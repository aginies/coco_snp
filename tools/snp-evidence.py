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


def main(argv):
    if len(argv) > 1:
        b64 = argv[1].encode()
    else:
        b64 = sys.stdin.buffer.read()
    b64 = b64.strip()
    raw = base64.b64decode(b64)          # standard base64 of the raw report
    evidence = parse_report(raw)
    text = json.dumps(evidence, separators=(",", ":"))
    # proto `bytes` field: base64 URL-safe, NO padding.
    out = base64.urlsafe_b64encode(text.encode()).rstrip(b"=").decode()
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
