# =============================================================================
# 5. HOST SETUP  — AMD SEV-SNP
# =============================================================================

# --- Collateral source: two methods ------------------------------------------
#
# The AMD certificate chain (ARK -> ASK -> VCEK) can come from two places:
#   Method 1 (kds):    AMD's global Key Distribution Service (KDS) directly —
#                      always authoritative, but every fetch goes over the
#                      public internet.
#   Method 2 (offline): a locally-provisioned certificate store (air-gapped).
#                      Import the chain once with 'snphost import' and reuse
#                      it; attestation collateral stays on the local machine.
#
# The chain is fetched/verified with 'snphost' (the SLES 16.1 host tool).
# Unlike Intel TDX (which has a QGS daemon + QCNL config + PCCS cache), SEV-SNP
# has NO host-side quote daemon: the guest's 'snpguest report' triggers report
# generation directly via GHCB and the CPU's PSP signs it. So there is no
# QGS/QCNL equivalent to configure here — only the certificate store.

# Method 1: fetch the certificate chain from AMD KDS directly.
collateral_via_kds() {
    [[ -n "$KDS_URL" ]] || die "KDS mode requires a KDS endpoint (--kds-url)"
    log "Collateral source: AMD KDS (${KDS_URL})"
    fetch_kds_certs
}

# Method 2: use a locally-provisioned certificate store (air-gapped).
collateral_via_offline() {
    log "Collateral source: offline certificate store (${SNP_CERT_DIR})"
    if [[ ! -s "$SNP_ARK_CERT" || ! -s "$SNP_VCEK_CERT" ]]; then
        die "Offline mode requires a populated certificate store.
Fetch the ARK/ASK/VCEK chain first (on a machine with KDS access):
  snphost fetch ca pem ${SNP_CERT_DIR}
  snphost fetch vcek pem ${SNP_CERT_DIR}
then copy ${SNP_CERT_DIR} to this host, or re-run with --collateral kds."
    fi
    log "Offline certificate store present: ${SNP_ARK_CERT}"
}

# Fetch the ARK/ASK/VCEK certificate chain from AMD KDS into the local store.
# Idempotent: re-fetches are safe (the chain is overwritten).
fetch_kds_certs() {
    require_cmd snphost
    mkdir -p "$SNP_CERT_DIR"
    # snphost has no --kds-url flag: 'fetch ca' / 'fetch vcek' always talk to
    # AMD's KDS, and they write ark.pem / ask.pem / vcek.pem straight into the
    # target directory — exactly the layout SNP_*_CERT expects, so no
    # post-fetch normalization is needed.
    if [[ "$KDS_URL" != "https://kdsintf.amd.com/vcek/v1/SEV_SNP" ]]; then
        warn "--kds-url (${KDS_URL}) is not honoured by 'snphost fetch' (it has no such option);"
        warn "it is only used for the CoCo-AS collateral_service setting and the reachability probe."
    fi
    log "Fetching the AMD CA chain (ARK/ASK) from KDS into ${SNP_CERT_DIR}"
    if ! run snphost fetch ca pem "$SNP_CERT_DIR"; then
        warn "snphost fetch ca failed (network? KDS unreachable?)."
        warn "If this host is air-gapped, use --collateral offline with a pre-populated store."
        return 1
    fi
    log "Fetching this platform's VCEK from KDS into ${SNP_CERT_DIR}"
    if ! run snphost fetch vcek pem "$SNP_CERT_DIR"; then
        warn "snphost fetch vcek failed (network? KDS unreachable?)."
        warn "If this host is air-gapped, use --collateral offline with a pre-populated store."
        return 1
    fi
    # Verify the chain end-to-end (ARK -> ASK -> VCEK, ECDSA P-384).
    if run snphost verify certs "$SNP_CERT_DIR"; then
        log "Certificate chain verified (ARK -> ASK -> VCEK)"
    else
        warn "Certificate chain verification reported a problem (see snphost output)."
    fi
    # Turin+ platforms also carry a VLEK hashstick; verify it when present.
    if snphost verify vlek-hashstick >/dev/null 2>&1; then
        log "VLEK hashstick verified (Turin+ platform)"
    fi
    return 0
}

# Select the collateral source (method 1 = KDS, method 2 = offline) and prepare
# whatever it needs (the certificate chain). Called before writing the CoCo-AS
# config so it always points at a usable source.
setup_collateral_source() {
    case "$COLLATERAL_MODE" in
    kds) collateral_via_kds ;;
    offline) collateral_via_offline ;;
    *) die "Invalid --collateral '${COLLATERAL_MODE}' (must be 'kds' or 'offline')" ;;
    esac
}

