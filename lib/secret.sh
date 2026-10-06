# =============================================================================
# 7b. SECRET DELIVERY (KBS)  — AMD SEV-SNP
# =============================================================================
#
# Trustee delivers secrets only after a client attests successfully. The host
# admin stores a secret in the KBS (secret-set); a guest inside an SNP VM
# fetches it (secret-get), which triggers attestation + policy evaluation
# transparently.

cmd_secret_set() {
    require_root
    log "=== Storing secret in KBS: ${SECRET_PATH} ==="
    step "Upload a secret to the KBS as admin" \
        "Stores the file at resource path '${SECRET_PATH}'. The KBS releases it only to clients that pass attestation + resource policy."

    local kbs_client_bin
    kbs_client_bin="$(resolve_kbs_client_bin)"
    [[ -x "$kbs_client_bin" ]] || die "kbs-client not found (looked in \$PATH and ${kbs_client_bin}). Install the 'trustee' package first."

    if [[ -z "$SECRET_FILE" ]]; then
        die "secret-set requires --file <path> (the secret to store)"
    fi
    if [[ ! -f "$SECRET_FILE" ]]; then
        die "Secret file not found: ${SECRET_FILE}"
    fi

    # Admin mode is InsecureAllowAll (LAB); no auth token needed.
    run "$kbs_client_bin" --url "$(kbs_url)" config \
        set-resource --path "$SECRET_PATH" --resource-file "$SECRET_FILE"

    log "Secret stored at ${SECRET_PATH}."
    log "Retrieve from inside an SNP guest with:"
    log "  ${SCRIPT_NAME} secret-get --guest-ip <IP> --path ${SECRET_PATH}"
}

