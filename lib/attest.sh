# =============================================================================
# 7. REMOTE ATTESTATION  — AMD SEV-SNP
# =============================================================================

# Fetch a fresh SEV-SNP report from the guest, submit it to CoCo-AS via
# grpcurl, and return the EAR JWT in the global EAR_TOKEN. Returns 0 on
# success, 1 on failure. Shared by cmd_attest (allow-check) and secret-get
# --mode host (KBS REST fetch).
#
# Evaluate a given base64 SEV-SNP report against CoCo-AS and set EAR_TOKEN.
# Does NOT touch the guest — the report is supplied by the caller, so the same
# report can be re-evaluated (e.g. right after RVPS registration) without
# generating a fresh one.
#
# Evidence format: the CoCo-AS snp_verifier does NOT take the raw report
# bytes. The gRPC handler base64-URL-decodes the proto `evidence` field and
# then runs serde_json::from_slice::<serde_json::Value>(), which must
# deserialize into verifier::snp::SnpEvidence { attestation_report,
# cert_chain } — i.e. the JSON serialisation of the parsed AttestationReport
# (serde field names; [u8;N] -> JSON arrays; TcbVersion/Version -> objects).
# Sending the raw binary instead is not valid base64url and yields
# "Illegal input Evidence: Invalid symbol ...". snp_evidence_from_b64() performs
# that wrap: base64(raw report) -> JSON evidence -> base64url (no padding).
#
# Optional second argument: structured runtime data JSON (e.g.
# '{"tee-pubkey":"..."}'). When given, it is sent as runtime_data so the EAR
# token carries the matching attester_runtime_data claims (KBS needs the
# tee-pubkey claim to release resources); the report's report_data must then
# equal sha384(canonical JSON) zero-padded to 64 bytes.
# Wrap a base64 (standard) SEV-SNP attestation report as the base64 URL-safe
# NO-PAD JSON evidence that CoCo-AS's snp_verifier expects. The gRPC handler
# base64-decodes the proto `evidence` field and serde_json-parses it into
# SnpEvidence{ attestation_report } — the JSON serialisation of the parsed
# report — so we must serialise the parsed report, never ship the raw bytes
# (that yields "Illegal input Evidence: Invalid symbol ...").
# stdin/stdout: base64 report in, base64url evidence out.
snp_evidence_from_b64() {
    local report_b64="$1"
    require_cmd python3 base64
    [[ -f "${SCRIPT_DIR}/tools/snp-evidence.py" ]] \
        || die "missing tools/snp-evidence.py"
    printf '%s' "$report_b64" \
        | python3 "${SCRIPT_DIR}/tools/snp-evidence.py"
}