cmd_setup_host() {
    require_root
    require_cmd "$(distro_pkg_manager)"
    log "=== Setting up SEV-SNP host (snphost stack) ==="
    step "Install snphost, verify host SEV-SNP, fetch KDS certificates, start libvirt" \
        "Enables the host to fetch the AMD certificate chain from the selected source (KDS or offline store); confirms SEV-SNP is active on the host (/dev/sev, kvm_amd)."

    log "Checking SEV-SNP host attestation stack (snphost)"
    # shellcheck disable=SC2046  # deliberate word-splitting of the package list
    install_pkgs $(distro_pkgs snp_host)

    local snphost_bin
    snphost_bin=$(distro_snp_host_bin)
    if [[ ! -f "$snphost_bin" ]] && ! command -v snphost >/dev/null 2>&1; then
        die "snphost binary ${snphost_bin} not found after install"
    fi
    log "snphost binary present: ${snphost_bin:-$(command -v snphost)}"

    # NOTE: there is NO host-side quote daemon for SEV-SNP (unlike TDX's QGS).
    # Report generation is triggered in-guest via GHCB and signed by the CPU's
    # PSP. The host only needs /dev/sev (SEV-SNP control) + the cert chain.
    log "Verifying host SEV-SNP (/dev/sev + kvm_amd SNP)"
    if [[ -c /dev/sev ]]; then
        log "/dev/sev present (SEV-SNP host control device)"
    else
        warn "/dev/sev missing. Load kvm_amd with SNP enabled and check BIOS SEV-SNP:"
        warn "  dmesg | grep -i sev"
    fi
    if command -v snphost >/dev/null 2>&1; then
        if snphost ok >/dev/null 2>&1; then
            log "snphost ok: platform probe passed"
        else
            warn "snphost ok: platform probe reported a problem (see output above)"
        fi
    fi

    # Always (re)fetch/verify the certificate chain so the selected collateral
    # source (KDS or offline) is what the verifier actually uses.
    setup_collateral_source

    log "Verifying installed SNP packages"
    run distro_pkg_list_all | grep -Ei 'snp|sev' || warn "No SNP packages matched"

    log "Ensuring libvirt is running (needed later by setup-vm)"
    if command -v virsh >/dev/null 2>&1; then
        ensure_libvirt
    else
        warn "virsh not installed; skipping libvirt check."
    fi

    log "Ensuring grpcurl is available for remote attestation"
    ensure_grpcurl || warn "grpcurl installation deferred"

    log "Host setup complete."
}

