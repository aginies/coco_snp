# AMD SEV-SNP Attestation — Step-by-Step Guide

Version 1.0.0

A guided walkthrough of how to set up and run AMD SEV-SNP attestation using
`snp-attest.sh`. The installation layer is distribution-pluggable (`lib/distros/`),
but for now only SLES/openSUSE are implemented.

Each step explains **what** happens, **why** it is needed, and **how to verify** it worked.

The whole process has two sides:

- **HOST** — the physical machine running the hypervisor. All commands in this
  guide run here (guest commands are executed remotely over SSH).
- **GUEST** — the virtual machine that becomes an **SEV-SNP confidential VM**:
  its memory is encrypted *and* integrity-protected by the AMD SEV-SNP
  hardware, and its launch state is measured into a single **launch digest**
  that the CPU's PSP signs into an attestation report.

> **SEV-SNP vs Intel TDX in one paragraph.** Both are confidential-VM
> technologies, but the attestation data path is different. In TDX the guest
> cannot sign its own quote — it asks a **host-side QGS** service to sign a
> TD Report over vsock, and verification pulls PCK collateral from Intel PCS.
> In SEV-SNP the **CPU's PSP signs the report in-guest** (over the GHCB
> channel) with a **VCEK** derived from the launch measurement — there is no
> host quote daemon, no vsock quote path, and no per-platform registration.
> Collateral (the ARK → ASK → VCEK chain) comes from **AMD KDS**. That
> removes an entire setup step (no `setup-qgs`) and a whole class of
> host-side quote bugs.

---

## Quick Start — 10 commands on a ready host

**Goal in one sentence:** prove to a remote verifier that the guest is a
genuine, untampered SEV-SNP confidential VM, and only then hand it a secret.

**The happy path (10 commands):**

```bash
# 1. Host preparation & capability check
sudo ./snp-attest.sh check

sudo ./snp-attest.sh setup-host
sudo ./snp-attest.sh setup-trustee
sudo ./snp-attest.sh setup-vm --guest-iso /path/to/SLE-16.1.iso

# 2. Manual: install SLES in the VM
virsh console snp-guest                    # install from ISO (or any other viewer)
sudo ./snp-attest.sh show-vm-info              # get GUEST_IP

# 3. Guest preparation + attestation
sudo ./snp-attest.sh setup-guest --guest-ip <GUEST_IP>
sudo ./snp-attest.sh attest --guest-ip <GUEST_IP> --register-rv

# 4. Secret delivery
sudo ./snp-attest.sh secret-set --file /tmp/my-secret --path default/test/secret
sudo ./snp-attest.sh secret-get --guest-ip <GUEST_IP> --path default/test/secret
```

