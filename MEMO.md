# MEMO — AMD SEV-SNP Remote Attestation

**One line:** prove, to a remote party, that a workload runs inside a genuine, untampered AMD SEV-SNP confidential VM — and release a secret or data only once that proof checks out.

SEV-SNP (Secure Encrypted Virtualization — **S**ecure **N**ested **P**aging) is AMD's confidential-VM technology. It makes a VM's memory **encrypted** (isolated from the hypervisor and other tenants) **and** **integrity-protected** (any tampering is detected). Remote attestation extends that hardware guarantee outward: a verifier gets cryptographically signed, machine-checkable claims about *where*, *how*, and *what* ran — before trusting the guest.

---

## 1. The SEV family

| Tech | Protects | Notes |
| --- | --- | --- |
| **SEV** | Guest memory encryption | Hypervisor can't read RAM. |
| **SEV-ES** | Memory + CPU register state | Encrypts the VMSA (registers) too. |
| **SEV-SNP** | Memory **+** integrity **+** launch measurement **+** attestation | Adds nested paging (per-page ownership), a signed attestation report, and VMPL privilege levels. This memo. |

**SNP's three guarantees:**
1. **Memory encryption** — data and metadata (page tables) are encrypted at rest in RAM.
2. **Memory integrity** — each page has an owner (guest OS vs hypervisor); a malicious hypervisor cannot read *or* silently rewrite guest pages.
3. **Launch measurement + attestation** — the guest's entire boot chain is measured into one digest and signed by hardware, producing a report a remote party can verify.

---

## 2. The trust anchor: the PSP

All security operations centre on the **Platform Security Processor (PSP)** — an on-die security coprocessor in AMD EPYC (Rome / Genoa / Turin+).

| Component | Role |
| --- | --- |
| **PSP** | AMD's on-die security coprocessor; generates and signs SNP reports. |
| **GHCB** | Guest-Hypervisor Communication Block — a shared page the guest uses to talk to the PSP (e.g. the `GET_REPORT` request). |
| **VCEK** | VM Certificate Key — per-launch-identity key the PSP uses to sign reports; chained to the ASK. |
| **VLEK** | VM Launch Encryption Key — encrypts the guest's launch secret (direct launch). |
| **VMSA** | VM Save Area — the initial CPU/register state at launch. |
| **VMPL** | VM Privilege Level — 0 = guest OS, 1–3 = more privileged (e.g. hypervisor at VMPL 3). |

The signing key never leaves the CPU and the measurement is bound to silicon, so a report **cannot be forged in software** — even a compromised hypervisor cannot mint a valid one.

---

## 3. The attestation report (4000 bytes)

The guest asks the PSP for a report over the GHCB channel. The PSP measures the guest's whole launch state (OVMF → kernel → initrd → VMSA) into a single **launch digest** and signs the result with the **VCEK**. Key fields:

| Field | Size | Meaning |
| --- | --- | --- |
| `launch_digest` | 48 B (384-bit) | The guest's launch state — SNP's equivalent of TDX's MRTD + RTMRs rolled into one. |
| `id_block` / `id_auth` | 32 B each | Guest family / author identifiers set by the VMM at launch. |
| `reported_tcb` | — | Firmware / TEE / microcode TCB the guest launched with (checked against KDS). |
| `policy` | 64 B | Launch policy bits (default `0x30000`). |
| `vmpl` | — | Privilege level (0 = guest OS). |
| `report_data` | 64 B | Caller-chosen field, bound to a nonce or a TEE public key. |
| `svn` | — | Security Version Number — monotonically increasing patch level. |

**Measurement model — SNP vs TDX:** TDX has four extend-only **RTMR** registers (per-stage granularity). SNP extends a *single* running digest as the firmware walks the boot chain — simpler to reason about (one value to enroll) but without per-stage split.

---

## 4. The certificate chain (ARK → ASK → VCEK)

To verify a report's signature, the verifier needs the key that signed it — that chain comes from **AMD KDS (Key Distribution Service)**:

```
ARK  (AMD Root Key — trust anchor)
 └─ ASK  (AMD Signing Key — signed by ARK)
     └─ VCEK  (per-launch-identity — signed by ASK)  ← signs the report
```

- **Remote mode:** fetched live from `https://kdsintf.amd.com/vcek/v1`.
- **Offline mode:** imported once into a local store (`/var/lib/sev-snp/certs/{ark,ask,vcek}.pem`).

**No per-platform registration.** Unlike Intel TDX (which must register the platform before PCK certificates are issued), the SNP VCEK is *derived from the launch measurement itself* and chains to AMD's public ARK/ASK. This removes an entire setup step and a whole class of host-side quote bugs.