cmd_setup_trustee() {
    require_root
    require_cmd "$(distro_pkg_manager)" systemctl
    log "=== Setting up Trustee (attestation + secret delivery) ==="
    step "Install + configure + start CoCo-AS (snp_verifier), KBS, RVPS (trustee)" \
        "CoCo-AS verifies SEV-SNP reports and issues an EAR token; KBS gates secret delivery behind attestation; RVPS holds reference values. Generates a KBS admin key so 'secret-set' can push secrets."

    log "Checking trustee + SNP verification libraries"
    # shellcheck disable=SC2046  # deliberate word-splitting of the package list
    install_pkgs $(distro_pkgs trustee)

    # Some distros (SUSE) install the trustee binaries under
    # /usr/libexec/trustee/ but the systemd units reference /usr/libexec/<name>.
    # Create symlinks so the units work (see <id>_trustee_needs_symlinks).
    if [[ "$(distro_trustee_needs_symlinks)" == "1" ]]; then
        log "Linking trustee binaries to /usr/libexec/ (service units expect them there)"
        local bin
        local trustee_dir
        trustee_dir=$(dirname "$(distro_kbs_client_bin)")
        for bin in grpc-as kbs rvps trustee; do
            local src="${trustee_dir}/${bin}"
            local dst="/usr/libexec/${bin}"
            if [[ -f "$src" && ! -e "$dst" ]]; then
                run ln -sf "$src" "$dst"
                log "  ${dst} -> ${src}"
            elif [[ -f "$dst" ]]; then
                log "  ${dst} already present"
            else
                warn "Binary not found: ${src} (and no ${dst})"
            fi
        done
    fi

    log "Checking grpc-as dynamic library dependencies"
    local grpc_as_bin
    grpc_as_bin=$(distro_grpc_as_bin)
    if [[ -f "$grpc_as_bin" ]]; then
        local missing
        missing=$(ldd "$grpc_as_bin" 2>/dev/null | grep 'not found' || true)
        if [[ -n "$missing" ]]; then
            error "Missing libraries for grpc-as:"
            echo "$missing" >&2
            die "Install missing SNP verification libraries and retry"
        fi
    fi

    setup_collateral_source
    local as_collateral
    as_collateral=$(kds_url)
    log "Writing CoCo-AS config: $GRPC_AS_CONF"
    mkdir -p "$AS_STORAGE_DIR"
    if id coco_as >/dev/null 2>&1; then
        run chown coco_as:coco_as "$AS_STORAGE_DIR"
    fi
    # Persistent signer so grpc-as serves a stable JWKS endpoint for KBS.
    ensure_as_signer_key

    # The snp_verifier config differs from TDX's dcap_verifier: it points at
    # the AMD KDS (or the offline cert store) for the ARK/ASK/VCEK chain. The
    # exact field names depend on the Trustee version; the two most common
    # layouts are written here (collateral_service for KDS, local_collateral_path
    # for offline). CoCo-AS ignores fields it does not recognize.
    local verifier_block
    if [[ "$COLLATERAL_MODE" == "offline" ]]; then
        verifier_block=$(cat <<EOF
    "snp_verifier": {
      "local_collateral_path": "${SNP_CERT_DIR}",
      "use_secure_cert": false
    }
EOF
)
    else
        verifier_block=$(cat <<EOF
    "snp_verifier": {
      "collateral_service": "${as_collateral}",
      "use_secure_cert": true
    }
EOF
)
    fi

    cat >"$GRPC_AS_CONF" <<EOF
{
  "storage_backend": {
    "storage_type": "LocalFs",
    "backends": {
      "local_fs": {
        "dir_path": "${AS_STORAGE_DIR}"
      }
    }
  },
  "rvps_config": {
    "type": "BuiltIn"
  },
  "attestation_token_broker": {
    "duration_min": 5,
    "issuer_name": "CoCo-Attestation-Service",
    "verbose_token": true,
    "signer": {
      "key_path": "${AS_SIGNER_KEY}",
      "cert_path": "${AS_SIGNER_CERT}"
    }
  },
  "verifier_config": {
${verifier_block}
  }
}
EOF
    if id coco_as >/dev/null 2>&1; then
        run chown coco_as:coco_as "$GRPC_AS_CONF"
    fi
    run chmod 600 "$GRPC_AS_CONF"

    # Admin keypair + resource policy: required for KBS to accept secrets and to
    # gate their release on attestation.
    ensure_kbs_admin_key
    write_resource_policy

    log "Writing KBS config: $KBS_CONF"
    # SECURITY NOTE: the following settings are LAB/development defaults ONLY.
    #   - insecure_http = true        : no TLS on the KBS HTTP listener
    #   - authorization_mode = InsecureAllowAll : ANY client that passes
    #     attestation can read ANY resource — no per-resource auth checks.
    #     In production, replace with AuthenticatedAuthorization + bearer_jwt
    #     and tighten the resource policy (write_resource_policy).
    #   - insecure_http + InsecureAllowAll together mean: anyone who can
    #     reach the KBS port (0.0.0.0) and pass a valid EAR token can
    #     read every secret. Never expose this port to untrusted networks.
    # For production: provide TLS certs (insecure_http=false), use
    # AuthenticatedAuthorization, and write a restrictive rego policy.
    # trusted_jwk_sets must be file:// or https:// (http:// is rejected). We
    # derive the JWKS from the signer public key (see ensure_as_signer_key).
    cat >"$KBS_CONF" <<EOF
{
  "http_server": {
    "sockets": ["0.0.0.0:${KBS_PORT}"],
    "insecure_http": true
  },
  "admin": {
    "authorization_mode": "InsecureAllowAll"
  },
  "attestation_token": {
    "trusted_jwk_sets": ["file://${KBS_JWKS_FILE}"],
    "trusted_certs_paths": ["${AS_SIGNER_CERT}"]
  },
  "attestation_service": {
    "type": "coco_as_grpc",
    "as_addr": "http://${COCO_AS}"
  },
  "policy_engine": {
    "policy_path": "${KBS_POLICY}"
  },
  "storage_backend": {
    "storage_type": "LocalFs",
    "backends": {
      "local_fs": {
        "dir_path": "${AS_STORAGE_DIR}/kbs"
      }
    }
  },
  "plugins": [
    {
      "name": "resource",
      "storage_backend_type": "kvstorage"
    }
  ]
}
EOF
    if id coco_kbs >/dev/null 2>&1; then
        run chown coco_kbs:coco_kbs "$KBS_CONF"
        run chown coco_kbs:coco_kbs "$KBS_ADMIN_PUB" "$KBS_POLICY" 2>/dev/null || true
    fi
    run chmod 600 "$KBS_CONF"
    mkdir -p "${AS_STORAGE_DIR}/kbs" "${AS_STORAGE_DIR}/rvps"
    if id coco_kbs >/dev/null 2>&1; then
        run chown coco_kbs:coco_kbs "${AS_STORAGE_DIR}/kbs"
    fi
    if id coco_rvps >/dev/null 2>&1; then
        run chown coco_rvps:coco_rvps "${AS_STORAGE_DIR}/rvps"
    fi

    log "Writing RVPS config: $RVPS_CONF"
    cat >"$RVPS_CONF" <<EOF
{
  "storage_type": "LocalFs",
  "storage_dir": "${AS_STORAGE_DIR}/rvps"
}
EOF
    if id coco_rvps >/dev/null 2>&1; then
        run chown coco_rvps:coco_rvps "$RVPS_CONF"
    fi
    run chmod 600 "$RVPS_CONF"

    log "Starting Trustee services"
    # SUSE kbs.service ExecStart omits --config-file; override it to point at
    # /etc/kbs.json (the unit's ConditionPathExists already checks this file).
    mkdir -p /etc/systemd/system/kbs.service.d
    cat >/etc/systemd/system/kbs.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=$(distro_kbs_bin) --config-file /etc/kbs.json
EOF
    # SUSE grpc-as.service sets GRPC_AS_OPTIONS="--config ..." but ExecStart does
    # not expand it, and the CLI flag is --config-file (not --config). So grpc-as
    # runs with no config file -> default config -> ephemeral signer -> no JWKS
    # endpoint. Override ExecStart to pass the config explicitly.
    mkdir -p /etc/systemd/system/grpc-as.service.d
    cat >/etc/systemd/system/grpc-as.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=$(distro_grpc_as_bin) --config-file /etc/grpc-as.json
EOF
    if [[ -n "${https_proxy:-${HTTPS_PROXY:-}}" ]]; then
        cat >>/etc/systemd/system/grpc-as.service.d/override.conf <<EOF
Environment="HTTPS_PROXY=${https_proxy:-$HTTPS_PROXY}"
Environment="https_proxy=${https_proxy:-$HTTPS_PROXY}"
EOF
    fi

    if id coco_as >/dev/null 2>&1; then
        run mkdir -p /var/lib/coco_as
        run chown -R coco_as:coco_as /var/lib/coco_as
    fi
    run systemctl daemon-reload

    # Start services in dependency order. KBS needs the CoCo-AS JWKS file to
    # exist before it starts (KBS loads trusted_jwk_sets at startup), so start
    # rvps + grpc-as first, then kbs.
    local svc
    if systemctl cat rvps.service >/dev/null 2>&1; then
        run systemctl enable --now rvps.service
    else
        warn "Service unit not found, skipping: rvps.service"
    fi
    if systemctl cat grpc-as.service >/dev/null 2>&1; then
        run systemctl enable --now grpc-as.service
        run systemctl restart grpc-as.service
    else
        warn "Service unit not found, skipping: grpc-as.service"
    fi

    # Wait for grpc-as to actually listen (KBS connects to it for attestation).
    log "Waiting for CoCo-AS to listen on ${COCO_AS}"
    if ! wait_for_port 127.0.0.1 "${COCO_AS##*:}" 30; then
        warn "CoCo-AS not listening on ${COCO_AS} after 30s; KBS attestation will fail"
    fi

    # The JWKS was already derived from the signer public key in
    # ensure_as_signer_key(). Verify it is in place before KBS starts.
    if [[ ! -s "$KBS_JWKS_FILE" ]]; then
        warn "JWKS file missing or empty: ${KBS_JWKS_FILE}. KBS token verification will fail."
    else
        log "JWKS in place at ${KBS_JWKS_FILE}"
    fi

    # Now start kbs (KBS needs the JWKS file to exist).
    if systemctl cat kbs.service >/dev/null 2>&1; then
        run systemctl enable --now kbs.service
    else
        warn "Service unit not found, skipping: kbs.service"
    fi
    if systemctl cat trustee.service >/dev/null 2>&1; then
        run systemctl disable trustee.service 2>/dev/null || true
    fi

    log "Verifying Trustee stack"
    for svc in grpc-as.service kbs.service rvps.service; do
        local state
        state=$(systemctl is-active "$svc" 2>/dev/null || true)
        state="${state:-unknown}"
        log "  ${svc}: ${state}"
    done
    ss -tln 2>/dev/null | grep -E "[:.](${COCO_AS##*:}|${KBS_PORT})\b" || warn "Expected ports not listening yet"

    # Push the resource policy into the running KBS so secret release is governed.
    # Admin mode is InsecureAllowAll (LAB), so no auth token is needed.
    local kbs_client_bin
    kbs_client_bin="$(resolve_kbs_client_bin)"
    if [[ -x "$kbs_client_bin" ]]; then
        log "Waiting for KBS to listen on ${KBS_PORT}"
        if wait_for_port 127.0.0.1 "${KBS_PORT}" 30; then
            log "Uploading resource policy to KBS"
            # Local upload: this runs on the host itself, so use 127.0.0.1.
            run "$kbs_client_bin" --url "http://127.0.0.1:${KBS_PORT}" config \
                set-resource-policy --policy-file "$KBS_POLICY" ||
                warn "Policy upload failed; set it later with kbs-client set-resource-policy"
        else
            warn "KBS not listening after 30s; upload policy later (see 'secret-set')"
        fi
    else
        warn "kbs-client not found (looked in \$PATH and ${kbs_client_bin}); install it to push policy/secrets"
    fi

    ensure_attestation_proto
    if [[ -d /etc/trustee && -w /etc/trustee ]]; then
        cp "${PROTO_DIR}/attestation.proto" /etc/trustee/attestation.proto 2>/dev/null || true
        cp "${PROTO_DIR}/reference.proto" /etc/trustee/reference.proto 2>/dev/null || true
    fi

    log "Trustee setup complete. Store a secret with: ${SCRIPT_NAME} secret-set --file <f>"
}