> **Prerequisites before starting:**
>
> - AMD EPYC CPU with SEV-SNP (Rome / Genoa / Turin or later)
> - SEV-SNP enabled in BIOS (the CPU must report `sev_snp`)
> - SLES 16.1 installer ISO (from SUSE Customer Center)
> - Internet access to AMD KDS (or a local offline certificate store)
> - [Full prerequisites →](#prerequisites-before-any-script-command)

---

## Attestation flow (remote path, as driven by this guide)

1. **Guest:** `snpguest report` (or `snp-report-gen`) asks the **CPU's PSP**
   for a 4000-byte attestation report over the GHCB channel. The PSP signs it
   with the **VCEK** — no host involvement, no vsock.
2. **Guest → Host (HTTP:8080):** `kbs-client` submits the report to KBS
   (Method A), or the host fetches the report over SSH and submits it to
   CoCo-AS with `grpcurl` (the `attest` command / Method B).
3. **Host:** KBS delegates report verification to CoCo-AS.
4. **Host:** CoCo-AS fetches the **ARK → ASK → VCEK** chain from **AMD KDS**
   (remote) — or from the local offline certificate store when run with
   `--collateral offline`.
5. **Host:** CoCo-AS verifies the report signature against the VCEK, checks
   the reported TCB against KDS, and compares the launch identity
   (`id_block`, `id_auth`, `launch_digest`) against reference values from RVPS,
   then signs an EAR token.
6. **Host:** KBS evaluates its resource policy (Rego) against the EAR token claims.
7. **Host → Guest (HTTP:8080):** KBS releases the secret to `kbs-client`.

> **Note:** the `snp-attest.sh` script drives the guest over **ssh**
> (`setup-guest`, `attest`, `secret-get`). The attestation data path itself is
> the in-guest report (PSP-signed) + HTTP (KBS). There is **no vsock quote
> channel** — that is a TDX/QGS artifact, not an SEV-SNP one.

---

## Choose your path

| I want to… | Use this |
| --- | --- |
| Get everything running in one shot | `./snp-attest.sh all --guest-iso …` → [jump to Step 5](#step-5--install-the-guest-os-manual) |
| Understand each layer individually | [Steps 1–4](#one-shot-setup-snp-attestsh-all) below |
| Debug a broken setup | [Troubleshooting](#troubleshooting-map) |
| Validate the KDS cert chain + TCB (deep check) | `./snp-attest.sh check --check-platform` |
| Convert an existing (non-SNP) VM to SNP | `./snp-attest.sh convert-snp --convert-vm <VM>` |
| Run in an air-gapped / offline environment | `--collateral offline` (local cert store) |

---

## What each step actually changes

| Step | Changes on disk? | Changes network? | Requires reboot? | Can be skipped? |
| ------ | --- | --- | --- | --- |
| [1. Check host capabilities](#step-1--check-host-capabilities) | No | No | No | No (safety gate) |
| [2. setup-host (snphost + KDS collateral)](#step-2--set-up-the-host-snphost--kds-collateral) | Yes (packages, cert store) | No | No | Only if already done |
| [3. setup-trustee (attestation + secrets)](#step-3--set-up-trustee-attestation--secrets) | Yes (3 configs, keys, policy) | Yes (ports 3000/8080) | No | Only if already done |
| [4. setup-vm (create SNP VM)](#step-4--create-the-snp-vm) | Yes (disk, XML) | No | No | Only if already done |
| [5. Install guest OS](#step-5--install-the-guest-os-manual) | Yes (guest disk) | No | Yes (guest) | **No** |
| [6. setup-guest (guest config)](#step-6--set-up-the-guest-inside-the-snp-vm) | Yes (guest config) | No | No | Only if already done |
| [7. attest (remote attestation)](#step-7--perform-remote-attestation) | No (read-only) | Yes (guest→KDS→CoCo-AS) | No | Only if already done |
| [8. secret-get (secret delivery)](#step-8--secret-delivery) | No | Yes (guest→KBS) | No | Only if already done |
| [9. verify (consistency check)](#step-9--verify-everything-is-consistent-any-time) | No | No | No | **Recommended anytime** |
| [10. clean (cleanup)](#step-10--cleanup-when-done) | Yes (destroys VM) | No | No | Only when done |
| [11. Air-gapped / offline setup](#step-11--air-gapped--offline-setup-optional) | Yes (local cert store) | No (local) | No | **Yes** (only for offline hosts) |

---

## Source Code

The source code for these scripts is hosted on GitHub:

- **Repository:** [https://github.com/aginies/coco_snp](https://github.com/aginies/coco_snp)
- **Tarball:** [https://github.com/aginies/coco_snp/releases](https://github.com/aginies/coco_snp/releases) (when available)

### Getting the scripts

**Option 1 — Clone the repository (recommended for development or latest changes):**

```bash
git clone https://github.com/aginies/coco_snp.git
cd coco_snp
```

This gives you the full history, all branches, and the ability to update with
`git pull`.

**Option 2 — Download a specific release tarball:**

```bash
VERSION="1.0.0"
curl -LO "https://github.com/aginies/coco_snp/releases/download/v${VERSION}/coco_snp-${VERSION}.tar.gz"
tar xzf coco_snp-${VERSION}.tar.gz
cd coco_snp-${VERSION}
```

The tarball contains a versioned subdirectory with all scripts, the library,
and documentation — ready to use without Git.

**Option 3 — Download a single branch or tag:**

```bash
# Download a specific tag without cloning the full repo
curl -LO "https://github.com/aginies/coco_snp/archive/refs/tags/v1.0.0.tar.gz"
tar xzf v1.0.0.tar.gz
cd coco_snp-1.0.0
```

---

## Prerequisites (before any script command)

| Requirement |
| --- |
| AMD EPYC CPU with SEV-SNP (Rome / Genoa / Turin or later) |
| SEV-SNP enabled in BIOS (CPU must report `sev_snp`) |
| Linux host (SLES 16.1 is the reference target) |
| Internet access to AMD KDS |
| `kvm_amd` loaded with SEV-SNP support (the CPU exposes `/dev/sev`) |

**What to prepare before you start:**

| Item | Where to get it | Needed for |
| --- | --- | --- |
| SLES 16.1 installer ISO | SUSE Customer Center (subscription) | `setup-vm` / `all` (`--guest-iso`) and the manual install in Step 5 |

> **No platform registration needed.** Unlike Intel TDX (Xeon 6 / Scalable
> platforms must be registered before PCK certificates are issued), SEV-SNP
> needs **no per-platform registration**. The VCEK is derived from the VM's
> launch measurement and chained to AMD's public ARK/ASK root — fetched from
> KDS. If `check` reports the CPU does not advertise SEV-SNP, the fix is a
> BIOS setting, not a registration.

If BIOS SEV-SNP is off, nothing later will work — the CPU will not report
`sev_snp` and `/dev/sev` will not support the SNP ioctls.

---

## One-shot setup: `snp-attest.sh all`

Instead of running Steps 1–4 one by one, a single command chains them:

```bash
sudo ./snp-attest.sh all --guest-iso /path/to/SLE-16.1.x86_64.iso
```

It runs `check` → `setup-host` → `setup-trustee` → `setup-vm` in order,
**stops on the first hard failure** (the capability check aborts before
anything is installed), and finishes with a `verify` audit of the host-side
configuration.

- *When to use it:* a fresh host where you want the complete stack up in one
  go.
- *When to use the individual steps instead:* debugging a specific layer, or
  re-running after a partial failure — every step is idempotent, so re-running
  just the failed one is safe.

`all` stops at VM start: the manual guest OS install (Step 5) and everything
after it (Steps 6–8) still have to be done by hand. **If you used `all`, skip
straight to Step 5** — Steps 1–4 below are only for running things
individually.

---

## Detailed Steps 1–4 (host setup, individual)

> **Skip this section if you used `snp-attest.sh all`.**
> These are the individual commands for when you want to run each layer
> one-by-one (debugging, custom setups, incremental re-runs).

### Step 1 — Check host capabilities

**Command:**

```bash
sudo ./snp-attest.sh check
```

**What it does:** runs read-only probes. No changes are made; root is not
strictly required.

**Why each probe exists:**

| Probe | Tool | Why we check it |
| --- | --- | --- |
| CPU SEV-SNP flag | `grep /proc/cpuinfo` | Hardware must advertise `sev_snp`. Fallback: `/dev/sev` SNP ioctl support. |
| KVM | `stat /dev/kvm` | No `/dev/kvm` → no VMs at all. |
| Boot params (SEV-SNP) | `/proc/cmdline` + `/sys/module/kvm_amd/parameters/sev_snp` | The kernel/boot side of enabling SNP: `kvm_amd` must be loaded with `sev_snp=1` (cmdline or `/etc/modprobe.d`), `mem_encrypt=on` must not be off (the default `auto` is accepted when `/dev/sev` exists), and the AMD IOMMU must be on (`amd_iommu=on`). |
| libvirt | `virsh -c qemu:///system version` | A successful connection proves libvirt works (modular `virtqemud` or monolithic). |
| QEMU version | `qemu-system-x86_64 --version` | SEV-SNP support requires QEMU ≥ 8.0. |
| virt-customize | `command -v virt-customize` | guestfs-tools does the offline SSH-key injection in `setup-vm`. WARN only. |
| QEMU SEV-SNP object | `qemu-system-x86_64 -object help` | SEV-SNP is a QEMU *object* (`sev-snp-guest`), not a machine type — so we probe the object list, not `-machine help`. |
| SNP OVMF firmware | scan `/usr/share/qemu/firmware/*.json` | A SNP-capable UEFI firmware (feature `amd-sev-snp`) must exist to boot the confidential VM. |
| `/dev/sev` | `stat /dev/sev` | The SEV-SNP host device. Absent → `kvm_amd` not loaded with SNP, or BIOS off. |
| snphost package | `rpm -qa` | The host-side SNP verifier (reads the ARK/ASK/VCEK chain). |
| Trustee services | `systemctl` ×3 | Attestation stack (grpc-as, kbs, rvps; Step 3). |
| Ports 3000/8080 | `ss -tln` | CoCo-AS and KBS must listen. |
| KDS reachability | `curl -sI` | AMD KDS is where the ARK/ASK/VCEK chain comes from (or the local store in offline mode). |

**Expected result:** all rows PASS (WARN is non-fatal).

**If FAIL:** read the HINT column — it tells you the exact fix (BIOS setting,
package to install, service to start).

> **Tip — deep platform validity check:** run
> `sudo ./snp-attest.sh check --check-platform` (or the standalone
> `check-platform` command) to fetch the full ARK → ASK → VCEK chain from AMD
> KDS and verify the chain + TCB OIDs with `snphost`. Unlike TDX, there is no
> per-platform *registration* to validate — SEV-SNP has no PCK certificates —
> so this is a pure collateral/TCB check, not a "is my platform registered"
> check.

---

### Step 2 — Set up the host (snphost + KDS collateral)

**Command:**

```bash
sudo ./snp-attest.sh setup-host
```

**What it does, in order:**

1. **Installs the `snphost` package** (the host-side SEV-SNP verifier) via
   `zypper`, adding the Virtualization:SGX OBS repository if the package is not
   in the default SLES 16.1 repos.
   - *Why:* `snphost` is what verifies an SNP report's signature against the
     ARK → ASK → VCEK chain and checks the reported TCB. It is the SEV-SNP
     counterpart of Intel's DCAP quote-verification libraries.
   - The script only installs what's missing (`rpm -q` first), so re-runs are
     quiet.

2. **Verifies the host is SEV-SNP capable** (`/dev/sev` present, CPU reports
   `sev_snp`).
   - *Why:* sanity gate before going further. If this fails, no SNP VM can be
     launched and attestation is impossible.

3. **Fetches the AMD KDS certificate chain** (ARK, ASK, VCEK) into the local
   store (`/var/lib/sev-snp/certs/`).
   - *Why:* verification needs the root chain. In the default `kds` mode the
     chain is fetched from AMD's global KDS
     (`https://kdsintf.amd.com/vcek/v1/SEV_SNP`). In `offline` mode the store
     must already be populated (see [Step 11](#step-11--air-gapped--offline-setup-optional)).
   - *Why a local store:* CoCo-AS and `snphost` read the chain from disk at
     verification time; caching it locally also makes re-runs fast and lets an
     air-gapped host verify without internet.

4. **Ensures libvirt is running** (enables `virtqemud.socket` etc. if needed).
   - *Why:* Step 4 needs it to create the VM.

5. **Ensures `grpcurl` is available** (installs the distro package or the
   official prebuilt binary).
   - *Why:* Step 7 uses `grpcurl` to communicate directly with the CoCo-AS gRPC
     service for report appraisal.

> **Tip — air-gapped / offline collateral:**
> When the host cannot reach AMD KDS, import the certificate chain once while
> online (or from a trusted source) and use `--collateral offline`:
>
> ```bash
> sudo ./snp-attest.sh setup-host --collateral offline
> ```
>
> The offline store is `/var/lib/sev-snp/certs/{ark,ask,vcek}.pem`. See
> [Step 11](#step-11--air-gapped--offline-setup-optional) for the full
> air-gapped flow.

**Verify:**

```bash
rpm -qa | grep -i snphost                       # package present
ls -la /var/lib/sev-snp/certs/                  # ark/ask/vcek .pem present
virsh -c qemu:///system version                 # libvirt answers
```

---

### Step 3 — Set up Trustee (attestation + secrets)

**Command:**

```bash
sudo ./snp-attest.sh setup-trustee
```

**Background — the attestation stack's three roles:**

| Service | Role in one line |
| --- | --- |
| **CoCo-AS** (`grpc-as`) | The verifier: checks the report's signature (VCEK) and launch identity, and returns an **EAR token** (a JWT containing the measured claims + an `allow` decision). For SEV-SNP it uses the **`snp_verifier`**. |
| **KBS** | The vault: stores secrets; releases one only to a client presenting a valid EAR token that passes the resource policy. |
| **RVPS** | The reference list: holds the expected launch identity (`id_block`, `id_auth`, `launch_digest`) CoCo-AS compares against. |

**What it does, in order:**

1. **Installs `trustee` + the SNP verify libraries.**
   - *Why:* provides the three services; the extra libs are what grpc-as links
     against for signature verification.

2. **Checks `ldd` on grpc-as.**
   - *Why:* fail now on missing shared libraries instead of a service that
     crashes at runtime with an obscure log.

3. **Generates the CoCo-AS signer keypair (EC P-256), the JWKS file, and a
   self-signed X.509 certificate for the token's `x5c` chain.**
   - *Why:* CoCo-AS signs EAR tokens with this key. If no persistent signer is
     configured, grpc-as uses an *ephemeral* key — tokens become unverifiable
     and KBS rejects everything. This SLE build of grpc-as doesn't serve a
     `/.well-known/jwks.json` endpoint, so the script derives the JWKS
     manually from the public key (openssl → x/y coordinates → JSON). KBS is
     pointed at it via `file://` (it rejects plain `http://`).
   - *Why also a certificate:* the token header embeds the signing key as a
     `jwk`, and when it does, KBS **requires** a non-empty `x5c` chain that
     chains to `attestation_token.trusted_certs_paths` — otherwise it rejects
     the token ("neither trusted jwk set nor trusted pem public key works").
     The script derives a self-signed cert from the signer key
     (`/etc/trustee/as-signer.crt`), points `grpc-as.json` `cert_path` at it,
     and lists it in `kbs.json` `trusted_certs_paths`.

4. **Generates the KBS admin keypair (ed25519).**
   - *Why:* admin-mode operations (storing secrets, setting policy) authenticate
     with this key. Private key stays root-only; KBS only needs the public
     half.

5. **Writes the resource policy (Rego).**
   - *Why:* this policy decides *which* attested clients may fetch *which*
     secrets. **Warning:** the script writes an **allow-all** policy — a lab
     default. For production, gate it on real claims (e.g.
     `snp.report.id_block` / `snp.report.launch_digest`).

6. **Writes the three config files:**
   - `/etc/grpc-as.json` → CoCo-AS: storage dir, signer key, and the
     **`snp_verifier`** (so it appraises SEV-SNP reports, not TDX quotes).
   - `/etc/kbs.json` → KBS: listen address, CoCo-AS address, JWKS file,
     policy path. (Lab settings: `insecure_http`, `InsecureAllowAll`.)
   - `/etc/rvps.json` → RVPS: storage dir.
   - *Why explicit configs:* every component must point at the same endpoints;
     inconsistent addresses are a classic silent failure.

7. **Overrides `kbs.service` and `grpc-as.service` ExecStart** via drop-ins.
   - *Why:* the packaged units don't pass the config file correctly (KBS omits
     `--config-file`; grpc-as's env var isn't expanded and uses a wrong flag
     name). Without the override, both run with built-in defaults → broken
     attestation.

8. **Starts services in dependency order:**
   `rvps` → `grpc-as` → *wait for port 3000* → `kbs`.
   - *Why this order:* KBS loads the JWKS file at startup, so CoCo-AS must be
     up first; the policy upload needs KBS up.
   - *Note on `trustee.service`:* the monolithic `trustee.service` package unit
     is intentionally disabled. It is redundant with the dedicated `grpc-as`,
     `kbs`, and `rvps` services, and its unit requires `/etc/trustee.json`
     which is not used in this architecture.

9. **Uploads the resource policy to KBS** with `kbs-client
   config set-resource-policy`.
   - *Why:* KBS only enforces a policy that has been pushed into it.

**Verify:**

```bash
systemctl is-active grpc-as kbs rvps           # all active
ss -tln | grep -E '3000|8080'                  # ports listening
```

> **Note — lab vs production:** this setup is deliberately a **lab
> configuration**. Three things are permissive and must be changed for real
> use: (1) the resource policy is **allow-all** — any attested client can
> fetch any secret; in production, gate it on real claims (e.g.
> `snp.report.id_block`). (2) KBS runs with `insecure_http` +
> `InsecureAllowAll` — no TLS, no tenant isolation. (3) the host-mode
> `secret-get` (Method B) leaves the EAR token on the host, so anyone holding
> it can fetch the secret — use the in-guest `kbs-client` (Method A) for real
> secret gating.

---

### Step 4 — Create the SNP VM

**Command:**

```bash
sudo ./snp-attest.sh setup-vm --guest-iso /path/to/SLE-16.1.iso
```

**Options (with defaults):**

| Option | Default | Description |
| --- | --- | --- |
| `--guest-iso PATH` | *(mandatory)* | Path to installer ISO |
| `--vm-name NAME` | `snp-guest` | Libvirt domain name |
| `--vm-mem MB` | `16384` | RAM in megabytes (16 GB) |
| `--vm-cpu N` | `4` | Number of vCPUs |
| `--vm-disk SIZE` | `32G` | Qcow2 disk size |
| `--ssh-key PATH` | `~/.ssh/id_ed25519` | SSH keypair to generate/inject |
| `--virt-install` / `--no-virt-install` | `auto` | VM creation engine: `virt-install` if available, else generated XML |
| `--vnc-listen ADDR` | `0.0.0.0` | VNC listen address (use `127.0.0.1` for host-local only) |
| `--vnc-port PORT` | `5900` | Fixed VNC port (instead of libvirt autoport) |
| `--dry-run` | *(off)* | Print the `virt-install` command without executing (no root needed) |
| `--no-snp` | *(off)* | Create regular non-SNP VM (for later `convert-snp`) |

**What it does, in order:**

1. **Locates the SNP OVMF** via QEMU firmware descriptors (feature
   `amd-sev-snp`) and **confirms QEMU has the `sev-snp-guest` object.**
   - *Why:* fail fast — creating a VM that can't be a confidential VM wastes
     the whole install cycle.

2. **Creates the qcow2 disk** (32G default) — by `virt-install` itself when
   the virt-install engine is used, otherwise `qemu-img create`.
   - *Why:* guest storage. If the disk already exists it's reused — but only
     counted as "has an OS" when it actually contains a filesystem
     (`virt-filesystems`); a leftover empty qcow2 from an aborted install is
     treated as fresh.

3. **Creates the domain definition.** Two engines, same result:

   - **virt-install engine (default when `virt-install` is installed):**
     the script extracts the installer kernel/initrd from the ISO
     (`/boot/x86_64/loader/{linux,initrd}`) into
     `/var/lib/libvirt/boot/<vm>-installer-{kernel,initrd}`, then runs
     `virt-install --name … --memory … --vcpus … --disk … --cpu
     host-passthrough --network network=default,model=virtio --graphics
     vnc,listen=… --video virtio --boot cdrom,hd --machine q35 --location <ISO>
     --extra-args console=ttyS0,115200 --print-xml` — i.e. **XML generation
     only, nothing is started**. The script then applies a post-define SNP
     patch (below) and defines + starts the domain **once** — so the SNP
     configuration is in place *before* the first boot.
   - **Generated XML engine** (`--no-virt-install`, or automatic fallback):
     the script writes the full domain XML itself.

   The SNP-critical elements and *why* each (both engines produce these):

   | XML element | Why it's required |
   | --- | --- |
   | `<launchSecurity type='sev-snp'>` + `<policy>` + `<vms>` | Tells libvirt/QEMU to launch this VM as an SEV-SNP confidential VM. The `policy` (default `0x30000`) is the launch policy; `vms` is the VMPL (0 = guest OS). **This element is what makes libvirt auto-select the SNP firmware and set up the writable NVRAM.** |
   | (no explicit `<loader>`) | The SNP firmware is selected by libvirt's firmware autoselection from the `amd-sev-snp` descriptor once `launchSecurity type='sev-snp'` is present. Forcing a pflash loader without a matching NVRAM template would break the VM. (The virt-install engine *removes* the regular loader it emits.) |
   | `<vsock model='virtio'>` | Optional guest↔host channel (useful for agent traffic). SNP attestation itself does **not** need vsock — the report is generated in-guest by the PSP, not via a host daemon. |
   | `<memtune><hard_limit>` | Hard memory limit slightly above guest RAM (firmware + overhead). |
   | `<resource><partition>/machine` | Resource partitioning for the confidential guest. |
   | `<pm><suspend-to-mem/disk enabled='no'>` | SNP VMs cannot suspend/hibernate — the saved image would be unmeasured/unencrypted. |
   | virtio video + serial console | The display path that works for the ISO installer on a confidential guest. |

4. **Generates an SSH key** (`ssh-keygen -t ed25519`) if absent.
   - *Why:* all later steps drive the guest passwordlessly over SSH.

5. **If the disk already has an OS:** injects the SSH key and disables
   suspend via `virt-customize` (libguestfs offline disk editing).
   - *Why virt-customize:* it mounts the disk image without booting the VM —
     faster and more reliable than console editing.
   - On a **fresh empty disk** this is skipped (nothing to mount); you inject
     the key after the OS install instead.

6. **Defines and starts the VM** with `virsh` (generated-XML engine also
   attaches the ISO with `attach-disk --config` first; the virt-install
   engine attaches it via `--location`/cdrom at XML-generation time).
   - *Why `--config` on attach-disk:* persists the ISO into the domain
     definition; a live attach would fail before the domain exists at runtime.

**Alternative path — converting an existing VM:**
If you already have a VM (disk, network, OS) you'd rather not reinstall:

```bash
sudo ./snp-attest.sh setup-vm --no-snp --guest-iso /path/to/iso   # or use any existing VM
virsh shutdown <vm>
sudo ./snp-attest.sh convert-snp --convert-vm <vm>
```

> **Tip:** If `--convert-vm` is omitted, `convert-snp` automatically detects
> running/available VMs and prompts interactively.

`convert-snp` edits the domain XML in place (removes the regular loader so the
SNP firmware is autoselected, adds `launchSecurity type='sev-snp'` + `vsock`,
disables suspend) using an inline Python (ElementTree) XML transformer, with
automatic backup and rollback. *Why Python:* bash text munging of XML is
fragile; ElementTree parses it properly.

**Verify:**

```bash
virsh list                                # VM running
virsh dumpxml snp-guest | grep -E 'launchSecurity|vsock|policy'
```

---

## Step 5 — Install the guest OS (manual)

The installer **boots automatically** on the first start (one-shot direct
kernel boot from the ISO — see Step 4); you only drive the installer itself
through the console.

1. **Open the console:**

   ```bash
   virsh console snp-guest
   ```

   - *Why console:* the installer is wired to `console=ttyS0` (serial) — the
     reliable channel for a confidential guest. The VNC display works too, but
     the serial console never depends on the guest's display stack.

2. **Install SLES 16.1** from the ISO. Use the default kernel (6.1+ is
   required for SEV-SNP guest support).

3. **After install + reboot, get the guest IP:**

   ```bash
   virsh net-dhcp-leases default
   # or inspect all VMs:
   sudo ./snp-attest.sh show-vm-info
   ```

   - *Why:* the guest got DHCP on libvirt's default network; the script needs
     this IP for SSH.

> **Tip — Guest IP auto-detection:**
> When only one VM is running, subsequent commands (`setup-guest`, `attest`,
> `register-rv`, `secret-get`) will auto-detect the guest IP if `--guest-ip`
> is omitted.

4. **If you skipped key injection (fresh disk), inject it now:**

   ```bash
   sudo virt-customize -a /var/lib/libvirt/images/snp-guest.qcow2 \
       --ssh-inject root:file:$HOME/.ssh/id_ed25519.pub
   ```

   (VM must be stopped for this; or paste the key via console.)

**Verify:**

```bash
ssh -i ~/.ssh/id_ed25519 root@<GUEST_IP> echo ok
```

---

## Step 6 — Set up the guest (inside the SNP VM)

**Command (run on the HOST, acts inside the guest via SSH):**

```bash
sudo ./snp-attest.sh setup-guest --guest-ip <GUEST_IP>
```

**What it does, in order — with the guest/host distinction explicit:**

1. **Tests SSH connectivity** to the guest.
   - *Why:* fail early with a troubleshooting checklist (sshd running? key
     present? right IP? firewall?) instead of dying mid-setup.

2. **Refuses to run if the target is the host.**
   - *Why:* pointing this at the host would fail later with a misleading
     "Failed to get the report" error.

3. **Confirms the SNP guest device exists** (`/dev/sev-guest`).
   - *Why:* this character device is **the proof you're inside a real
     SEV-SNP confidential VM**. It is created by the kernel's `sev-guest`
     driver only when the VM was launched as an SNP guest.

4. **Disables suspend/hibernate in the guest** (masks sleep targets, ignores
   hardware keys).
   - *Why:* SNP cannot hibernate — the disk image would be unmeasured and
     unencrypted, breaking the attestation guarantee.

5. **Installs attestation packages in the guest** (`snpguest`, `trustee`
   package) over SSH.
   - *Why:* `snpguest` talks to `/dev/sev-guest` to generate reports; the
   `trustee` package's `kbs-client` is the in-guest attester for secret
   delivery.

6. **Verifies the packaged `kbs-client` has the SNP attester** (and removes
   any stale source-built `/usr/local/bin/kbs-client-snp`).
   - *Why:* the SLE `trustee` package ships an SNP-attester-capable
     kbs-client at `/usr/libexec/trustee/kbs-client`, version-aligned with the
     host verifier stack. Older builds lacked the SNP attester, and source
     builds from upstream master can drift ahead of the packaged verifier. If
     the package client lacks the attester, the script dies with an upgrade
     hint instead of falling back to a source build.

7. **Builds `snp-report-gen` in the guest** (from `tools/snp-report-gen.c`,
   installing `gcc` if needed).
   - *Why:* the distro's `snpguest report` always mints reports with a
     *random* `report_data` (it never reads argv). Host-mode `secret-get`
     needs a report whose `report_data` is bound to a TEE public key, so the
     script builds a minimal `/dev/sev-guest` ioctl wrapper that takes the
     `report_data` as an argument. Installed at
     `/usr/local/bin/snp-report-gen`.

8. **Generates the first report:**

   ```
   snpguest report   (in guest workdir /root/snp-attest)
   ```

    - *Why:* this is the in-guest report generator. It asks the CPU's PSP for
      a 4000-byte attestation report (signed with the VCEK) and writes
      `report.dat`. Success here proves the entire report path works:
      guest → GHCB → PSP → signed report.
    - The script then **verifies** the report in-guest with `snpguest verify`
      (ARK → ASK → VCEK chain, signature, TCB, VMPL, `report_data` binding) so
      you see a green local check before the remote appraisal.

**Verify (inside guest):**

```bash
ls -la /root/snp-attest/report.dat
```

---

## Step 7 — Perform remote attestation

This is the end-to-end live attestation: once your SNP guest is running,
`attest` generates a 4000-byte report (signed in-guest by the CPU's PSP),
submits it to CoCo-AS, which fetches the ARK/ASK/VCEK chain from AMD KDS and
verifies the signature, TCB status, and launch identity, then returns an EAR
token — `affirming` when the platform is valid and reference values are
enrolled.

**Command (on the host):**

```bash
sudo ./snp-attest.sh attest --guest-ip <GUEST_IP> --register-rv
```

> **Default:** `--register-rv` is recommended — it enrolls the guest's launch
> identity in RVPS *and* re-evaluates the same report, giving a clean
> `ear.status = affirming` in one step. See [below](#enrolling-reference-values-into-rvps)
> for details.

**What it does, in order:**

1. **Generates a fresh report** in the guest (`snpguest report` via SSH).
   - *Why fresh:* the report's `report_data` is a per-run nonce; a reused
     report is rejected.

2. **Fetches the report** (the raw 4000 bytes, base64-encoded over SSH).
   - *Why base64:* it's binary data that must travel inside a JSON request.
   - *Why raw (no JSON wrapper):* the CoCo-AS SNP verifier expects the raw
     report as the `evidence` bytes — unlike TDX, which wraps the quote in a
     JSON object.

3. **Enrolls reference values in RVPS** (with `--register-rv`):
   - *Why:* RVPS stores the expected launch identity (`id_block`, `id_auth`,
     `launch_digest`) that CoCo-AS compares against during appraisal. Without
     enrollment, the appraisal returns `contraindicated` because no reference
     values exist. `--register-rv` writes the current guest's identity into
     RVPS and re-evaluates the *same* report (not a fresh one), so the values
     match by construction → `ear.status = affirming`.

4. **Submits it to CoCo-AS** with:

   ```bash
   grpcurl -plaintext -import-path "$PROTO_DIR" -proto attestation.proto -d @ 127.0.0.1:3000 \
       attestation.AttestationService/AttestationEvaluate < req.json
   ```

   The request body is:

   ```json
   {
     "verification_requests": [
       { "tee": "snp", "evidence": "<base64 of the 4000-byte report>" }
     ],
     "policy_ids": ["default"]
   }
   ```

   - *Why grpcurl:* CoCo-AS speaks gRPC; grpcurl is the standard CLI for
     calling gRPC services without writing code. `$PROTO_DIR` is resolved at
     runtime — an existing `attestation.proto` (repo `protos/`, `/etc/trustee`,
     …) is used if present, otherwise the script writes one to
     `/tmp/trustee-protos/`. `snp-attest.sh` automatically installs prebuilt
     `grpcurl` into `/usr/local/bin` (or `~/.local/bin`) if missing.
   - *What CoCo-AS does with it:* verifies the VCEK signature, fetches the
     ARK/ASK/VCEK chain from AMD KDS (or the local offline store), checks the
     reported TCB, compares the launch identity (`id_block`, `id_auth`,
     `launch_digest`) against RVPS reference values, then returns an **EAR
     token** — a JWT containing all measured claims plus an `allow: true/false`
     decision.

5. **Decodes the EAR JWT and checks `allow: true`.**
   - *Why look in the JWT:* the policy decision lives *inside the token*, not
     in the gRPC response body. `allow: true` = attestation succeeded.

**The EAR token in one sentence:** CoCo-AS wraps the verified report in an
**EAR token** — a JWT (built on EAT, RFC 9711) carrying the measured claims
plus the `allow` decision; KBS verifies its signature and reads `allow`
without re-doing the attestation. *(Full background: "Appendix — JWT & EAR
tokens" at the end of this guide.)*

The `attest` command decodes the EAR token (a JWT built on EAT, RFC 9711):
extracts the payload, formats the claims, displays a structured verification
report, and checks `ear.status` as well as the KDS `tcb_status`.

**Expected output (report verified, awaiting RVPS enrollment):**

```
=============================================================================
                       SEV-SNP REMOTE ATTESTATION REPORT
=============================================================================
  Hardware Verification (AMD KDS):
    TCB Status:             UpToDate
    TEE Type:               snp
    VMPL:                   0
  Guest Launch Identity:
    id_block:               <32-byte family ID>
    id_auth:                <32-byte author ID>
    launch_digest:          <48-byte (384-bit) launch measurement>
  Trustee Appraisal Result (RVPS):
    EAR Status:             contraindicated
=============================================================================
[INFO] === HARDWARE ATTESTATION SUCCESS: report verified (TCB: UpToDate) ===
[WARN] Appraisal status is 'contraindicated' because reference values are not enrolled in RVPS.
[WARN] To register current guest identity in RVPS and achieve 'affirming' status, run:
  ./snp-attest.sh attest --guest-ip <GUEST_IP> --register-rv
  or: ./snp-attest.sh register-rv --guest-ip <GUEST_IP>
```

**Expected output (Fully appraised with RVPS reference values):**

```
=== ATTESTATION SUCCESS: ear.status = affirming ===
AMD KDS hardware verification AND Trustee appraisal passed!
```

### Enrolling reference values into RVPS

The default Trustee appraisal policy used by this script requires `id_block`,
`id_auth`, and `launch_digest` to match approved reference values stored in
the Reference Value Provider Service (RVPS). You can enroll the guest's
identity directly:

```bash
# Enroll reference values and attest in one step:
sudo ./snp-attest.sh attest --guest-ip <GUEST_IP> --register-rv

# Or enroll separately:
sudo ./snp-attest.sh register-rv --guest-ip <GUEST_IP>
sudo ./snp-attest.sh query-rv --id launch_digest
```

### The SNP launch identity (no RTMRs)

Unlike TDX (which has four extend-only RTMR registers), an SEV-SNP guest has
a **single launch digest** plus two identity fields, all in the 4000-byte
report:

| Field | Size | Measures | Stability |
| --- | --- | --- | --- |
| **`launch_digest`** | 48 bytes (384-bit) | The guest's launch state: OVMF, kernel, initrd, VMSA. This is the SNP equivalent of TDX's MRTD + RTMRs rolled into one extend-only measurement. | Static per firmware + kernel + boot config |
| **`id_block`** | 32 bytes | Guest family identifier (set by the VMM at launch). | Stable per deployment |
| **`id_auth`** | 32 bytes | Guest author identifier (set by the VMM at launch). | Stable per deployment |

The report also carries `reported_tcb` (the firmware/TEE/microcode TCB the
guest was launched with — checked against KDS), `policy` (the launch policy,
default `0x30000`), `vmpl` (the privilege level, 0 for the guest OS), and
`report_data` (a 64-byte field the caller can bind to a nonce or a TEE key).

**Why one digest instead of four RTMRs:** SEV-SNP's measurement model extends
a single running digest as the firmware walks the boot chain, rather than
exposing per-stage registers. The result is simpler to reason about (one value
to enroll) but you lose the per-stage granularity TDX's RTMRs give you.

### Understanding `ear.status`

- **`affirming`** — the report verified against KDS *and* the launch identity
  matches enrolled RVPS reference values. This is the success state.
- **`contraindicated`** — hardware verification passed but no (or mismatched)
  RVPS reference values exist. Fix: `attest --register-rv` (or `register-rv`).
- **`warning`** — hardware verified, but a non-critical claim is off (e.g. TCB
  is `OutOfDate` — update microcode/BIOS, or the KDS cache is stale).

**If it fails:**

```bash
journalctl -u grpc-as.service -n 50     # CoCo-AS logs: why it rejected
```

Common causes: RVPS reference values don't match the guest's launch identity,
reported TCB outdated, AMD KDS / offline store unreachable.

---

## Step 8 — Secret delivery

This demonstrates the full purpose of attestation: **a secret is released only
to a guest that has proven it is a genuine SEV-SNP confidential VM.**

### 8a. Store a secret (host, admin role)

```bash
echo "s3cr3t-api-key" > /tmp/my-secret
sudo ./snp-attest.sh secret-set --file /tmp/my-secret --path default/test/secret
```

- *Tool:* `kbs-client config set-resource` in admin mode.
- *Why:* the secret now lives in KBS. KBS will not hand it to anyone until a
  client (1) attests successfully and (2) passes the resource policy.

### 8b. Fetch the secret — two methods

**Method A (default): in-guest kbs-client**

```bash
sudo ./snp-attest.sh secret-get --guest-ip <GUEST_IP> --path default/test/secret
```

- *What happens:* the script runs the SNP-enabled `kbs-client` **inside the
  SNP VM**. The client generates a real report, sends it to KBS, KBS forwards
  it to CoCo-AS, gets the EAR token, checks the policy, and streams the secret
  back.
- *Why this is the "real" method:* the client fetching the secret *is* the
  attested entity. The secret lands in the confidential VM.

**Method B: host-side RCAR with a host TEE key**

```bash
sudo ./snp-attest.sh secret-get --guest-ip <GUEST_IP> --path default/test/secret --mode host
```

- *What happens:* the host generates an EC P-256 TEE key, has the guest mint a
  report bound to it (`report_data = sha384` of the canonical runtime data,
  zero-padded to 64 bytes, via `snp-report-gen`), submits it to CoCo-AS with
  grpcurl (structured runtime data carries the `tee-pubkey` claim KBS
  requires), then GETs the resource from KBS and decrypts the JWE-encrypted
  response (ECDH-ES+A256KW/A256GCM) locally with python3 (`cryptography` +
  `jwcrypto`).
- *Why it exists:* no in-guest kbs-client needed.
- *Caveat:* the EAR token and the TEE private key sit on the host, so anyone
  with them can fetch the secret. Fine for labs; not for real secret gating.

**Expected output (both):**

```
=== SECRET DELIVERY SUCCESS: attestation passed, secret released ===
```

> **Tip — saving secrets to file:**
> By default, `secret-get` prints text secrets to stdout. For binary secrets
> (or direct persistence), pass `--file <DEST_PATH>`. In Method A this saves
> the secret directly to the file inside the guest; in Method B it saves it to
> the host filesystem.

---

## Step 9 — Verify everything is consistent (any time)

**Command:**

```bash
sudo ./snp-attest.sh verify
```

Read-only deep audit. *Why it exists:* the setup steps write many config files
and start many services; a single wrong endpoint or typo in the JSON fails
attestation silently. `verify` cross-checks:

- all config files exist and are valid JSON (`jq`/`python3`),
- **CoCo-AS uses the `snp_verifier`** (not the TDX verifier),
- KBS points at the configured CoCo-AS address,
- JWKS file and KBS admin key are wired,
- the resource policy file is present,
- all 3 stack services active (`grpc-as`, `kbs`, `rvps`; `trustee.service` is
  intentionally disabled), both ports listening (`3000`, `8080`),
- grpc-as libraries resolve (`ldd`),
- `/dev/sev` present and the SNP OVMF firmware descriptor exists,
- the VM has `launchSecurity type='sev-snp'` + policy,
- collateral source reachable (KDS or offline store),
- guest `kbs-client` has the SNP attester feature compiled in (when reachable
  via SSH).

Run it after any manual change, and whenever attestation stops working.

---

## Step 10 — Cleanup (when done)

**Command:**

```bash
sudo ./snp-attest.sh clean
```

- Stops Trustee services, destroys and undefines the VM.
- Pass `-f` / `--force` to skip the interactive confirmation prompt.
- *Deliberately keeps:* configs, keys, policies, the certificate store, and
  the disk image (all listed in the output) — so re-running setup is
  incremental, not from scratch.
- Remove the disk manually if truly done:
  `rm /var/lib/libvirt/images/snp-guest.qcow2`

---

## Step 11 — Air-gapped / Offline Setup (optional)

If your host **cannot reach AMD KDS** (no internet, air-gapped network,
compliance requirements), you must use a **local offline certificate store**
that holds the ARK → ASK → VCEK chain. The scripts support this via the
`--collateral offline` flag.

### What is the offline store?

The offline store is a local directory of PEM certificates:

- **ARK** — AMD Root Key certificate (the trust anchor)
- **ASK** — AMD Signing Key certificate (signed by the ARK)
- **VCEK** — the VM Certificate Key certificate for your guest (signed by the
  ASK), fetched for the specific launch identity

Without the offline store, the SNP stack fetches collateral from AMD KDS at
runtime (`https://kdsintf.amd.com/vcek/v1/SEV_SNP`). With the offline store,
it reads from `/var/lib/sev-snp/certs/` instead.

> **SEV-SNP vs TDX offline:** TDX needs a full **PCCS** server (Node.js +
> SQLite) to cache PCK/TCB/QE collateral, plus a one-time **platform
> registration** while online. SEV-SNP needs **neither** — just the three
> PEM files. There is no per-platform registration to do while online, which
> makes the air-gapped transition much simpler.

### Prerequisites for air-gapped operation

| Requirement | Notes |
| --- | --- |
| ARK/ASK/VCEK PEM files | Must be obtained *before* going offline (see below) |
| SLES 16.1 ISO | Same as online setup |
| SEV-SNP enabled in BIOS | Same as online setup |
| `kvm_amd` with SNP support | Same as online setup |

### Step-by-step: initial sync (while you still have internet)

#### 1. Fetch the certificate chain

The simplest path: run the normal online setup once, which populates the local
store from KDS:

```bash
sudo ./snp-attest.sh setup-host          # default --collateral kds
ls -la /var/lib/sev-snp/certs/           # ark.pem, ask.pem, vcek.pem
```

Alternatively, import a chain you obtained from a trusted source with
`snphost import` (see the `snphost` man page for the exact import syntax for
your build).

#### 2. Verify the store is complete

```bash
sudo ./snp-attest.sh check --collateral offline
```

This confirms the offline store is populated and usable.

### Step-by-step: going offline

#### 3. Disconnect the host from the internet

#### 4. Run the full setup with `--collateral offline`

```bash
sudo ./snp-attest.sh check --collateral offline
sudo ./snp-attest.sh setup-host --collateral offline
sudo ./snp-attest.sh setup-trustee --collateral offline
sudo ./snp-attest.sh setup-vm --guest-iso /path/to/SLE-16.1.iso --collateral offline
```

> **Note:** the `--collateral offline` flag tells `setup-host` to use the
> local store (not fetch from KDS) and `setup-trustee` to configure CoCo-AS to
> read the local store. `setup-vm` doesn't directly use the flag but benefits
> from the host being configured.

#### 5. Complete the remaining steps (5–10) as usual

Steps 5–10 (guest OS install, guest setup, attestation, secret delivery,
verify, cleanup) are **identical** to the online flow. The only difference is
that report verification reads the ARK/ASK/VCEK chain from the local store
instead of AMD KDS.

### Offline store maintenance

The ARK and ASK certificates are long-lived (they are AMD's root of trust and
rarely change). The **VCEK** is per-launch-identity and is stable for a given
guest configuration. If you change the guest's launch identity (different
OVMF/kernel → different `launch_digest`), you need a fresh VCEK — fetch it
while online, or re-run `setup-host` with internet access.

If the ARK/ASK are ever rotated by AMD, re-fetch the chain while online and
re-run `setup-host --collateral kds` to refresh the store.

---

## Appendix — JWT & EAR tokens

**What is a JWT?**
A **JWT (JSON Web Token)** is a standard format (RFC 7519) for carrying
signed data as a single string. It has three base64url-encoded parts
separated by dots:

```
header.payload.signature
```

- **header** — signing algorithm and key type
- **payload** — the actual claims (JSON data)
- **signature** — cryptographic proof the content wasn't tampered with

In this flow, the **EAR token** from CoCo-AS is a JWT whose payload contains:

- the measured claims (`id_block`, `id_auth`, `launch_digest`, TCB, policy,
  vmpl)
- `allow: true/false` — the policy decision
- the issuer and expiry

**What is EAR?**
EAR = **EAT Attestation Result**. It's a standard JWT format built on the IETF
Entity Attestation Token (EAT, RFC 9711), as used by the Confidential
Containers / Trustee ecosystem.

The raw SNP report is complex (binary, AMD-specific). The EAR token:

1. **Normalizes** it into standard JSON
2. **Adds the policy decision** (`allow`)
3. **Makes it portable** — KBS doesn't need to understand SEV-SNP, just verify
   the JWT signature and read `allow`

The EAR token is the **bridge** between hardware-specific attestation and
generic secret delivery.

**Why it's used:** KBS receives the token, verifies its signature with the
JWKS (the public key set from Step 3), and trusts the claims *without*
re-doing the whole attestation. The token is portable proof that "this guest
was verified" — that's why the script can use it as a bearer token in Step 8.

---

## Troubleshooting map

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| QEMU/libvirt fail at launch: "SEV-SNP not supported" | `kvm_amd` not loaded with SNP, or BIOS SEV-SNP off | Check `dmesg \| grep -i sev`; enable SEV-SNP in BIOS, reload `kvm_amd`. Verify: `ls -la /dev/sev` |
| `check`: "CPU does NOT report SEV-SNP support" | BIOS SEV-SNP disabled, or CPU predates SEV-SNP | Enable SEV-SNP in BIOS (AMD EPYC Rome/Genoa/Turin+). No registration needed (unlike TDX) |
| `/dev/sev` missing | `kvm_amd` not loaded with SNP support | `modprobe kvm_amd`; check `dmesg \| grep -i sev` for SEV-SNP init |
| `modprobe sev-guest` → "No such device" inside guest | VM not launched as an SNP guest | `sudo ./snp-attest.sh verify` → VM rows; check `launchSecurity type='sev-snp'` in `virsh dumpxml` |
| Installer never appears; guest boots but isn't confidential | `launchSecurity` missing or firmware not SNP | `virsh dumpxml` — confirm `launchSecurity type='sev-snp'` + `<policy>`; confirm the SNP OVMF descriptor exists |
| `snpguest report`: "Failed to get the report" | `/dev/sev-guest` not present or GHCB not set up | Confirm the VM is a real SNP guest (Step 6 item 3); check the guest kernel has the `sev-guest` driver |
| Attestation: `ear.status: contraindicated` | RVPS values missing or mismatched | Run `sudo ./snp-attest.sh attest --guest-ip <GUEST_IP> --register-rv` or check `journalctl -u grpc-as.service -n 50` |
| Attestation: `ear.status: warning` (TCB OutOfDate) | Reported TCB older than KDS's current TCB | Update guest microcode/BIOS, or refresh the KDS cache / offline store |
| CoCo-AS: "unknown TEE" / verifier error | CoCo-AS not using `snp_verifier` | `sudo ./snp-attest.sh setup-trustee` (rewrites `grpc-as.json` with `snp_verifier`); or `verify` → CoCo-AS rows |
| KBS rejects tokens: `neither trusted jwk set nor trusted pem public key works` | Token header embeds a `jwk` but the `x5c` chain is empty or doesn't chain to `trusted_certs_paths` | `sudo ./snp-attest.sh setup-trustee` (regenerates `/etc/trustee/as-signer.crt`, `grpc-as.json` `cert_path`, `kbs.json` `trusted_certs_paths`); or `verify` → JWKS rows |
| `trustee.service` reports `inactive` / condition failed | The monolithic `trustee.service` is intentionally disabled in favor of individual modular units | Expected behavior. Verify the active modular services: `systemctl is-active grpc-as kbs rvps` |
| Guest kbs-client missing or lacks SNP attester | `trustee` package too old | Install/upgrade the `trustee` package from the Virtualization:SGX repo, then re-run `sudo ./snp-attest.sh setup-guest --guest-ip <GUEST_IP>` |
| Guest can't reach KBS (secret-get times out) | Host firewall blocks 8080, wrong guest IP, or libvirt NAT issue | From the guest: `curl -sI http://<HOST_IP>:8080` — check the host firewall (`sudo firewall-cmd --list-ports`) and re-fetch the IP with `virsh net-dhcp-leases default` |
| Offline mode: verification fails with a cert error | ARK/ASK/VCEK store incomplete or stale | `sudo ./snp-attest.sh check --collateral offline`; re-run `setup-host --collateral kds` while online to refresh |
| `grpcurl: command not found` | Auto-installed grpcurl not in PATH | The script installs it to `/usr/local/bin` (root) or `~/.local/bin` — check `echo $PATH`, or re-run `attest` as root so it lands in `/usr/local/bin` |

Debug any step with full command trace:

```bash
sudo ./snp-attest.sh <command> -d
```

> **Note:** options always come **after** the command — `snp-attest.sh -d check`
> is rejected with `Unknown option: check`.

---

## Acronym Glossary

### TEE Platforms & Architectures

| Acronym | Full Name | Description |
| --------- | ----------- | ------------- |
| SEV | Secure Encrypted Virtualization | AMD's confidential computing technology; encrypts guest memory |
| SEV-ES | SEV Encrypted State | SEV extension that also encrypts the CPU register state |
| SEV-SNP | SEV Secure Nested Paging | SEV extension adding memory integrity + launch measurement + attestation |
| TDX | Trust Domain Extensions | Intel's equivalent confidential-VM technology (for comparison) |

### AMD-Specific

| Acronym | Full Name | Description |
| --------- | ----------- | ------------- |
| PSP | Platform Security Processor | AMD's on-die security coprocessor; generates and signs the SNP attestation report with the VCEK |
| GHCB | Guest-Hypervisor Communication Block | Shared memory page the guest uses to talk to the PSP (e.g. `GET_REPORT`) |
| VCEK | VM Certificate Key | Per-launch-identity key the PSP uses to sign reports; chained to the ASK |
| VLEK | VM Launch Encryption Key | Key used to encrypt the guest's launch secret (for direct launch) |
| ARK | AMD Root Key | AMD's root-of-trust certificate (top of the chain) |
| ASK | AMD Signing Key | AMD's signing key, signed by the ARK; signs VCEKs |
| KDS | Key Distribution Service | AMD's service that serves the ARK/ASK/VCEK chain and TCB info |
| launch_digest | Launch Digest | 384-bit measurement of the guest launch (OVMF, kernel, initrd, VMSA) — the SNP equivalent of TDX's MRTD + RTMRs |
| id_block | Identity Block | 32-byte guest family identifier set by the VMM at launch |
| id_auth | Identity Auth | 32-byte guest author identifier set by the VMM at launch |
| VMPL | VM Privilege Level | SEV-SNP privilege level (0 = guest OS, 1–3 = more privileged) |
| VMSA | VM Save Area | The initial CPU/register state of the guest at launch |
| reported_tcb | Reported TCB | The firmware/TEE/microcode TCB the guest was launched with (checked against KDS) |
| report_data | Report Data | 64-byte field in the report the caller can bind to a nonce or a TEE key |
| policy | Launch Policy | 64-bit launch policy bits (default `0x30000`) controlling SNP launch options |
| TCB | Trusted Computing Base | Set of hardware/firmware/software critical to platform security (evaluated by KDS) |
| SVN | Security Version Number | Monotonically increasing counter reflecting security patch level |

### Attestation & Cryptography

| Acronym | Full Name | Description |
| --------- | ----------- | ------------- |
| EAR | EAT Attestation Result | JWT built on EAT (RFC 9711) used by Trustee to convey appraisal outcomes |
| EAT | Entity Attestation Token | IETF token format underlying EAR |
| RATS | Remote ATtestation procedureS | IETF architecture (RFC 9334) defining Attester / Verifier / Relying Party roles |
| KBS | Key Broker Service | Trustee component that brokers secrets after successful attestation |
| CoCo | Confidential Containers | Industry project for running containers in TEE-backed VMs |
| AS | Attestation Service | Trustee component that receives attestation requests and verifies evidence |
| RVPS | Reference Value Provider Service | Trustee component for storing and serving reference values to the policy engine |
| Rego | Rego (OPA policy language) | Policy language used by Open Policy Agent (OPA); Trustee uses it for attestation policies |
| JWT | JSON Web Token | Token format used in attestation responses |
| JWKS | JSON Web Key Set | Format for publishing public keys used to verify JWT signatures |
| JWE | JSON Web Encryption | Format for encrypted payloads (used by KBS secret delivery) |
| DER | Distinguished Encoding Rules | Binary encoding format for X.509 certificates |
| PEM | Privacy-Enhanced Mail | Base64-encoded encoding of DER certificates with header/footer |
| ECDSA | Elliptic Curve Digital Signature Algorithm | Signature algorithm used by the VCEK (P-384) and the CoCo-AS signer (P-256) |
| SHA384 | Secure Hash Algorithm 384-bit | Hash function used for the launch digest and `report_data` binding |
| base64 | Base64 | Encoding format for binary data in JSON evidence |

### Virtualization & Infrastructure

| Acronym | Full Name | Description |
| --------- | ----------- | ------------- |
| QEMU | Quick Emulator | Open-source machine emulator and virtualizer |
| KVM | Kernel-based Virtual Machine | Linux kernel module providing virtualization infrastructure |
| Libvirt | libvirt | Virtualization management API and tool suite |
| OVMF | Open Virtual Machine Firmware | EDK2 UEFI firmware implementation for virtual machines |
| EDK2 | EFI Development Kit 2 | Open-source UEFI/BIOS implementation |
| UEFI | Unified Extensible Firmware Interface | Modern firmware interface replacing BIOS |
| RPM | RPM Package Manager | Package format used by SUSE/RHEL distributions |
| SLES | SUSE Linux Enterprise Server | The reference distribution for this guide |
| JSON | JavaScript Object Notation | Data interchange format used in attestation evidence |
| HTTP | Hypertext Transfer Protocol | Network protocol used for KBS REST and AMD KDS collateral |
| Rust | Rust | Programming language used by Trustee |

### Trustee-Specific

| Acronym | Full Name | Description |
| --------- | ----------- | ------------- |
| Trustee | Trustee (CoCo project) | The confidential container attestation framework (KBS + AS) |
| CoCoAS | Confidential Containers Attestation Service | Trustee's attestation service adapter layer |
| attester | Attester | Client component that collects and submits TEE evidence |
| verifier | Verifier | Trustee component that validates TEE evidence and generates claims (`snp_verifier` for SEV-SNP) |
| tenant | Tenant | The workload owner whose VM/containers are being attested |

### General

| Acronym | Full Name | Description |
| --------- | ----------- | ------------- |
| VM | Virtual Machine | Isolated computing environment |
| Hypervisor | Hypervisor | Software/hardware layer managing VMs |
| ioctl | I/O Control | System call for device-specific operations (used by `snp-report-gen` on `/dev/sev-guest`) |
| API | Application Programming Interface | Interface for software components to communicate |
| CLI | Command Line Interface | User command interface |
| gRPC | gRPC (HTTP/2-based RPC) | RPC framework used by Trustee for inter-component communication |
| REST | Representational State Transfer | HTTP-based API style used by the KBS |
| DNS | Domain Name System | Network service for resolving hostnames |
| ISO | International Organization for Standardization | Standards body |
| NIST | National Institute of Standards and Technology | US agency that standardized several crypto algorithms |

---

## License

Copyright (C) 2026 aginies
Source: [https://github.com/aginies/coco_snp](https://github.com/aginies/coco_snp)

This program is free software: you can redistribute it and/or modify it under
the terms of the **GNU General Public License, version 3** as published by the
Free Software Foundation. See the [`LICENSE`](LICENSE) file for the full text.

`snp-attest.sh` prints the classic GPL notice when run interactively, and
`show-w` / `show-c` print the warranty / copyright terms:

```bash
sudo ./snp-attest.sh show-w   # warranty terms (no warranty)
sudo ./snp-attest.sh show-c   # copyright & license terms
```