cmd_secret_get() {
    detect_guest_ip
    log "=== Fetching secret from KBS (with attestation): ${SECRET_PATH} ==="

    local url
    url=$(kbs_url)

    if [[ "$SECRET_MODE" == "host" ]]; then
        # Host-side. Generate an EC P-256 TEE key on the host, bind a fresh
        # guest report to it (report_data = sha384 of the runtime data),
        # evaluate via grpcurl to get an EAR token carrying the tee-pubkey
        # claim, then GET the resource from KBS (JWE-encrypted) and decrypt it
        # locally. No in-guest kbs-client needed. Unlike the in-guest path it
        # uses a host-generated report, so it works even when the guest
        # kbs-client is unavailable.
        step "Host-side: attest with a host TEE key, then fetch + decrypt resource" \
            "Generates an EC P-256 TEE key, binds the guest report to it, evaluates via grpcurl, then GETs /kbs/v0/resource/${SECRET_PATH} and decrypts the JWE response locally."
        require_cmd curl openssl python3

        local keyfile resp_file tee_pubkey_json
        keyfile=$(mktemp /tmp/snp-tee-key.XXXXXX)
        resp_file=$(mktemp /tmp/snp-kbs-resp.XXXXXX)
        trap 'rm -f "${keyfile-}" "${resp_file-}"' RETURN 2>/dev/null || true

        log "Generating EC P-256 TEE key on host"
        # Emit the tee-pubkey as a CANONICAL JSON object (sorted keys,
        # compact): the AS hashes the canonical JSON of the runtime data to
        # derive the expected report_data, and KBS parses the tee-pubkey
        # claim as a TeePubKey object (kbs_types, serde tag "kty").
        tee_pubkey_json=$(
            python3 - "$keyfile" <<'PYEOF'
import base64, json, sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

key = ec.generate_private_key(ec.SECP256R1())
n = key.public_key().public_numbers()
b64 = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
jwk = {"kty": "EC", "crv": "P-256", "alg": "ECDH-ES+A256KW",
       "x": b64(n.x.to_bytes(32, "big")),
       "y": b64(n.y.to_bytes(32, "big"))}
pem = key.private_bytes(serialization.Encoding.PEM,
                        serialization.PrivateFormat.PKCS8,
                        serialization.NoEncryption())
open(sys.argv[1], "wb").write(pem)
print(json.dumps(jwk, sort_keys=True, separators=(",", ":")))
PYEOF
        ) || die "Failed to generate TEE key (python3 'cryptography' module missing?)"

        attest_get_ear_token_with_tee_key "$tee_pubkey_json"

        log "Fetching resource from KBS: ${url}/kbs/v0/resource/${SECRET_PATH}"
        # Direct curl (not via run) so the EAR token is not printed in the CMD log.
        if ! curl -fsS -H "Authorization: Bearer ${EAR_TOKEN}" \
            "${url}/kbs/v0/resource/${SECRET_PATH}" >"$resp_file"; then
            die "Secret retrieval failed. Check attestation (attest cmd) and KBS resource policy."
        fi

        local decrypt_args
        if [[ -n "$SECRET_FILE" ]]; then
            log "Saving secret to: ${SECRET_FILE}"
            decrypt_args=("$keyfile" "$resp_file" "$SECRET_FILE")
        else
            log "Retrieving secret to stdout"
            decrypt_args=("$keyfile" "$resp_file" "-")
        fi
        if python3 - "${decrypt_args[@]}" <<'PYEOF'
import base64, json, sys

keyfile, respfile, outfile = sys.argv[1], sys.argv[2], sys.argv[3]

def b64e(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")

resp = json.load(open(respfile))
prot = resp.get("protected")
if isinstance(prot, str):
    seg0 = prot
else:
    # Re-serialize canonically (sorted keys, compact) so the AAD matches what
    # KBS computed over the protected header.
    seg0 = b64e(json.dumps(prot, sort_keys=True, separators=(",", ":")).encode())
# The byte fields are already base64url(no pad) strings in the KBS response
# (serde serialize_base64 in kbs_types).
compact = ".".join([seg0, resp["encrypted_key"], resp["iv"],
                    resp["ciphertext"], resp["tag"]])

from jwcrypto import jwe, jwk
j = jwe.JWE()
key = jwk.JWK.from_pem(open(keyfile, "rb").read())
j.deserialize(compact, key)
data = j.payload
if outfile == "-":
    sys.stdout.buffer.write(data)
else:
    open(outfile, "wb").write(data)
PYEOF
        then
            [[ -n "$SECRET_FILE" ]] && log "Secret written to ${SECRET_FILE}."
            log "=== SECRET DELIVERY SUCCESS: attestation passed, secret released ==="
        else
            die "Failed to decrypt the JWE resource response (python3 'jwcrypto' module missing?)"
        fi
        return 0
    fi

    # Option A (default): in-guest kbs-client.
    step "From inside the SNP VM, fetch a KBS secret" \
        "Runs kbs-client on the guest: it attests to CoCo-AS via KBS, then downloads resource '${SECRET_PATH}' if policy allows."

    # kbs-client must run inside the SNP guest so its evidence is a real SNP
    # report. Use the distro 'trustee' package kbs-client: it is
    # version-aligned with the host-side verifier (snp-verifier).
    local kbs_bin
    kbs_bin="$(guest_distro_kbs_client_bin)"
    if ! ssh_guest "test -x ${kbs_bin}"; then
        log "kbs-client not found in guest — installing 'trustee' package"
        # shellcheck disable=SC2046  # deliberate word-splitting of the package list
        install_pkgs_guest $(guest_distro_pkgs trustee)
        kbs_bin="$(guest_distro_kbs_client_bin)"
    fi
    kbs_client_supports_snp_guest "$kbs_bin" ||
        die "Guest kbs-client (${kbs_bin}) has no SNP attester. Upgrade the guest 'trustee' package and re-run setup-guest."

    local out
    if [[ -n "$SECRET_FILE" ]]; then
        log "Saving secret to (guest path): ${SECRET_FILE}"
        ssh_guest "${kbs_bin} --url '${url}' get-resource --path '${SECRET_PATH}' > '${SECRET_FILE}'" ||
            die "Secret retrieval failed. Check attestation (attest cmd) and KBS policy."
        log "Secret written to ${SECRET_FILE} on the guest."
    else
        log "Retrieving secret to stdout (text secrets only; use --file for binary data)"
        if out=$(ssh_guest "${kbs_bin} --url '${url}' get-resource --path '${SECRET_PATH}'"); then
            echo "$out"
            log "=== SECRET DELIVERY SUCCESS: attestation passed, secret released ==="
        else
            die "Secret retrieval failed. Check attestation (attest cmd) and KBS resource policy."
        fi
    fi
}
