# AMD SEV-SNP Attestation — snphost (host-side verification)

**Scope:** SEV-SNP report generated in the guest; certificate chain + VLEK verified **on the host** via `snphost`. No Trustee.
**Basis:** SLES 16.1 source tree (`snphost-0.7.0`).
**Guest vs host:** blue = runs **inside the SNP VM (guest)**; orange = runs **on the host / platform** (CPU firmware, VMM, `snphost`).

---

## Flow

```mermaid
flowchart TD
    subgraph GUEST["GUEST (SNP VM) — inside the confidential VM"]
        A["snpguest report<br/>open /dev/sev-guest<br/>GET_REPORT via GHCB"]
        S["send report + cert chain → host"]
        A --> S
    end

    subgraph PLATFORM["HOST / PLATFORM — CPU + VMM"]
        D["AMD PSP / SEV firmware (HW)<br/>generates + signs report (VEK)"]
        E[("4000-byte AttestationReport<br/>report_data=nonce · launch-digest<br/>reported_tcb · policy · host_data")]
        D --> E
    end

    A -->|"GHCB GET_REPORT → platform"| D
    E --> S

    subgraph HOST["HOST — snphost verifier"]
        H1["snphost fetch<br/>VCEK / VLEK from AMD KDS"]
        H2["snphost verify certs<br/>chain ARK→ASK→VCEK (ECDSA P-384)"]
        H3["snphost verify vlek-hashstick<br/>(VLEK, Turin+)"]
        H4["host trust decision"]
        H1 --> H2 --> H4
        H1 --> H3 --> H4
    end

    S --> H1
    H4 --> R["attested / rejected<br/>(decision on host)"]

    classDef guest fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#0d47a1;
    classDef host fill:#fff3e0,stroke:#ef6c00,stroke-width:2px,color:#e65100;
    classDef neutral fill:#f5f5f5,stroke:#616161,color:#212121;
    class A,S guest;
    class D,E,H1,H2,H3,H4 host;
    class R neutral;
```

---

## Notes

- `snphost` verifies the **certificate chain on the host**: `verify certs` (ARK→ASK→VCEK) and `verify vlek-hashstick` (VLEK, Turin+).
- `snphost` is a host tool (`/dev/sev`): `fetch` (KDS), `import`/`export` (cert chain), `ok` (platform probe), `vlek-load` (load VLEK), `verify` (cert chain / VLEK hashstick).
- The guest still generates the report (via `snpguest report`); the host (`snphost`) verifies the cert chain.
- Note: full report binding (`report_data`/`host_data`/VMPL) is `snpguest`'s domain — `snphost verify` focuses on the cert chain + VLEK hashstick, not the report's nonce/host_data binding.

## Legend

| Term | Meaning |
|------|---------|
| **snphost** | Host CLI (`/dev/sev`). Subcommands: `show`, `export`, `import`, `ok` (probe), `config`, `verify` (certs / vlek-hashstick), `fetch` (KDS), `commit`, `vlek-load`. |
| **VEK** | Versioned Endorsement Key — **VCEK** (per-chip) or **VLEK** (cloud-provisioned, Turin+). Signs the report. |
| **VLEK hashstick** | Per-VM VLEK hash committed to the PSP; `snphost verify vlek-hashstick` validates it (Turin+). |
| **report_data** | 64-byte nonce/challenge field (bound by `snpguest`, not `snphost`). |
| **host_data** | 32-byte launch field (bound by `snpguest`, not `snphost`). |
| **launch-digest** | 48-byte (384-bit) measurement of guest launch (OVMF, kernel, initrd, VMSA). |
| **GHCB** | Guest-Hypervisor Communication Block — guest→firmware channel for `GET_REPORT`. |
| **ARK → ASK → VEK** | AMD cert chain: AMD Root Key → AMD Signing Key → Versioned Endorsement Key. |
| **KDS** | AMD Key Distribution Server — source of VCEK/VLEK certs. |
