#!/usr/bin/env python3
# =============================================================================
#  snp-evidence.py — wrap a raw SEV-SNP report as CoCo-AS evidence.
#
#  CoCo-AS (Trustee) `attestation.AttestationService/AttestationEvaluate` does
#  NOT take the raw report bytes as `evidence`. The gRPC handler decodes the
#  proto `bytes` field with base64 URL-safe *no-padding* and then runs
#      serde_json::from_slice::<serde_json::Value>()
#  which must deserialize into verifier::snp::SnpEvidence:
#
#      struct SnpEvidence {
#          attestation_report: AttestationReport,   # sev crate struct
#          cert_chain: Option<Vec<CertTableEntry>>,
#      }
#
#  So the evidence value is the *JSON serialisation* of the parsed
#  AttestationReport (serde field names; [u8;N] -> JSON arrays via
#  serde_big_array; TcbVersion / Version -> objects). Sending the raw binary
#  instead produces "Illegal input Evidence: Invalid symbol ...".
#
#  This tool reads a base64 (standard) SEV-SNP attestation report and prints
#  the base64 URL-safe NO-PAD JSON evidence on stdout, ready to drop into the
#  `evidence` field of the attestation request JSON.
#
#  Report layout: the report produced by the SEV-SNP firmware (snpguest / the
#  kernel ioctl) uses a header that is 8 bytes *longer* than the decoder
#  committed to the v0.22.0 tag. The offsets below match the sev crate used by
#  the installed trustee package; they were verified against `snphost show
#  identifier / tcb`. See the AMD SEV-SNP attestation report specification for
#  the field-by-field layout.
# =============================================================================
import base64
import json
import sys


def u32(r, o):
    return int.from_bytes(r[o:o + 4], "little")


def u64(r, o):
    return int.from_bytes(r[o:o + 8], "little")


def tcb(r, o):
    # legacy Genoa/Milan TCB layout:
    #   [bootloader, tee, 0, 0, 0, 0, snp, microcode]
    return {"fmc": None,
            "bootloader": r[o],
            "tee": r[o + 1],
            "snp": r[o + 6],
            "microcode": r[o + 7]}


def version(r, o):
    # [build, minor, major]
    return {"major": r[o + 2], "minor": r[o + 1], "build": r[o]}


def parse_report(r):
    if len(r) != 1184:
        raise SystemExit(
            f"SEV-SNP report must be 1184 bytes, got {len(r)}")

    report_version = u32(r, 0)
    # ReportVariant: 2 -> V2, 3|4 -> V3, anything else -> V5.
    if report_version not in (2, 3, 4):
        variant = "V5"
    elif report_version == 2:
        variant = "V2"
    else:
        variant = "V3"

    o = 0

    def take(n):
        nonlocal o
        d = r[o:o + n]
        o += n
        return d

    fields = {}
    fields["version"] = u32(r, o)
    o += 4
    fields["guest_svn"] = u32(r, o)
    o += 4
    fields["policy"] = u32(r, o)
    o += 4
    fields["family_id"] = list(take(16))
    fields["image_id"] = list(take(16))
    fields["vmpl"] = u32(r, o)
    o += 4
    take(4)                       # reserved (firmware layout)
    fields["sig_algo"] = u32(r, o)
    o += 4
    fields["current_tcb"] = tcb(r, o)
    o += 8
    fields["plat_info"] = u32(r, o)
    o += 4
    fields["key_info"] = u32(r, o)
    o += 4
    take(8)                       # reserved (firmware layout, 8 not 4)
    fields["report_data"] = list(take(64))
    fields["measurement"] = list(take(48))
    fields["host_data"] = list(take(32))
    fields["id_key_digest"] = list(take(48))
    fields["author_key_digest"] = list(take(48))
    fields["report_id"] = list(take(32))
    fields["report_id_ma"] = list(take(32))
    fields["reported_tcb"] = tcb(r, o)
    o += 8

    if variant == "V2":
        fields["cpuid_fam_id"] = None
        fields["cpuid_mod_id"] = None
        fields["cpuid_step"] = None
        take(21)
        fields["chip_id"] = list(take(64))
    else:
        fields["cpuid_fam_id"] = take(1)[0]
        fields["cpuid_mod_id"] = take(1)[0]
        fields["cpuid_step"] = take(1)[0]
        take(21)
        fields["chip_id"] = list(take(64))

    fields["committed_tcb"] = tcb(r, o)
    o += 8
    fields["current"] = version(r, o)
    o += 3
    take(1)
    fields["committed"] = version(r, o)
    o += 3
    take(1)
    fields["launch_tcb"] = tcb(r, o)
    o += 8

    if variant == "V5":
        fields["launch_mit_vector"] = u64(r, o)
        o += 8
        fields["current_mit_vector"] = u64(r, o)
        o += 8
        take(152)
    else:
        fields["launch_mit_vector"] = None
        fields["current_mit_vector"] = None
        take(168)

    signature = take(144)
    fields["signature"] = {"r": list(signature[:72]),
                           "s": list(signature[72:])}
    return {"attestation_report": fields}


