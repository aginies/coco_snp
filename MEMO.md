# MEMO — SEV-SNP Attestation Toolkit (`snp-attest.sh`)

**Project:** AMD SEV-SNP remote attestation + secret delivery toolchain (Trustee / CoCo-AS).
**Repo:** `coco_snp` — `snp-attest.sh` + `lib/*.sh` (distro-pluggable; SLES/openSUSE implemented). Full docs: `README.md`.
**Host:** `genoa-sev1` (10.128.65.5) — snphost. **Guest:** VM `161` @ 192.168.122.239 (libvirt NAT). Chip: Genoa.
**Status:** ✅ Attestation works end-to-end; `ear.status = affirming`. Working tree clean on both local repo and snphost.

---

## What the toolkit does
Proves a guest is a genuine, untampered SEV-SNP confidential VM, then releases a secret only to it. The CPU's **PSP** signs a 4000-byte report in-guest with a **VCEK** (over GHCB) — no host quote daemon, no vsock, no per-platform registration. Collateral (ARK→ASK→VCEK) comes from **AMD KDS**. Flow: `snpguest report` → host fetches over SSH → wraps as CoCo-AS evidence → `grpcurl` to CoCo-AS (127.0.0.1:3000) → verifies sig + TCB + RVPS launch identity → signs **EAR token** (JWT/EAT) → KBS gates the secret.

## Commands
`check` → `setup-host` → `setup-trustee` → `setup-vm --guest-iso …` → (install OS via `virsh console`) → `setup-guest --guest-ip …` → `attest --guest-ip … [--register-rv]` → `secret-set` / `secret-get`. One-shot: `snp-attest.sh all`. Read-only audit: `verify`. Cleanup: `clean`.

---

## Bugs fixed & commits (newest first)

| Commit | Fix |
| --- | --- |
| `0d40d7b` Docs | Document empty-reused-disk detection + offer-to-remove (Step 4 + troubleshooting). |
| `6dea8ce` Code | **Offer to remove** an empty reused disk before install (interactive `y/N`, `--force` auto-remove, keep non-interactively). Fixed a `[[ -t 0 ]] && confirm` bug that blocked `--force` in non-interactive runs. Also guard generated-XML disk creation on file existence (avoids `qemu-img create: File already exists`). |
| `88a0865` Code | **Detect correctly:** a reused disk is "has OS" only with real partitions or a filesystem with a recognised VFS. An empty qcow2 is reported by `virt-filesystems` as `/dev/sda filesystem unknown`, which the old `grep -q .` matched → misdetected as has-OS. |
| `891dc60` Docs | Clarify `--register-rv` is only needed to *populate* RVPS; values **persist**, so plain `attest` already returns `affirming`. |
| `f687bc7` Docs | Reflect evidence-wrapper, reference-value derivation, msr probe, robust eval. |
| `c3bdb60` Code | **Derive reference values from the report** (was meaningless `"none"`). `snp_rv_sample()` builds the CoCo-AS sample from annotated evidence (`in`→JSON lists, `==`→scalars). Retry grpcurl 4×/5s for transient KDS VCEK failures. `snp_ear_fields` pipe+`|| true`+`return 0` (ERR-trap safe). |
| `6e71645` Code | **Core fix:** wrap raw report as CoCo-AS JSON `SnpEvidence` (was shipping raw bytes → `Illegal input Evidence: Invalid symbol …`). New `tools/snp-evidence.py`. Reads KDS verification from `ear.trustworthiness-vector.hardware` (no `submods.cpu0.tcb_status`). Probe `msr` module in setup-host. |
| `10795d2`…`b98c5d3` | Earlier: KDS URL, `snpguest` report gen, RVPS in-process, CLI fixes, SNP XML, licence, boot-param probes. |

---

## Key facts / gotchas
- **Evidence format:** `snp_verifier` base64url-decodes `evidence` then `serde_json`-parses into `SnpEvidence { attestation_report }` → report must be JSON first. `tools/snp-evidence.py` parses the firmware report layout (V2/V3/V5).
- **`register-rv`:** only needed to *initially populate* RVPS (`/var/lib/attestation-service/storage/reference_value/`). Values persist → plain `attest` returns `affirming`. RVPS has no `Delete` (only Query/Register), so values can't be removed via the toolkit.
- **Appraisal reads:** `ear.status` + `ear.trustworthiness-vector.hardware` (0–100). This Trustee build's annotated evidence has **no** `id_block`/`id_auth`/`launch_digest`/`submods` — hardware verification is `Unknown`/blank in the printed report but `affirming` still results from the `snp_*` measurement/TCB fields.
- **Disk reuse:** empty reused qcow2 → skip `virt-customize`; installer writes to it. Offer to remove for a clean install.
- **`check` probes:** added `msr` module (snphost reads per-CPU MSRs via `/dev/msr64`).
- **Guest reachability:** guest is behind snphost NAT (192.168.122.239); run `attest`/`setup-vm` *from* snphost, not from the management host.
- **Lab-only defaults:** allow-all Rego policy, KBS `insecure_http`/`InsecureAllowAll`, host-mode `secret-get` leaves EAR token on host.

---

## Verified on host
- Plain `./snp-attest.sh attest --guest-ip 192.168.122.239` (no `--register-rv`) → **`ear.status = affirming`**, EXIT=0.
- Detection logic tested: partitioned+ext4 disk → has-OS; empty reused disk → fresh.
- Both `lib/setup-vm.sh` fixes committed locally (`88a0865`, `6dea8ce`) and synced+committed on snphost (`da61006`).

## To reproduce / continue
```bash
# on snphost:
cd /root/coco_snp
./snp-attest.sh setup-vm --guest-iso /var/lib/libvirt/images/default/<SLE-*.iso>   # boots installer
virsh console 161                                                                   # install SLES
./snp-attest.sh setup-guest --guest-ip 192.168.122.239
./snp-attest.sh attest --guest-ip 192.168.122.239 --register-rv                     # → affirming
```