# Ensure the KBS service user (coco_kbs) can traverse TRUSTEE_DIR to read the
# admin public key and policy. The private key stays root-only (0600).
prepare_trustee_dir() {
    mkdir -p "$TRUSTEE_DIR"
    if getent group coco_kbs >/dev/null 2>&1; then
        run chown root:coco_kbs "$TRUSTEE_DIR"
        run chmod 750 "$TRUSTEE_DIR"
    else
        # coco_kbs group absent: fall back to world-traversable (lab only).
        run chmod 755 "$TRUSTEE_DIR"
    fi
}

# Generate the KBS admin keypair (used by kbs-client to push policy + secrets).
ensure_kbs_admin_key() {
    prepare_trustee_dir
    if [[ -f "$KBS_ADMIN_KEY" && -f "$KBS_ADMIN_PUB" ]]; then
        log "KBS admin keypair already exists: ${KBS_ADMIN_KEY}"
        return 0
    fi
    require_cmd openssl
    log "Generating KBS admin keypair (ed25519): ${KBS_ADMIN_KEY}"
    run openssl genpkey -algorithm ed25519 -out "$KBS_ADMIN_KEY"
    run openssl pkey -in "$KBS_ADMIN_KEY" -pubout -out "$KBS_ADMIN_PUB"
    run chmod 600 "$KBS_ADMIN_KEY" # private: admin/kbs-client only, never KBS
    run chmod 644 "$KBS_ADMIN_PUB" # public: readable by coco_kbs (KBS reads it)
}

