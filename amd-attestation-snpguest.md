# AMD SEV-SNP Attestation — snpguest (in-guest verification)

**Scope:** SEV-SNP report generation + verification entirely via `snpguest` (runs in the guest). No Trustee.
**Basis:** SLES 16.1 source tree (`snpguest-0.10.0`).
**Guest vs host:** blue = runs **inside the SNP VM (guest)**; orange = runs **on the host / platform** (CPU firmware, VMM).

---

## Flow

```mermaid
flowchart TD
    subgraph GUEST["GUEST (SNP VM) — inside the confidential VM"]
        A["snpguest report<br/>open /dev/sev-guest<br/>GET_REPORT via GHCB"]
        G1["snpguest fetch<br/>VCEK / VLEK cert chain"]
        V1["snpguest verify (IN-GUEST)<br/>1 chain ARK→ASK→VEK (ECDSA P-384)<br/>2 verify report sig vs VEK<br/>3 verify TCB OIDs (bootloader/TEE/SNP/microcode/FMC)<br/>4 check VMPL == 0<br/>5 bind report_data (nonce)<br/>6 bind host_data"]
        A --> V1
        G1 --> V1
    end

    subgraph PLATFORM["HOST / PLATFORM — CPU + VMM"]
        D["AMD PSP / SEV firmware (HW)<br/>generates + signs report (VEK)"]
        E[("4000-byte AttestationReport<br/>report_data=nonce · launch-digest<br/>reported_tcb · policy · host_data")]
        F["VCEK / VLEK cert chain<br/>ARK → ASK → VEK (AMD KDS / offline store)"]
        D --> E
    end

    A -->|"GHCB GET_REPORT → platform"| D
    E --> V1
    F --> V1

    V1 --> H["attested / rejected<br/>(decision in guest)"]

    classDef guest fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#0d47a1;
    classDef host fill:#fff3e0,stroke:#ef6c00,stroke-width:2px,color:#e65100;
    classDef neutral fill:#f5f5f5,stroke:#616161,color:#212121;
    class A,G1,V1 guest;
    class D,E,F host;
    class H neutral;
```

---

## Notes

- `snpguest verify` does the **full report verification in the guest**: cert chain, report signature, TCB OIDs, VMPL, `report_data`, `host_data`.
- The guest only *triggers* report generation via GHCB; the report is produced and signed by the CPU's PSP (platform).
- `snpguest fetch` pulls the VCEK/VLEK chain (AMD KDS or offline store) so verification can run fully in-guest.
- `snpguest generate` (preattestation) computes the launch digest (OVMF/kernel/initrd/VMSA) before launch.

## Legend

| Term | Meaning |
|------|---------|
| **snpguest** | Guest CLI (`/dev/sev-guest`). Subcommands: `report` (request report), `fetch` (VCEK/VLEK), `verify` (verify report + certs), `generate` (preattestation launch digest). |
| **VEK** | Versioned Endorsement Key — **VCEK** (per-chip) or **VLEK** (cloud-provisioned, Turin+). Signs the report. |
| **report_data** | 64-byte nonce/challenge field; binding it proves freshness and ties the report to this session. |
| **host_data** | 32-byte field set at launch; binds the report to the VM's launch parameters. |
| **launch-digest** | 48-byte (384-bit) measurement of guest launch (OVMF, kernel, initrd, VMSA). |
| **TCB OIDs** | Five Service-Provider-Level checks in the VEK cert: bootloader, TEE, SNP, microcode, FMC (Turin+). |
| **VMPL** | VM Privilege Level. Verifier requires `VMPL == 0` (guest OS). |
| **GHCB** | Guest-Hypervisor Communication Block — guest→firmware channel for `GET_REPORT`. |
| **ARK → ASK → VEK** | AMD cert chain: AMD Root Key → AMD Signing Key → Versioned Endorsement Key. |