---

## 5. The remote attestation flow

```
GUEST                              HOST
  │ 1. snpguest report  ────────────▶│ PSP signs report with VCEK (in-guest, over GHCB)
  │    4000-byte report              │
  │ 2. report → host over SSH        │  (or in-guest kbs-client → KBS over HTTP:8080)
  │                                  │ 3. Wrap report as CoCo-AS SnpEvidence evidence
  │                                  │ 4. grpcurl → CoCo-AS (127.0.0.1:3000)
  │                                  │    ├─ verify VCEK signature (ARK→ASK→VCEK)
  │                                  │    ├─ check reported TCB against KDS
  │                                  │    ├─ compare launch identity vs RVPS reference values
  │                                  │    └─ sign an EAR token (JWT)
  │                                  │ 5. KBS reads EAR claims + allow decision
  │ 6. secret released ◀─────────────┤ 7. KBS releases secret only if allow = true
```

**Two ways the report reaches KBS:**
- **Method A (in-guest):** an SNP-enabled `kbs-client` *inside* the VM generates a real report, sends it to KBS, which forwards it to CoCo-AS and streams the secret back. The fetching client *is* the attested entity.
- **Method B (host-side):** the host fetches the report over SSH, wraps it, and submits it to CoCo-AS via `grpcurl`; it then fetches the secret and decrypts the JWE locally. Simpler, but the EAR token and TEE key sit on the host.

**Decision = `ear.status`:**
- **`affirming`** — verified against KDS *and* launch identity matches enrolled reference values. Success.
- **`warning`** — hardware verified, but a non-critical claim is off (e.g. TCB `OutOfDate`, stale KDS cache).
- **`contraindicated`** — hardware verified but no / mismatched reference values in RVPS.

---

## 6. EAR tokens & the Trustee components

- **EAR (EAT Attestation Result)** — a JWT built on the IETF **EAT** (RFC 9711). It has the standard `header.payload.signature` shape; the payload carries the measured claims (`id_block`, `id_auth`, `launch_digest`, TCB, policy, vmpl) plus `allow: true/false` and issuer/expiry.
- **Why EAR:** the raw SNP report is binary and AMD-specific. The EAR token **normalises** it into JSON, **adds** the `allow` decision, and **makes it portable** — KBS doesn't need to understand SEV-SNP, just verify the JWT signature (via the JWKS) and read `allow`.
- **CoCo-AS (grpc-as)** — the verifier: checks signature + TCB + launch identity, returns the EAR token. For SNP it uses the **`snp_verifier`**.
- **KBS (Key Broker Service)** — the vault: stores secrets and releases one only to a client that (1) attests successfully and (2) passes the resource policy (Rego).
- **RVPS (Reference Value Provider Service)** — stores the expected launch identity that CoCo-AS compares against. Reference values are enrolled once (e.g. `register-rv`) and **persist**; a plain attestation returns `affirming` as long as they match. This Trustee version's evidence carries a set of `in` (list) and `==` (scalar) fields, so reference values are derived from the report itself rather than a single launch digest.

---

## 7. SEV-SNP vs Intel TDX (attestation data path)

| | SEV-SNP (AMD) | TDX (Intel) |
| --- | --- | --- |
| Who signs the quote | Guest's **PSP** (in-guest) | Host-side **QGS** daemon |
| Channel | GHCB | vsock |
| Collateral source | AMD **KDS** (ARK/ASK/VCEK) | Intel **PCS** (PCK) |
| Platform registration | **None** | Required (PCK issuance) |
| Offline collateral | 3 PEM files | Full **PCCS** server (Node.js + SQLite) |
| Setup cost | No `setup-qgs`, no quote path | Quote daemon + registration |

---

## 8. Air-gapped / offline

SNP's offline mode needs **only three PEM files** (ARK/ASK/VCEK) — no PCCS server, no online registration. Fetch the chain once while online (`setup-host`, or `snphost import`), verify with `check --collateral offline`, then run the whole stack with `--collateral offline`. The flow is identical; only the collateral source changes (local store instead of KDS). ARK/ASK are long-lived; the VCEK is per-launch-identity, so changing the guest's launch identity (different OVMF/kernel → different `launch_digest`) requires a fresh VCEK.

---

## 9. Why it matters

Attestation turns *"I trust the VM"* into *"I have cryptographic proof the VM is genuine and untampered."* **Remote** attestation adds the relying-party layer: a verifier (or KBS) can gate secrets, data, or compute access on verified hardware + firmware + software claims. That is the foundation of confidential computing, secure multi-tenant workloads, and zero-trust deployment — where trust is continuously proven, not merely asserted.