# Generate the CoCo-AS token signer key pair (persistent EC P-256) and derive
# the JWKS file KBS uses to verify attestation tokens. Without a persistent
# signer, grpc-as uses an ephemeral key and KBS cannot verify tokens across
# restarts.
ensure_as_signer_key() {
    mkdir -p "$AS_SIGNER_DIR"
    if id coco_as >/dev/null 2>&1; then
        run chown coco_as:coco_as "$AS_SIGNER_DIR"
    fi
    run chmod 700 "$AS_SIGNER_DIR"
    if [[ -f "$AS_SIGNER_KEY" && -f "$AS_SIGNER_PUB" && -f "$AS_SIGNER_CERT" && -f "$KBS_JWKS_FILE" ]] &&
        [[ -s "$KBS_JWKS_FILE" ]]; then
        log "CoCo-AS signer keypair + JWKS already exist: ${AS_SIGNER_KEY}"
        return 0
    fi
    require_cmd openssl
    if [[ ! -f "$AS_SIGNER_KEY" || ! -f "$AS_SIGNER_PUB" ]]; then
        log "Generating CoCo-AS signer keypair (EC P-256): ${AS_SIGNER_KEY}"
        run openssl ecparam -name prime256v1 -genkey -noout -out "$AS_SIGNER_KEY"
        run openssl pkey -in "$AS_SIGNER_KEY" -pubout -out "$AS_SIGNER_PUB"
    fi
    run chmod 600 "$AS_SIGNER_KEY" # private: coco_as only
    run chmod 644 "$AS_SIGNER_PUB" # public: JWKS consumers
    if id coco_as >/dev/null 2>&1; then
        run chown coco_as:coco_as "$AS_SIGNER_KEY" "$AS_SIGNER_PUB"
    fi
    # Self-signed cert for the signer key. This KBS version verifies
    # header-embedded JWKs only against an x5c chain that chains to
    # attestation_token.trusted_certs_paths. The cert lives in $TRUSTEE_DIR
    # (readable by coco_kbs/KBS); coco_as needs group traversal of the 750
    # root:coco_kbs directory.
    prepare_trustee_dir
    if [[ -f "$AS_SIGNER_CERT" ]]; then
        log "CoCo-AS signer cert already exists: ${AS_SIGNER_CERT}"
    else
        log "Generating self-signed CoCo-AS signer cert: ${AS_SIGNER_CERT}"
        run openssl req -new -x509 -key "$AS_SIGNER_KEY" \
            -subj "/CN=CoCo-AS" -days 3650 -out "$AS_SIGNER_CERT"
    fi
    run chmod 644 "$AS_SIGNER_CERT"
    if id coco_as >/dev/null 2>&1; then
        run chown coco_as:coco_as "$AS_SIGNER_CERT"
        if getent group coco_kbs >/dev/null 2>&1; then
            id -nG coco_as | tr ' ' '\n' | grep -qx coco_kbs ||
                run usermod -aG coco_kbs coco_as
        fi
    fi
    # Derive the JWKS (JWK Set) JSON from the public key for KBS token
    # verification. The JWKS holds the EC P-256 x/y coordinates (base64url).
    log "Deriving JWKS from signer public key: ${KBS_JWKS_FILE}"
    local hexstr x y
    hexstr=$(openssl pkey -pubin -in "$AS_SIGNER_PUB" -text -noout 2>/dev/null | awk '
        /^pub:/ {f=1; next}
        f {
          line=$0
          gsub(/^[ \t]+|[ \t]+$/,"",line)
          if (line ~ /^[0-9a-f:]+$/) { gsub(/:/,"",line); hex=hex line }
          else if (line != "") { exit }
        }
        END { print hex }')
    # Uncompressed point: 04 || X (32 bytes) || Y (32 bytes)
    x="${hexstr:2:64}"
    y="${hexstr:66:64}"
    if [[ ${#x} -ne 64 || ${#y} -ne 64 ]]; then
        die "Failed to parse EC public key coordinates from ${AS_SIGNER_PUB}"
    fi
    local x_b64 y_b64
    x_b64=$(echo "$x" | xxd -r -p | b64url_encode)
    y_b64=$(echo "$y" | xxd -r -p | b64url_encode)
    mkdir -p "$(dirname "$KBS_JWKS_FILE")"
    cat >"$KBS_JWKS_FILE" <<EOF
{
  "keys": [
    {
      "kty": "EC",
      "crv": "P-256",
      "alg": "ES256",
      "x": "${x_b64}",
      "y": "${y_b64}"
    }
  ]
}
EOF
    if id coco_kbs >/dev/null 2>&1; then
        run chown coco_kbs:coco_kbs "$KBS_JWKS_FILE"
    fi
    run chmod 640 "$KBS_JWKS_FILE"
}

# Write a permissive resource-access policy (LAB DEFAULT: allow all).
# Tighten this to gate secrets on real SNP claims before production use.
write_resource_policy() {
    log "Writing KBS resource policy (allow-all, LAB ONLY): ${KBS_POLICY}"
    prepare_trustee_dir
    cat >"$KBS_POLICY" <<'REGO'
package policy

# LAB DEFAULT: allow any attester to read any resource once attestation
# succeeds. Replace with checks on input claims (e.g. snp.report.id_block)
# for real secret gating.
default allow = true
REGO
    run chmod 644 "$KBS_POLICY" # readable by coco_kbs (KBS loads it)
}