def processor_generation(fam, mod):
    # Mirrors trustee deps/verifier/src/snp/mod.rs get_processor_generation().
    if fam == 0x19:
        if mod <= 0x0F:
            return "Milan"
        if 0x10 <= mod <= 0x1F or 0xA0 <= mod < 0xAF:
            return "Genoa"
    elif fam == 0x1A and mod <= 0x11:
        return "Turin"
    raise SystemExit(
        f"unsupported processor (cpuid family 0x{fam:x} model 0x{mod:x})")


def vcek_params(r):
    """Return the VCEK lookup keys for a raw report.

    Same derivation as the trustee 0.23 snp_verifier (fetch_vcek_from_kds /
    fetch_vcek_from_offline_store), so the host can fetch the VCEK from AMD
    KDS and drop it where CoCo-AS's OfflineStore source looks for it:
        <store>/vcek/<hw_id>/<tcb_prefix>_vcek.der
    """
    ev = parse_report(r)["attestation_report"]
    fam, mod = ev["cpuid_fam_id"], ev["cpuid_mod_id"]
    if fam is None:
        raise SystemExit("report version 2 has no CPUID: cannot pick the "
                         "processor generation (need report v3+)")
    gen = processor_generation(fam, mod)
    chip_id = bytes(ev["chip_id"])
    if chip_id == bytes(64):
        raise SystemExit("chip_id is all zeros (MASK_CHIP_ID set?): "
                         "cannot look up the VCEK")
    # reported_tcb raw bytes: Turin uses [fmc, bl, tee, snp, 0, 0, 0, ucode],
    # Milan/Genoa [bl, tee, 0, 0, 0, 0, snp, ucode].
    t = r[0x180:0x188]
    if gen == "Turin":
        hw_id = chip_id[:8].hex()
        fmc, bl, tee, snp, ucode = t[0], t[1], t[2], t[3], t[7]
        prefix = f"bl{bl:02}_tee{tee:02}_snp{snp:02}_ucode{ucode:02}_fmc{fmc:02}"
        query = (f"fmcSPL={fmc:02}&blSPL={bl:02}&teeSPL={tee:02}"
                 f"&snpSPL={snp:02}&ucodeSPL={ucode:02}")
    else:
        hw_id = chip_id.hex()
        bl, tee, snp, ucode = t[0], t[1], t[6], t[7]
        prefix = f"bl{bl:02}_tee{tee:02}_snp{snp:02}_ucode{ucode:02}"
        query = f"blSPL={bl:02}&teeSPL={tee:02}&snpSPL={snp:02}&ucodeSPL={ucode:02}"
    return gen, hw_id, prefix, query


def main(argv):
    params = False
    args = argv[1:]
    if args and args[0] == "--vcek-params":
        # Print "<gen> <hw_id> <tcb_prefix> <kds_query>" instead of evidence.
        params = True
        args = args[1:]
    if args:
        b64 = args[0].encode()
    else:
        b64 = sys.stdin.buffer.read()
    b64 = b64.strip()
    raw = base64.b64decode(b64)          # standard base64 of the raw report
    if params:
        sys.stdout.write(" ".join(vcek_params(raw)) + "\n")
        return 0
    evidence = parse_report(raw)
    text = json.dumps(evidence, separators=(",", ":"))
    # proto `bytes` field: base64 URL-safe, NO padding.
    out = base64.urlsafe_b64encode(text.encode()).rstrip(b"=").decode()
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
