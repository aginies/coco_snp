# =============================================================================
# 3. GENERIC HELPERS
# =============================================================================

require_root() {
    if ((EUID != 0)); then
        die "This command requires root. Re-run with sudo."
    fi
}

require_cmd() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            die "Required command not found: ${cmd}"
        fi
    done
}

# Read stdin and print base64url without padding (RFC 4648 §5).
b64url_encode() {
    base64 -w0 | tr '+/' '-_' | tr -d '='
}

# Ensure grpcurl is available on the host (used to communicate with CoCo-AS gRPC service).
# Automatically downloads and installs the official prebuilt binary if missing.
ensure_grpcurl() {
    if command -v grpcurl >/dev/null 2>&1; then
        return 0
    fi
    for cand in "/usr/local/bin/grpcurl" "${HOME}/.local/bin/grpcurl" "/usr/bin/grpcurl"; do
        if [[ -x "$cand" ]]; then
            local dir
            dir=$(dirname "$cand")
            export PATH="${dir}:$PATH"
            return 0
        fi
    done

    # Prefer the distribution package (SLE ships grpcurl); fall back to the
    # official prebuilt binary if the package is not (yet) available.
    local grpcurl_pkgs
    grpcurl_pkgs=$(distro_pkgs grpcurl)
    if [[ -n "$grpcurl_pkgs" ]]; then
        log "grpcurl not found; trying the distribution package first..."
        # shellcheck disable=SC2046  # deliberate word-splitting of the package list
        if install_pkgs $grpcurl_pkgs && command -v grpcurl >/dev/null 2>&1; then
            log "grpcurl installed via package manager"
            return 0
        fi
        warn "Distribution package for grpcurl unavailable; falling back to prebuilt binary"
    fi

    log "grpcurl not found; installing official prebuilt release..."
    local install_dir="/usr/local/bin"
    local use_sudo=""
    if [[ "$EUID" -ne 0 ]]; then
        if sudo -n true 2>/dev/null; then
            use_sudo="sudo"
        else
            install_dir="${HOME}/.local/bin"
            mkdir -p "$install_dir"
            export PATH="${install_dir}:${PATH}"
        fi
    fi

    local grpcurl_ver="1.9.3"
    local grpcurl_url="https://github.com/fullstorydev/grpcurl/releases/download/v${grpcurl_ver}/grpcurl_${grpcurl_ver}_linux_x86_64.tar.gz"
    local tmp_tar
    tmp_tar=$(mktemp /tmp/grpcurl.XXXXXX.tar.gz)
    if curl -sSL -o "$tmp_tar" "$grpcurl_url" 2>/dev/null && [[ -s "$tmp_tar" ]]; then
        $use_sudo tar -xz -C "$install_dir" -f "$tmp_tar" grpcurl 2>/dev/null || tar -xz -C "$install_dir" -f "$tmp_tar" grpcurl
        $use_sudo chmod 0755 "${install_dir}/grpcurl" 2>/dev/null || chmod 0755 "${install_dir}/grpcurl"
        rm -f "$tmp_tar"
        if command -v grpcurl >/dev/null 2>&1 || [[ -x "${install_dir}/grpcurl" ]]; then
            export PATH="${install_dir}:${PATH}"
            log "Installed grpcurl to ${install_dir}/grpcurl"
            return 0
        fi
    fi
    rm -f "$tmp_tar"

    # Fallback to go install if go is available
    if command -v go >/dev/null 2>&1; then
        log "Attempting to install grpcurl via go install..."
        GOBIN="$install_dir" go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest >/dev/null 2>&1 || true
        if command -v grpcurl >/dev/null 2>&1 || [[ -x "${install_dir}/grpcurl" ]]; then
            export PATH="${install_dir}:${PATH}"
            log "Installed grpcurl via go"
            return 0
        fi
    fi

    die "grpcurl is required to communicate with CoCo-AS gRPC. Install the package
  $(distro_pkg_manager) in grpcurl
or the prebuilt binary:
  curl -sSL https://github.com/fullstorydev/grpcurl/releases/download/v1.9.3/grpcurl_1.9.3_linux_x86_64.tar.gz | sudo tar -xz -C /usr/local/bin grpcurl"
}

