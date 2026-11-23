# Trustee 0.23: grpc-as panics on every attestation request

Status: **open upstream** (no fix on `confidential-containers/trustee` `main`
as of commit `9dd128c`, 2026-11-23). **Workaround implemented in this repo**:
CoCo-AS uses only the `OfflineStore` VCEK source, and `snp-attest.sh` fills
that store from AMD KDS with `curl` on the host. `grpc-as` never builds its own
HTTPS client.

The same bug was first seen on Intel TDX (DCAP collateral client, see the
TDX twin repo). On SEV-SNP it is hit through the VCEK fetch.

## Symptom

`./snp-attest.sh attest` fails:

```
grpcurl call failed:
  Code: Canceled
  Message: stream terminated by RST_STREAM with error code: CANCEL
```

`journalctl -u grpc-as.service`:

```
grpc_as::grpc: AttestationEvaluate API called.
thread 'tokio-rt-worker' panicked at .../vendor/reqwest-0.13.5/src/async_impl/client.rs:2524:38:
Client::new(): reqwest::Error { kind: Builder, source: Normal(ErrorStack([])) }
```

If the service is then stopped, `attest` reports
`dial tcp 127.0.0.1:3000: connect: connection refused`.

## Environment where it was observed

| Item | Value |
|------|-------|
| OS | SLES 16.1 |
| trustee | `0.23.0~git0.564a3ba5-SGX.1610.2.1` (Virtualization:SGX), **broken** |
| trustee | `0.22.0~git0.512fed6-SGX.1610.2.1`, **works** |
| libopenssl3 | `3.5.0-160100.3.2` (unchanged between working and broken) |
| crypto-policies | `20250714.cd6043a-160100.2.1`, policy `DEFAULT`, FIPS off |
| Service user | `coco_as`, `OPENSSL_CONF=/etc/ssl/openssl.cnf` (readable) |

## Root cause

### 1. The in-process HTTPS client panics

The SNP verifier in 0.23 (`deps/verifier/src/snp/mod.rs`) fetches the VCEK
from AMD KDS itself when the evidence carries no certificate chain (the
`attest` flow and the guest `kbs-client` send only the report):

```rust
fn build_vcek_client(&self) -> reqwest_middleware::ClientWithMiddleware {
    ...
    ClientBuilder::new(reqwest::Client::new())   // line 150
```

- `reqwest::Client::new()` **panics** if the TLS backend fails to initialise
  (it is `Client::builder().build().expect("Client::new()")`).
- `Normal(ErrorStack([]))` is a `native-tls` / OpenSSL error with an empty
  error queue: OpenSSL TLS context setup failed in the service process. The
  exact trigger on SLES 16.1 is still unknown.
- On SNP the client is built per request (not in a `LazyLock` as on the TDX
  DCAP path), so every request panics. The process does not get "poisoned".

### 2. The script's old verifier keys were ignored

0.23 reads only `vcek_sources` in `snp_verifier`:

```rust
pub struct SnpVerifierConfig {
    #[serde(default = "default_vcek_sources")]   // [ { "type": "KDS" } ]
    pub vcek_sources: Vec<VCEKSource>,
}
```

There is no `deny_unknown_fields`, so the keys older versions of this script
wrote (`collateral_service`, `local_collateral_path`, `use_secure_cert`) were
silently ignored. CoCo-AS fell back to the default `KDS` source, even with
`--collateral offline`, and so it always hit the panicking client.

Two separate problems to report:

1. **Upstream (trustee):** a TLS init failure crashes the request instead of
   returning an attestation error. `build_vcek_client` (and `pcs.rs` for
   DCAP) should use `Client::builder().build()` and propagate the error.
2. **Packaging / platform (SUSE):** why OpenSSL TLS init fails for `coco_as`
   on SLES 16.1.

