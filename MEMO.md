# MEMO — AMD SEV-SNP Remote Attestation

**One line:** prove, to a remote party, that a workload is running inside a genuine, untampered AMD SEV-SNP confidential VM — and nothing else.

SEV-SNP (Secure Encrypted Virtualization — Secure Nested Paging) makes a VM's memory **encrypted** (isolation from the hypervisor) **and** **integrity-protected** (detection of tampering). Attestation extends that guarantee remotely: the relying party gets cryptographically verified claims about *where*, *how*, and *what* ran, before trusting the guest with a secret or data.

---

## 1. The trust anchor: the PSP

All security operations centre on the **Platform Security Processor (PSP)** — an on-die security coprocessor dedicated to the AMD EPYC (Rome / Genoa / Turin+) CPU.

| Role | Detail |
| --- | --- |
| **PSP** | AMD's on-die security coprocessor; generates and signs SNP reports. |
| **GHCB** | Guest-Hypervisor Communication Block — a shared memory page the guest uses to talk to the PSP (e.g. the `GET_REPORT` request). |
| **VCEK** | VM Certificate Key — a per-launch-identity key the PSP uses to sign reports; chained to the ASK. |
| **VLEK** | VM Launch Encryption Key — encrypts the guest's launch secret (direct launch). |
| **VMSA** | VM Save Area — the initial CPU/register state of the guest at launch. |

Because the PSP is silicon, the signing key never leaves the CPU and the measurement is bound to hardware — you cannot forge a report in software.

---

## 2. The attestation report (4000 bytes)

The guest asks the PSP for a report over the GHCB channel. The PSP measures the guest's entire launch state (OVMF → kernel → initrd → VMSA) into a single **launch digest**, and signs the result with the **VCEK**. Key fields:

| Field | Size | Meaning |
| --- | --- | --- |
| `launch_digest` | 48 B (384-bit) | The guest's launch state — the SNP equivalent of TDX's MRTD + RTMRs rolled into one. |
| `id_block` / `id_auth` | 32 B each | Guest family / author identifiers set by the VMM at launch. |
| `reported_tcb` | — | Firmware / TEE / microcode TCB the guest launched with (checked against KDS). |
| `policy` | 64 B | Launch policy bits (default `0x30000`). |
| `vmpl` | — | Privilege level (0 = guest OS, 1–3 = more privileged). |
| `report_data` | 64 B | Caller-chosen field, bound to a nonce or a TEE public key. |
| `svn` | — | Security Version Number — monotonically increasing patch level. |

**SNP vs TDX measurement model:** TDX has four extend-only **RTMR** registers (per-stage granularity). SNP extends a *single* running digest as the firmware walks the boot chain — simpler to reason about (one value to enroll) but no per-stage split.

---

## 3. The certificate chain (ARK → ASK → VCEK)

To verify a report's signature, the verifier needs the key that signed it. That chain comes from **AMD KDS (Key Distribution Service)**:

```
ARK  (AMD Root Key — trust anchor)
 └─ ASK  (AMD Signing Key — signed by ARK)
     └─ VCEK  (per-launch-identity — signed by ASK)  ← signs the report
```

- **Remote mode:** fetched live from `https://kdsintf.amd.com/vcek/v1`.
- **Offline mode:** imported once into a local store (`/var/lib/sev-snp/certs/{ark,ask,vcek}.pem`).

Unlike Intel TDX, there is **no per-platform registration** and **no PCK certificate** — the VCEK is derived from the launch measurement itself. This removes an entire setup step and a class of host-side quote bugs.

---

## 4. The remote attestation flow

```
GUEST                              HOST
  │  1. snpguest report  ──────────▶ │  PSP signs report with VCEK (in-guest, over GHCB)
  │     4000-byte report             │
  │  2. report → host over SSH       │
  │                                 │  3. Wrap report as CoCo-AS SnpEvidence evidence
  │                                 │  4. grpcurl → CoCo-AS (127.0.0.1:3000)
  │                                 │     ├─ verify VCEK signature (ARK→ASK→VCEK)
  │                                 │     ├─ check reported TCB against KDS
  │                                 │     ├─ compare launch identity vs RVPS reference values
  │                                 │     └─ sign an EAR token (JWT)
  │                                 │  5. KBS reads EAR claims + allow decision
  │  6. secret released ◀────────────┤  7. KBS releases secret only if allow = true
```

**Decision = `ear.status`:**
- **`affirming`** — verified against KDS *and* launch identity matches enrolled reference values. Success.
- **`warning`** — hardware verified, but a non-critical claim is off (e.g. TCB `OutOfDate`, stale KDS cache).
- **`contraindicated`** — hardware verified but no / mismatched reference values in RVPS.

---

## 5. EAR tokens & KBS

- **EAR (EAT Attestation Result)** — a JWT built on the IETF **EAT** (RFC 9711). It normalises the binary report into standard JSON, adds the `allow` policy decision, and is portable.
- KBS verifies the EAR signature with the JWKS (the signer's public key) and reads `allow` **without** re-doing the attestation — portable proof that "this guest was verified".
- **KBS (Key Broker Service)** stores secrets and releases one only to a client that (1) attests successfully and (2) passes the resource policy (Rego).
- **RVPS (Reference Value Provider Service)** stores the expected launch identity that CoCo-AS compares against. Reference values are enrolled once (e.g. `register-rv`) and persist; plain attestation returns `affirming` as long as they match.

---

## 6. SEV-SNP vs Intel TDX (attestation data path)

| | SEV-SNP (AMD) | TDX (Intel) |
| --- | --- | --- |
| Who signs the quote | Guest's **PSP** (in-guest) | Host-side **QGS** daemon |
| Channel | GHCB | vsock |
| Collateral source | AMD **KDS** (ARK/ASK/VCEK) | Intel **PCS** (PCK) |
| Platform registration | **None** | Required (PCK issuance) |
| Setup cost | No `setup-qgs`, no quote path | Quote daemon + registration |

---

## 7. Why it matters

Attestation turns "I trust the VM" into "I have cryptographic proof the VM is genuine and untampered." Enabling **remote** attestation adds the relying-party layer: a verifier (or KBS) can gate secrets, data, or compute access on verified hardware + firmware + software claims — the foundation of confidential computing, secure multi-tenant workloads, and zero-trust deployment.