attest_evaluate_report() {
    local report_b64="$1"
    local runtime_data_json="${2:-}"
    require_cmd base64 python3
    ensure_grpcurl || die "grpcurl is required for attestation (see the hint above)."
    ensure_attestation_proto

    [[ -n "$report_b64" ]] || die "Empty report passed to attest_evaluate_report"

    log "Building attestation request JSON (Trustee 0.20 format, SNP)"
    # evidence must be the base64url (no-pad) JSON of the parsed report, not
    # the raw report bytes (see the note above this function).
    local evidence_b64
    evidence_b64=$(snp_evidence_from_b64 "$report_b64")
    [[ -n "$evidence_b64" ]] || die "Failed to build SNP evidence JSON (is python3 installed?)"

    local runtime_data_block=""
    if [[ -n "$runtime_data_json" ]]; then
        # Escape the inner JSON so it is a valid JSON string value. The proto
        # oneof runtime_data is mapped in JSON by the set field's name
        # (structured_runtime_data), not the oneof name.
        local escaped_json=${runtime_data_json//\"/\\\"}
        runtime_data_block=$(printf ',\n    "structured_runtime_data": "%s"' "$escaped_json")
    fi

    local req_file
    req_file=$(mktemp /tmp/snp-attest-req.XXXXXX)
    cat >"$req_file" <<EOF
{
  "verification_requests": [
    {
      "tee": "snp",
      "evidence": "${evidence_b64}"${runtime_data_block}
    }
  ],
  "policy_ids": ["default"]
}
EOF

    local response="" attempt=0 max_attempts=4
    log "Sending request via grpcurl to ${COCO_AS}"
    # AMD KDS is intermittently unavailable: a VCEK fetch can fail transiently,
    # especially for the back-to-back re-evaluation done by --register-rv.
    # Retry a few times with a short backoff instead of failing immediately.
    while ((attempt < max_attempts)); do
        attempt=$((attempt + 1))
        response=$(grpcurl -plaintext \
            -import-path "$PROTO_DIR" \
            -proto attestation.proto \
            -d @ \
            "${COCO_AS}" attestation.AttestationService/AttestationEvaluate <"$req_file" 2>&1) \
            && break
        warn "grpcurl attempt ${attempt}/${max_attempts} failed; retrying (AMD KDS may be transiently unavailable):"
        echo "$response" | tail -2 >&2
        sleep 5
    done
    if ! printf '%s' "$response" | grep -q '"attestationToken"'; then
        rm -f "$req_file"
        echo "" >&2
        error "=== CoCo-AS logs (journalctl -u grpc-as.service -n 30) ==="
        journalctl -u grpc-as.service -n 30 --no-pager >&2 2>/dev/null || true
        die "Attestation request failed after ${attempt} attempt(s)."
    fi
    rm -f "$req_file"

    log "CoCo-AS response:"
    echo "$response"

    log "Extracting EAR token"
    EAR_TOKEN=$(echo "$response" | grep -ioP '"attestation[_-]?token"\s*:\s*"\K[^"]+' || true)
    if [[ -z "$EAR_TOKEN" ]]; then
        error "No attestation token in response:"
        echo "$response" >&2
        die "CoCo-AS did not return a token"
    fi
    return 0
}

# Fetch a fresh report from the guest and evaluate it. The fetched report is
# stored in LAST_REPORT_B64 so it can be re-evaluated without a new guest
# round-trip (see attest_evaluate_report).
attest_get_ear_token() {
    require_cmd base64
    require_cmd ssh

    log "Generating fresh SEV-SNP report on guest"
    guest_generate_report

    log "Fetching report (base64)"
    local report_b64
    report_b64=$(ssh_guest "base64 -w0 ${GUEST_WORKDIR}/report.dat")
    [[ -n "$report_b64" ]] || die "Empty report from guest"
    log "Report length: ${#report_b64} chars (base64) (~$(( ${#report_b64} * 3 / 4 )) bytes)"

    LAST_REPORT_B64="$report_b64"
    attest_evaluate_report "$report_b64"
}

# Like attest_get_ear_token, but binds the report to a TEE public key so the
# resulting EAR token carries attester_runtime_data tee-pubkey (required by
# KBS to release resources). The CoCo-AS SNP verifier expects the report's
# report_data to equal sha384(canonical JSON runtime data) zero-padded to 64
# bytes, so we write that digest into the guest before generating the report
# with snp-report-gen. Argument: the tee-pubkey as a canonical JSON object
# (sorted keys, compact), e.g.
# {"alg":"ECDH-ES+A256KW","crv":"P-256","kty":"EC","x":"...","y":"..."}.
# It must be canonical because the AS hashes the canonical JSON of the
# runtime data to derive the expected report_data.
attest_get_ear_token_with_tee_key() {
    local tee_pubkey_json="$1"
    [[ -n "$tee_pubkey_json" ]] || die "attest_get_ear_token_with_tee_key requires the tee-pubkey (canonical JSON object)"
    require_cmd base64 ssh openssl

    # Canonical JSON (serde_json_canonicalizer: compact, sorted keys) of the
    # structured runtime data; single key, so the layout is unambiguous.
    local structured
    structured="{\"tee-pubkey\":${tee_pubkey_json}}"
    local digest
    digest=$(printf '%s' "$structured" | openssl dgst -sha384 -hex | awk '{print $NF}')
    # sha384 = 48 bytes; SNP report_data is 64 bytes, zero-padded.
    local report_data_hex="${digest}00000000000000000000000000000000"

    log "Binding report to TEE key (report_data = sha384(runtime data))"
    # Write the 64-byte raw binary request-data and use standard upstream
    # 'snpguest report' (without --random, it binds the provided request data).
    # Fall back to snp-report-gen if available.
    local gen_cmd
    gen_cmd="python3 -c 'import sys; sys.stdout.buffer.write(bytes.fromhex(\"${report_data_hex}\"))' > request-data.bin && snpguest report report.dat request-data.bin --vmpl 0"
    if ! ssh_guest "cd ${GUEST_WORKDIR} && ( ${gen_cmd} || (${SNP_REPORT_GEN_GUEST} ${report_data_hex} report.dat 2>/dev/null) )"; then
        die "Failed to generate a report bound to the TEE key on guest"
    fi

    log "Fetching report (base64)"
    local report_b64
    report_b64=$(ssh_guest "base64 -w0 ${GUEST_WORKDIR}/report.dat")
    [[ -n "$report_b64" ]] || die "Empty report from guest"

    LAST_REPORT_B64="$report_b64"
    attest_evaluate_report "$report_b64" "$structured"
}

# Decode the payload segment (2nd dot-separated part) of a JWT: base64url ->
# base64 (re-padding as needed) -> JSON text on stdout.
jwt_decode_payload() {
    local token="$1" payload
    payload=$(echo "$token" | cut -d. -f2)
    payload="${payload//-/+}"
    payload="${payload//_//}"
    case $((${#payload} % 4)) in
    2) payload+="==" ;;
    3) payload+="=" ;;
    esac
    echo "$payload" | base64 -d 2>/dev/null
}

# Extract the SNP report fields from a decoded EAR JWT payload. Prints
# space-separated: ear_status id_block id_auth launch_digest policy vmpl
# report_id report_id_ma chip_id tcb_status
snp_ear_fields() {
    # Reads the flat SNP annotated-evidence structure produced by the Trustee
    # 0.22.0 snp_verifier: the fields live directly under
    #   submods.cpu0.ear.veraison.annotated-evidence.snp
    # (chip_id, measurement, reported_tcb_*), NOT nested under a 'report'
    # key, and there is NO 'tcb_status' field — AMD KDS verification is
    # signalled by ear.trustworthiness-vector.hardware (0..100).
    # Output is '|' delimited (not whitespace): empty fields are preserved and
    # values may contain spaces (e.g. the TCB status text), so `read` cannot
    # shift the columns.
    local jwt_json="$1"
    [[ -n "$jwt_json" ]] || return 0
    if command -v python3 >/dev/null 2>&1; then
        # Pipe (not a here-string) with `|| true` keeps this immune to the ERR
        # trap / set -e even if python exits non-zero (its try/except already
        # swallows errors); the output is the pipe-delimited field list.
        printf '%s' "$jwt_json" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    submod = d.get('submods', {}).get('cpu0', {})
    ear_status = submod.get('ear.status', '')
    evidence = submod.get('ear.veraison.annotated-evidence', {})
    snp = evidence.get('snp', {})
    chip_id = snp.get('chip_id', '')
    tw = submod.get('ear.trustworthiness-vector', {})
    hardware_tw = tw.get('hardware', '')
    if str(hardware_tw) not in ('', 'None') and int(hardware_tw) >= 50:
        tcb_status = 'Verified (hardware trustworthiness %s%%)' % hardware_tw
    else:
        tcb_status = ''
    print('|'.join([ear_status, '', '', '', '', '', '', '', chip_id, tcb_status]))
except Exception:
    pass
" || true
    fi
    return 0
}

# Build the CoCo-AS SNP reference-value sample: a JSON map of reference-value
# id -> value that ear_default_policy_cpu.rego looks up during appraisal.
# The `in` fields (snp_launch_measurement, snp_bootloader, snp_microcode,
# snp_snp_svn, snp_tee_svn) must be JSON lists; the `==` fields (snp_smt_enabled,
# snp_tsme_enabled, snp_guest_abi_major/minor, snp_single_socket, snp_smt_allowed)
# must be raw scalars with the same JSON type as the report so Rego matching
# succeeds. Values come from the guest report's annotated evidence, so the
# appraisal recognises this exact guest. stdin: decoded EAR JWT; stdout: sample.
snp_rv_sample() {
    require_cmd python3
    # `|| true` keeps this immune to the ERR trap / set -e even if python
    # exits non-zero (its try/except already swallows errors).
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    snp = d['submods']['cpu0']['ear.veraison.annotated-evidence']['snp']
    rv = {
        'snp_launch_measurement': [snp['measurement']],
        'snp_bootloader': [snp['reported_tcb_bootloader']],
        'snp_microcode': [snp['reported_tcb_microcode']],
        'snp_snp_svn': [snp['reported_tcb_snp']],
        'snp_tee_svn': [snp['reported_tcb_tee']],
        'snp_smt_enabled': snp['platform_smt_enabled'],
        'snp_tsme_enabled': snp['platform_tsme_enabled'],
        'snp_guest_abi_major': snp['policy_abi_major'],
        'snp_guest_abi_minor': snp['policy_abi_minor'],
        'snp_single_socket': snp['policy_single_socket'],
        'snp_smt_allowed': snp['policy_smt_allowed'],
    }
    print(json.dumps(rv))
except Exception:
    pass
" || true
    return 0
}

# Register a SNP reference-value sample (JSON map) in RVPS so the default EAR
# appraisal recognises the guest and returns ear.status = affirming.
# Argument: the sample JSON (see snp_rv_sample).
register_rvps_reference_values() {
    local sample_json="$1"
    [[ -n "$sample_json" ]] || die "register_rvps_reference_values requires the reference-value sample JSON"
    ensure_attestation_proto

    local req_file
    req_file=$(mktemp /tmp/snp-rvps-req.XXXXXX)
    printf '%s' "$sample_json" | python3 -c "
import sys, json, base64
sample = json.loads(sys.stdin.read())
prov = base64.b64encode(json.dumps(sample).encode()).decode()
msg = {'version': '0.1.0', 'type': 'sample', 'payload': prov}
print(json.dumps({'message': json.dumps(msg)}))
" >"$req_file"

    log "Registering SNP reference values in RVPS (${COCO_AS}):"
    echo "$sample_json" | python3 -m json.tool 2>/dev/null | sed 's/^/  /'

    local resp=""
    if ! resp=$(grpcurl -plaintext \
        -import-path "$PROTO_DIR" \
        -proto reference.proto \
        -d @ \
        "${COCO_AS}" reference.ReferenceValueProviderService/RegisterReferenceValue <"$req_file" 2>&1); then
        error "Failed to register reference values in RVPS:"
        echo "$resp" >&2
        rm -f "$req_file"
        return 1
    fi
    rm -f "$req_file"
    log "RVPS registration succeeded."
    return 0
}

query_rvps_reference_value() {
    local id="${1:-id_block}"
    ensure_attestation_proto
    local req="{\"reference_value_id\":\"${id}\"}"
    log "Querying RVPS (${COCO_AS}) for reference value '${id}'..."
    local resp=""
    if ! resp=$(echo "$req" | grpcurl -plaintext \
        -import-path "$PROTO_DIR" \
        -proto reference.proto \
        -d @ \
        "${COCO_AS}" reference.ReferenceValueProviderService/QueryReferenceValue 2>&1); then
        error "QueryReferenceValue failed:"
        echo "$resp" >&2
        return 1
    fi
    echo "$resp"
    return 0
}

cmd_query_rv() {
    local id="${RV_ID:-id_block}"
    query_rvps_reference_value "$id"
}

cmd_register_rv() {
    detect_guest_ip
    log "=== Registering SEV-SNP Reference Values in RVPS: ${GUEST_IP} -> ${COCO_AS} ==="
    step "Fetch guest report and enroll identity into RVPS" \
        "Fetches a fresh report, derives the SNP reference values from the report's annotated evidence, and registers them in RVPS so the default EAR appraisal returns affirming."

    attest_get_ear_token
    local token="$EAR_TOKEN"
    local jwt_json=""
    jwt_json=$(jwt_decode_payload "$token") || jwt_json=""
    [[ -n "$jwt_json" ]] || die "Could not obtain an EAR token to derive reference values"

    local sample_json=""
    sample_json=$(printf '%s' "$jwt_json" | snp_rv_sample)
    [[ -n "$sample_json" ]] || die "Could not derive SNP reference values from the report (is this a valid Genoa/Boremi SNP report?)"

    if ! register_rvps_reference_values "$sample_json"; then
        die "Failed to register reference values in RVPS"
    fi

    echo ""
    log "============================================================================="
    log "           RVPS REFERENCE VALUES SUCCESSFULLY ENROLLED (SEV-SNP)"
    log "============================================================================="
    log "Now re-run 'snp-attest.sh attest --guest-ip ${GUEST_IP}' to verify ear.status = affirming."
}

cmd_attest() {
    detect_guest_ip
    log "=== Remote attestation: ${GUEST_IP} -> CoCo-AS ${COCO_AS} ==="
    step "Send the guest SEV-SNP report to CoCo-AS and verify the EAR token" \
        "Fetches a fresh report over ssh, submits it via grpcurl, then checks AMD KDS certificate-chain verification and appraisal status."

    attest_get_ear_token
    local token="$EAR_TOKEN"

    log "Decoding EAR JWT payload"
    local jwt_json=""
    if command -v python3 >/dev/null 2>&1; then
        jwt_json=$(jwt_decode_payload "$token" | python3 -m json.tool) || jwt_json=""
        [[ -n "$jwt_json" ]] && echo "$jwt_json"
    else
        jwt_json=$(jwt_decode_payload "$token") || jwt_json=""
        [[ -n "$jwt_json" ]] && echo "$jwt_json"
    fi
    [[ -n "$jwt_json" ]] || warn "Could not decode JWT payload"

    log "Checking CoCo-AS service log"
    journalctl -u grpc-as.service -n 20 --no-pager 2>/dev/null || true

    local ear_status="" tcb_status="" id_block="" id_auth="" launch_digest="" policy="" vmpl="" report_id="" chip_id=""
    local fields
    fields=$(snp_ear_fields "$jwt_json")
    if [[ -n "$fields" ]]; then
        IFS='|' read -r ear_status id_block id_auth launch_digest policy vmpl report_id _ chip_id tcb_status <<<"$fields"
    fi
    if [[ -z "$ear_status" ]]; then
        ear_status=$(echo "$jwt_json" | grep -oP '"ear\.status"\s*:\s*"\K[^"]+' | head -n1 || true)
    fi
    if [[ -z "$tcb_status" ]]; then
        tcb_status=$(echo "$jwt_json" | grep -oP '"tcb_status"\s*:\s*"\K[^"]+' | head -n1 || true)
    fi
    if [[ -z "$id_block" ]]; then
        id_block=$(echo "$jwt_json" | grep -oP '"id_block"\s*:\s*"\K[^"]+' | head -n1 || true)
    fi
    if [[ -z "$id_auth" ]]; then
        id_auth=$(echo "$jwt_json" | grep -oP '"id_auth"\s*:\s*"\K[^"]+' | head -n1 || true)
    fi
    if [[ -z "$launch_digest" ]]; then
        launch_digest=$(echo "$jwt_json" | grep -oP '"launch_digest"\s*:\s*"\K[^"]+' | head -n1 || true)
    fi
    if [[ -z "$policy" ]]; then
        policy=$(echo "$jwt_json" | grep -oP '"policy"\s*:\s*"\K[^"]+' | head -n1 || true)
    fi
    if [[ -z "$vmpl" ]]; then
        vmpl=$(echo "$jwt_json" | grep -oP '"vmpl"\s*:\s*"\K[^"]+' | head -n1 || true)
    fi
    if [[ -z "$report_id" ]]; then
        report_id=$(echo "$jwt_json" | grep -oP '"report_id"\s*:\s*"\K[^"]+' | head -n1 || true)
    fi
    if [[ -z "$chip_id" ]]; then
        chip_id=$(echo "$jwt_json" | grep -oP '"chip_id"\s*:\s*"\K[^"]+' | head -n1 || true)
    fi

    if ((REGISTER_RV)); then
        log "Registering guest reference values in RVPS (--register-rv specified)..."
        local sample_json=""
        sample_json=$(printf '%s' "$jwt_json" | snp_rv_sample)
        if [[ -n "$sample_json" ]] && register_rvps_reference_values "$sample_json"; then
            # Re-evaluate the SAME report that was just registered (not a fresh
            # one), so the EAR token reflects the just-enrolled identity.
            log "Re-evaluating the same registered report to obtain updated EAR token..."
            attest_evaluate_report "$LAST_REPORT_B64"
            token="$EAR_TOKEN"
            jwt_json=$(jwt_decode_payload "$token") || jwt_json=""
            if command -v python3 >/dev/null 2>&1; then
                ear_status=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('submods', {}).get('cpu0', {}).get('ear.status', ''))
except Exception:
    pass
" <<<"$jwt_json")
            else
                ear_status=$(echo "$jwt_json" | grep -oP '"ear\.status"\s*:\s*"\K[^"]+' | head -n1 || true)
            fi
        fi
    fi

    echo ""
    log "============================================================================="
    log "                    SEV-SNP REMOTE ATTESTATION REPORT"
    log "============================================================================="
    log "  Hardware Verification (AMD KDS / certificate chain ARK->ASK->VCEK):"
    log "    TCB Status:             ${tcb_status:-Unknown}"
    log "    Chip ID:                ${chip_id:-Unknown}"
    log "  Guest Identity (SEV-SNP report):"
    [[ -n "$id_block" ]] && log "    ID Block:             ${id_block:0:32}..."
    [[ -n "$id_auth" ]] && log "    ID Auth:              ${id_auth:0:32}..."
    [[ -n "$launch_digest" ]] && log "    Launch Digest:        ${launch_digest:0:32}..."
    [[ -n "$policy" ]] && log "    Launch Policy:        ${policy}"
    [[ -n "$vmpl" ]] && log "    VMPL:                   ${vmpl}"
    [[ -n "$report_id" ]] && log "    Report ID:            ${report_id}"
    log "  Trustee Appraisal Result (RVPS):"
    log "    EAR Status:             ${ear_status:-Unknown}"
    log "============================================================================="
    echo ""

    if [[ "$ear_status" == "affirming" ]] || echo "$jwt_json" | grep -qE '"allow"[[:space:]]*:[[:space:]]*true'; then
        log "=== ATTESTATION SUCCESS: ear.status = affirming ==="
        log "AMD KDS certificate-chain verification AND Trustee appraisal passed!"
        trap - ERR
        return 0
    elif [[ -n "$tcb_status" && "$tcb_status" != "Revoked" ]]; then
        log "=== HARDWARE ATTESTATION SUCCESS: report verified via AMD KDS (TCB: ${tcb_status}) ==="
        if [[ "$ear_status" == "contraindicated" ]]; then
            warn "Appraisal status is 'contraindicated' because reference values are not enrolled in RVPS."
            warn "To register current guest identity in RVPS and achieve 'affirming' status, run:"
            warn "  snp-attest.sh attest --guest-ip ${GUEST_IP} --register-rv"
            warn "  or: snp-attest.sh register-rv --guest-ip ${GUEST_IP}"
        fi
        trap - ERR
        return 0
    else
        error "=== ATTESTATION FAILED: Invalid or rejected attestation token ==="
        error "Check grpc-as logs and AMD KDS connectivity."
        trap - ERR
        return 1
    fi
}

# Run snpguest report on the guest, capturing its output. On failure, print
# the error in red with an uppercase FAILED prefix and return the command's
# exit code.
guest_generate_report() {
    local out rc=0
    # snpguest takes its paths positionally: 'report <att-report> <request>'.
    # Explicitly pass --vmpl 0 so the report matches the guest privilege level
    # (snpguest defaults to --vmpl 1 without this flag).
    # --random fills the 64-byte request (report_data) with fresh entropy, so
    # each report carries its own nonce.
    out=$(ssh_guest "cd ${GUEST_WORKDIR} && snpguest report report.dat request-data.txt --vmpl 0 --random" 2>&1) || rc=$?
    if ((rc != 0)); then
        local msg
        msg=$(grep -vE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \[' <<<"$out" || true)
        msg="${msg:-no output from snpguest report}"
        msg="${msg/Failed to generate report/FAILED: generate report}"
        echo "$(red "$msg")" >&2
    fi
    return "$rc"
}

# Verify a generated report in-guest (snpguest verify). Returns 0 if the
# report passes in-guest verification, 1 otherwise.
#
# 'snpguest verify attestation <certs-dir> <att-report>' needs the ARK/ASK/VCEK
# chain on disk in the guest; setup-guest ships it to ${GUEST_WORKDIR}/certs
# whenever the host store is populated. Without it, in-guest verification is
# skipped (it is informational — CoCo-AS verifies host-side anyway).
guest_verify_report() {
    local out rc=0
    local certs="${GUEST_WORKDIR}/certs"
    if ! ssh_guest "test -s ${certs}/ark.pem"; then
        echo "No certificate store in guest at ${certs} — skipping in-guest verification."
        echo "Populate it from the host (setup-host) or in-guest with 'snpguest fetch ca/vcek'."
        return 1
    fi
    out=$(ssh_guest "cd ${GUEST_WORKDIR} && snpguest verify attestation ${certs} report.dat" 2>&1) || rc=$?
    echo "$out"
    return "$rc"
}

# Disable suspend/hibernate in the guest. SEV-SNP guests cannot hibernate:
# the hibernate image would be unmeasured/unencrypted, breaking attestation,
# and resume-from-disk is unsupported. Mask the sleep targets and ignore the
# hardware sleep keys in logind.
disable_suspend_guest() {
    ssh_guest "sudo bash -s" <<'EOF'
set -e
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/snp-no-suspend.conf <<'CONF'
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
CONF
systemctl try-restart systemd-logind || true
EOF
}