Related reqwest 0.13 `Client::new()` panic reports (all rustls variants, none
with the OpenSSL `ErrorStack([])` form):
[progenitor #1440](https://github.com/oxidecomputer/progenitor/issues/1440),
[pixi #6825](https://github.com/prefix-dev/pixi/issues/6825),
[sccache #2917](https://github.com/mozilla/sccache/pull/2917),
[developing-today/code #12608](https://github.com/developing-today/code/issues/12608).

## Workaround implemented in `snp-attest.sh`

### Configuration (`setup-trustee`)

`/etc/grpc-as.json` now has a single `OfflineStore` VCEK source, in both
`--collateral kds` and `--collateral offline` mode:

```json
"verifier_config": {
  "snp_verifier": {
    "vcek_sources": [
      { "type": "OfflineStore", "path": "/var/lib/attestation-service/kds-store" }
    ]
  }
}
```

The `OfflineStore` source only reads files. It never constructs the reqwest
client, so the panic cannot happen. ARK and ASK are built into the verifier
(Milan / Genoa / Turin), so CoCo-AS needs only the VCEK.

The verifier looks for (trustee 0.23 layout):

```
<path>/vcek/<hw_id>/<tcb_prefix>_vcek.der   # preferred, one per TCB
<path>/vcek/<hw_id>/vcek.der                # fallback, flat
```

- `hw_id`: the report `chip_id` as lowercase hex (Turin: first 8 bytes only)
- `tcb_prefix`: `bl{BL}_tee{TEE}_snp{SNP}_ucode{UCODE}` from the report's
  reported TCB, 2-digit zero-padded. Turin appends `_fmc{FMC}`.

### Filling the store (`attest`, `secret-get`, `vcek-fetch`)

Before each report reaches CoCo-AS, `ensure_as_vcek` (in `lib/attest.sh`):

1. Derives the processor generation, `hw_id`, `tcb_prefix` and KDS query from
   the report: `tools/snp-evidence.py --vcek-params` uses the same rules as
   the verifier.
2. Returns early if `<tcb_prefix>_vcek.der` is already in the store.
3. Otherwise downloads
   `${KDS_URL}/<Gen>/<hw_id>?blSPL=..&teeSPL=..&snpSPL=..&ucodeSPL=..` with
   `curl` (system OpenSSL works fine in curl), checks that it is a DER X.509
   certificate, and installs it owned by `coco_as`.
4. If KDS is unreachable, it falls back to the snphost store
   (`/var/lib/sev-snp/certs/vcek.pem`, converted to DER) as the flat
   `vcek.der`. That works while the guest's reported TCB matches the TCB the
   VCEK was fetched for.

Where it runs:

- `attest` / `secret-get --mode host`: on the report that is about to be sent
  (`attest_evaluate_report`).
- `secret-get` (in-guest `kbs-client`): the report goes guest → KBS →
  CoCo-AS without passing through the script, so it first generates a report
  over ssh to prime the store.
- `vcek-fetch`: does the same on demand:

  ```bash
  sudo ./snp-attest.sh vcek-fetch --guest-ip <GUEST_IP>
  ```

  Re-run it after a host firmware / microcode update (new reported TCB means
  a new VCEK). `attest` does it automatically anyway.

### Upgrading an existing setup

```bash
sudo ./snp-attest.sh setup-trustee        # rewrites /etc/grpc-as.json, restarts grpc-as
sudo ./snp-attest.sh attest --guest-ip <GUEST_IP>
sudo ./snp-attest.sh verify               # "CoCo-AS VCEK source: OfflineStore" + store populated
```

`verify` FAILs on a config without `vcek_sources` (pre-0.23 layout) and WARNs
when the source is not `OfflineStore` or the store is empty.

### Notes

- **Trustee 0.22** has no `vcek_sources`, ignores the key, and keeps using
  its built-in KDS fetch, which works there. The same config works on both.
- **VCEKs do not expire like TDX collateral.** A VCEK is bound to the chip and
  a TCB version. Store entries stay valid until the platform TCB changes, and
  old entries are harmless.
- **Multi-host:** the store is keyed by `hw_id`, so VCEKs for several hosts
  can live side by side. Each one is added the first time a report from that
  chip is attested.
- **Back to the KDS source** once trustee is fixed: add
  `{ "type": "KDS" }` after the `OfflineStore` entry in `vcek_sources` (tried
  in order) and restart `grpc-as`.

## Other 0.23 change: EAR token claim layout

Upstream commit `5aceb8d` ("as: migrate EAR token to draft-04 claim layout",
BREAKING) renamed the token claims:

| trustee <= 0.22 | trustee >= 0.23 |
|-----------------|-----------------|
| `submods.cpu0."ear.status"` | `submods.cpu0.ear_status` |
| `"ear.trustworthiness-vector"` | `ear_trustworthiness_vector` |
| `"ear.veraison.annotated-evidence".snp.<claim>` | `ear_attester_claims.claims.<claim>` |

The SNP claim names themselves (`measurement`, `chip_id`,
`reported_tcb_*`, `policy_*`, `platform_*`) and the RVPS reference-value IDs
(`snp_launch_measurement`, `snp_bootloader`, ...) are unchanged.

`snp-attest.sh` parses both layouts (`snp_ear_fields`, `snp_rv_sample`, the
`--register-rv` re-evaluation). Without this, `attest` showed
`EAR Status: Unknown` and `register-rv` could not build the reference values
on 0.23. Any custom KBS policy that reads `ear.status` must switch to
`ear_status` (see upstream `kbs/sample_policies/affirming.rego`). The lab
policy written by `setup-trustee` is allow-all and is not affected.

## Alternative: downgrade to trustee 0.22

```bash
systemctl stop grpc-as kbs rvps
zypper in --oldpackage trustee-0.22.0~git0.512fed6-SGX.1610.2.1 \
                       system-user-coco_trustee-0.22.0~git0.512fed6-SGX.1610.2.1
zypper al trustee trustee-intel system-user-coco_trustee
systemctl restart grpc-as kbs rvps
```

`trustee-intel` is a new sub-package in 0.23; zypper offers to remove it.

## Data for the bug reports

To find which file OpenSSL fails on, temporarily put the `KDS` source back
(e.g. a scratch copy of `/etc/grpc-as.json` with
`"vcek_sources": [{"type": "KDS"}]`) and run:

```bash
systemctl stop grpc-as
sudo -u coco_as strace -f -e trace=openat -o /tmp/grpc-as.strace \
  /usr/libexec/grpc-as --socket 127.0.0.1:3000 --config-file /tmp/grpc-as-kds.json &
./snp-attest.sh attest --guest-ip <GUEST_IP>; kill %1
grep -E 'ENOENT|EACCES' /tmp/grpc-as.strace | grep -vE '\.so|locale' | tail -20
systemctl start grpc-as
```

Include: the panic line, trustee and libopenssl3 versions, SLES 16.1, "0.22
works", and the strace excerpt.

- Upstream: <https://github.com/confidential-containers/trustee/issues>.
  `snp/mod.rs` `build_vcek_client` and `intel_dcap/pcs.rs` should not panic
  on TLS init failure.
- SUSE: trustee package in Virtualization:SGX. OpenSSL TLS init fails for
  `coco_as`.

## Diagnostics added to `snp-attest.sh`

- Pre-flight before `grpcurl`: is `grpc-as.service` active, is the port
  listening (tells a crashed service from a stopped one).
- On failure, the CoCo-AS log dump drops Rust backtrace frames so the
  `panicked at` line stays visible.
- Recognises the `Client::new()` panic, a `LazyLock ... poisoned` state and
  `Failed to fetch VCEK`, and prints the matching hint.

## Sources

- [trustee v0.23.0 release](https://github.com/confidential-containers/trustee/releases/tag/v0.23.0)
- [trustee AS config docs (`vcek_sources`)](https://github.com/confidential-containers/trustee/blob/main/attestation-service/docs/config.md)
- [trustee offline AMD VCEK store guide](https://github.com/confidential-containers/trustee/blob/main/attestation-service/docs/amd-offline-certificate-cache.md)
- [AMD KDS VCEK API](https://www.amd.com/content/dam/amd/en/documents/epyc-technical-docs/specifications/57230.pdf)
- [progenitor #1440](https://github.com/oxidecomputer/progenitor/issues/1440)
- [pixi #6825](https://github.com/prefix-dev/pixi/issues/6825)
- [sccache PR #2917](https://github.com/mozilla/sccache/pull/2917)
- [developing-today/code #12608](https://github.com/developing-today/code/issues/12608)