# Ensure the CoCo-AS attestation.proto file is accessible for grpcurl
# (since production gRPC servers usually disable the reflection API).
ensure_attestation_proto() {
    local candidate_dirs=(
        "${SCRIPT_DIR}/protos"
        "${SCRIPT_DIR}"
        "/etc/trustee/protos"
        "/etc/trustee"
        "/usr/share/trustee/protos"
        "/usr/share/trustee"
        "/var/tmp/trustee-protos"
    )
    for dir in "${candidate_dirs[@]}"; do
        if [[ -f "${dir}/attestation.proto" ]]; then
            PROTO_DIR="$dir"
            break
        fi
    done

    # Write embedded proto if not found on disk
    if [[ -z "$PROTO_DIR" || ! -f "${PROTO_DIR}/attestation.proto" ]]; then
        mkdir -p /var/tmp/trustee-protos
        cat >/var/tmp/trustee-protos/attestation.proto <<'EOF'
syntax = "proto3";

package attestation;

message AttestationRequest {
    repeated IndividualAttestationRequest verification_requests = 1;
    repeated string policy_ids = 2;
}

message IndividualAttestationRequest {
    string tee = 1;
    string evidence = 3;
    oneof runtime_data {
        string raw_runtime_data = 4;
        string structured_runtime_data = 5;
    }
    oneof init_data {
        string init_data_digest = 6;
        string init_data_toml = 7;
    }
    string runtime_data_hash_algorithm = 8;
}

message AttestationResponse {
    string attestation_token = 1;
}

message SetPolicyRequest {
    string policy_id = 1;
    string policy = 2;
}
message SetPolicyResponse {}

message ChallengeRequest {
    map<string, string> inner = 1;
}
message ChallengeResponse {
    string attestation_challenge = 1;
}

service AttestationService {
    rpc AttestationEvaluate(AttestationRequest) returns (AttestationResponse) {};
    rpc SetAttestationPolicy(SetPolicyRequest) returns (SetPolicyResponse) {};
    rpc GetAttestationChallenge(ChallengeRequest) returns (ChallengeResponse) {};
}
EOF
        PROTO_DIR="/var/tmp/trustee-protos"
    fi

    # Ensure reference.proto is also available in PROTO_DIR
    if [[ ! -f "${PROTO_DIR}/reference.proto" ]]; then
        if [[ -f "${SCRIPT_DIR}/protos/reference.proto" ]]; then
            cp "${SCRIPT_DIR}/protos/reference.proto" "${PROTO_DIR}/" 2>/dev/null || true
        elif [[ -f "/etc/trustee/reference.proto" ]]; then
            cp "/etc/trustee/reference.proto" "${PROTO_DIR}/" 2>/dev/null || true
        else
            mkdir -p "${PROTO_DIR}"
            cat >"${PROTO_DIR}/reference.proto" <<'EOF'
syntax = "proto3";

package reference;

message ReferenceValueQueryRequest {
    string reference_value_id = 1;
}

message ReferenceValueQueryResponse {
    optional string reference_value_results = 1;
}

message ReferenceValueRegisterRequest {
    string message = 1;
}

message ReferenceValueRegisterResponse {}

service ReferenceValueProviderService {
    rpc QueryReferenceValue(ReferenceValueQueryRequest) returns (ReferenceValueQueryResponse) {};
    rpc RegisterReferenceValue(ReferenceValueRegisterRequest) returns (ReferenceValueRegisterResponse) {};
}
EOF
        fi
    fi
    return 0
}

# Poll a TCP port until it listens or timeout expires.
# wait_for_port <host> <port> [timeout_seconds]
wait_for_port() {
    local host="$1" port="$2" timeout="${3:-30}"
    local elapsed=0
    while ! (echo >"/dev/tcp/${host}/${port}") 2>/dev/null; do
        if ((elapsed >= timeout)); then
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 0
}

# Run a command on the guest, either locally or via ssh.
# Accepts a single command string (executed through a shell on the target).
ssh_guest() {
    local cmd="$*"
    if [[ -z "$GUEST_IP" ]]; then
        _log "CMD" "[guest:local] ${cmd}"
        bash -c "$cmd"
    else
        _log "CMD" "[guest:${GUEST_USER}@${GUEST_IP}] ${cmd}"
        ssh -i "$SSH_KEY" \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            -o BatchMode=yes \
            "${GUEST_USER}@${GUEST_IP}" "$cmd"
    fi
}

# Effective KBS URL (explicit --kbs-url wins, else http://KBS_HOST:KBS_PORT).
kbs_url() {
    if [[ -n "$KBS_URL" ]]; then
        echo "$KBS_URL"
    else
        echo "http://${KBS_HOST}:${KBS_PORT}"
    fi
}

# Resolve the kbs-client binary: $PATH first, then the distro package path
# (kbs-client ships in the trustee package, not in $PATH).
resolve_kbs_client_bin() {
    local bin
    bin="$(command -v kbs-client 2>/dev/null || true)"
    [[ -n "$bin" ]] || bin="$(distro_kbs_client_bin)"
    echo "$bin"
}

confirm() {
    local prompt="${1:-Continue?}"
    if ((FORCE)); then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Confirmation required but stdin is not a tty. Re-run with -f/--force."
    fi
    local answer
    read -r -p "${prompt} [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}
# Install only the packages that are actually missing (host). Keeps re-runs
# quiet and avoids a network round-trip when the stack is already in place.
# Metadata is refreshed at most once per run, and only if something needs
# installing. Distro-specific via the lib/distros/ adapter.
PKG_REFRESHED=0
install_pkgs() {
    local pkg missing=()
    for pkg in "$@"; do
        distro_pkg_installed "$pkg" || missing+=("$pkg")
    done
    if ((${#missing[@]} == 0)); then
        log "Already installed: $*"
        return 0
    fi
    log "Installing missing packages: ${missing[*]}"
    if ((! PKG_REFRESHED)); then
        distro_pkg_refresh
        PKG_REFRESHED=1
    fi
    distro_pkg_install "${missing[@]}"
}

# Same idea, inside the guest over ssh (or locally when no GUEST_IP is set).
# The guest distro is detected once over ssh — it may differ from the host.
install_pkgs_guest() {
    guest_distro_pkg_install "$@"
}

# Probe whether a guest kbs-client binary has the SNP attester compiled in.
# A build WITH the feature references /dev/sev-guest; a build WITHOUT it
# instead carries the string "`snp-attester` feature is not enabled!".
# Static probe: no SNP VM, network, or binutils required.
kbs_client_supports_snp_guest() { # guest-side: kbs_client_supports_snp_guest <guest-path>
    ssh_guest "test -x '$1' && grep -aq '/dev/sev-guest' '$1'"
}

# Find a SNP-capable OVMF firmware (distro-specific probe, see lib/distros/).
# Prints "descriptor|binary" on success, returns 1 otherwise.
find_snp_ovmf() {
    distro_ovmf_snp_probe
}

# Probe whether the AMD KDS endpoint is reachable (or, in offline mode, that
# the local certificate store is populated). Returns 0 on success.
probe_kds_url() {
    local url="$1"
    # The KDS VCEK API is a GET endpoint. Probe the base URL and a known
    # sub-path; accept any HTTP response (200/400/404) as "reachable".
    local base="${url%/}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$base" 2>/dev/null || echo "000")
    if [[ "$code" == "200" || "$code" == "400" || "$code" == "404" || "$code" == "401" ]]; then
        return 0
    fi
    # Some KDS deployments only answer on the /vcek/... path.
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${base}/ark" 2>/dev/null || echo "000")
    if [[ "$code" == "200" || "$code" == "400" || "$code" == "404" || "$code" == "401" ]]; then
        return 0
    fi
    return 1
}

# Effective collateral endpoint. In 'offline' mode there is no remote URL —
# the local cert store is used instead (returns empty).
kds_url() {
    if [[ "$COLLATERAL_MODE" == "offline" ]]; then
        echo ""
    else
        echo "$KDS_URL"
    fi
}

ensure_libvirt() {
    if virsh -c qemu:///system version >/dev/null 2>&1; then
        log "libvirt reachable on qemu:///system"
        return 0
    fi

    local unit started=0
    for unit in virtqemud.socket virtnetworkd.socket virtstoraged.socket; do
        if systemctl list-unit-files "$unit" >/dev/null 2>&1 &&
            systemctl cat "$unit" >/dev/null 2>&1; then
            warn "libvirt not reachable, enabling ${unit}"
            run systemctl enable --now "$unit"
            started=1
        fi
    done

    if ((! started)); then
        warn "No modular libvirt sockets found, trying monolithic libvirtd.service"
        run systemctl enable --now libvirtd.service
    fi

    virsh -c qemu:///system version >/dev/null 2>&1 ||
        die "libvirt still unreachable on qemu:///system.
Install the QEMU driver ($(distro_pkg_manager) in $(distro_pkgs libvirt))
and check: systemctl status virtqemud.socket virtqemud.service"
}

# setup-vm needs virt-customize (guestfs-tools) to inject the SSH key into
# the guest disk offline. A SNP guest has no host-side console, so a missing
# tool here would leave the VM unreachable — install it instead of degrading
# to a manual step.
ensure_virt_customize() {
    command -v virt-customize >/dev/null 2>&1 && return 0
    log "virt-customize missing — installing $(distro_pkgs virt_customize)"
    install_pkgs $(distro_pkgs virt_customize)
    command -v virt-customize >/dev/null 2>&1 ||
        die "virt-customize still not available after install.
Install $(distro_pkgs virt_customize) manually ($(distro_pkg_manager)), then re-run."
}

# Auto-detect guest IP from running VMs if GUEST_IP is not set.
# Lists running VMs with their IPs, auto-selects if only one, prompts otherwise.
# Sets GUEST_IP on success; dies on failure.
# Shared interactive VM picker (used by detect_guest_ip and cmd_convert_snp).
# Arguments: header, prompt, hint (appended to the no-tty / invalid-selection
# die messages), display lines (newline-separated, one per VM) and VM names
# (newline-separated, same order). Prints the numbered list and sets the
# global PICKED_VM_NAME; auto-selects when there is exactly one VM.
pick_vm_interactively() {
    local header="$1" prompt="$2" hint="$3" lines="$4" names="$5"
    local -a vm_names=() vm
    while IFS= read -r vm; do
        [[ -n "$vm" ]] && vm_names+=("$vm")
    done <<<"$names"
    local -a display=() line
    while IFS= read -r line; do
        [[ -n "$line" ]] && display+=("$line")
    done <<<"$lines"
    local i=1
    echo ""
    echo "$header"
    for line in "${display[@]}"; do
        echo "  ${i}) ${line}"
        ((i++))
    done
    echo ""
    if ((${#vm_names[@]} == 1)); then
        PICKED_VM_NAME="${vm_names[0]}"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Interactive selection requires a tty. ${hint}"
    fi
    local choice
    read -r -p "$prompt" choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#vm_names[@]})); then
        PICKED_VM_NAME="${vm_names[choice - 1]}"
    else
        die "Invalid selection. ${hint}"
    fi
}

detect_guest_ip() {
    [[ -n "$GUEST_IP" ]] && return 0
    if ! command -v virsh >/dev/null 2>&1; then
        die "--guest-ip is required (virsh not available for auto-detection). Usage: ${SCRIPT_NAME} <cmd> --guest-ip <IP>"
    fi
    local running_vms
    # grep exits 1 on empty input (no running VMs / virsh failed); the empty
    # check below handles that case, so don't let the ERR trap fire here.
    running_vms=$(virsh list --name 2>/dev/null | grep -v '^$' || true)
    if [[ -z "$running_vms" ]]; then
        warn "No VM is running (virsh list is empty)"
        die "Start the guest VM first, or pass --guest-ip <IP>."
    fi
    local vm ip
    local -a vm_names=() vm_ips=() display=()
    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        ip=$(virsh domifaddr "$vm" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1 || true)
        vm_names+=("$vm")
        vm_ips+=("${ip:-unknown}")
        display+=("${vm}  [${ip:-no IP detected}]")
    done <<<"$running_vms"
    pick_vm_interactively "Running VMs:" "Enter VM number: " \
        "Re-run with --guest-ip <IP>." \
        "$(printf '%s\n' "${display[@]}")" "$(printf '%s\n' "${vm_names[@]}")"
    local idx
    for idx in "${!vm_names[@]}"; do
        if [[ "${vm_names[$idx]}" == "$PICKED_VM_NAME" ]]; then
            GUEST_IP="${vm_ips[$idx]}"
            break
        fi
    done
    if ((${#vm_names[@]} == 1)); then
        log "Auto-detected guest: ${vm_names[0]} (IP: ${GUEST_IP})"
    else
        log "Selected guest: ${vm_names[$idx]} (IP: ${GUEST_IP})"
    fi
    if [[ -z "$GUEST_IP" || "$GUEST_IP" == "unknown" ]]; then
        die "No IP detected for the selected VM. Check the guest (agent/ARP) or pass --guest-ip <IP>."
    fi
}
