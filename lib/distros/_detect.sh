# =============================================================================
# Distribution detection & adapter dispatch  — AMD SEV-SNP
# =============================================================================
# The install layer (package manager, package names, binary paths) is
# distribution-specific. Each adapter lib/distros/<id>.sh implements a
# namespaced hook contract:
#
#   <id>_pkg_manager            -> echo the package manager binary
#   <id>_pkg_refresh            -> refresh package metadata
#   <id>_pkg_installed <p>      -> rc 0 if <p> is installed
#   <id>_pkg_install <p...>     -> install packages
#   <id>_pkg_list_all           -> list installed packages (one per line)
#   <id>_pkgs_<role>            -> package name list for a role (word list)
#   <id>_snp_host_bin           -> host snphost binary path
#   <id>_snp_guest_bin          -> guest snpguest binary path
#   <id>_kbs_bin / <id>_kbs_client_bin / <id>_grpc_as_bin  -> binary paths
#   <id>_trustee_needs_symlinks -> 1/0 (SUSE ships /usr/libexec/trustee/<name>)
#   <id>_ovmf_fwdir             -> QEMU firmware descriptor dir
#   <id>_ovmf_snp_probe         -> echo "descriptor|binary" of a SNP OVMF
#   <id>_ovmf_regular_probe     -> echo a non-SNP pflash OVMF binary (--no-snp)
#   <id>_grub_snp_hint          -> echo the SEV-SNP kernel-cmdline hint
#   <id>_ca_trust_refresh       -> refresh the host system trust store
#   <id>_ca_trust_cmd           -> remote cmd (stdin=CA) to trust a CA in the guest
#   <id>_guest_pkg_install <p...> -> install inside the guest over ssh
#   <id>_guest_repo_add         -> register the SNP package repo in the guest
#                                  (optional; omitted = no extra repo needed)
#
# Roles: snp_host, snp_guest, trustee, libvirt, qemu, virt_customize, ovmf,
#        grpcurl
#
# The un-namespaced dispatchers below resolve against DISTRO_ID (host) or
# GUEST_DISTRO (guest, detected over ssh — the guest may run a different
# distribution than the host). Host override for testing / unlisted
# derivatives: SNP_ATTEST_DISTRO=sles|fedora|debian

# Classify raw os-release ID / ID_LIKE values into an adapter id.
classify_distro() {
    local id="${1:-}" id_like="${2:-}"
    case " ${id} ${id_like} " in
    *sles* | *opensuse* | *suse*) echo "sles" ;;
    *fedora* | *rhel* | *centos*) echo "fedora" ;;
    *debian* | *ubuntu*) echo "debian" ;;
    *) echo "unknown" ;;
    esac
}

# Detect the host distribution (SNP_ATTEST_DISTRO override wins).
detect_host_distro() {
    if [[ -n "${SNP_ATTEST_DISTRO:-}" ]]; then
        echo "$SNP_ATTEST_DISTRO"
        return 0
    fi
    local id="" id_like=""
    if [[ -r /etc/os-release ]]; then
        id=$(sed -n 's/^ID=//p' /etc/os-release | head -1 | tr -d '"')
        id_like=$(sed -n 's/^ID_LIKE=//p' /etc/os-release | head -1 | tr -d '"')
    fi
    classify_distro "$id" "$id_like"
}

# --- Host-side dispatchers (resolve against DISTRO_ID) -----------------------
distro_pkg_manager() {
    local v="${DISTRO_ID}_pkg_manager"
    echo "${!v:-}"
}
distro_pkg_refresh() { "${DISTRO_ID}_pkg_refresh"; }
distro_pkg_installed() { "${DISTRO_ID}_pkg_installed" "$@"; }
distro_pkg_install() { "${DISTRO_ID}_pkg_install" "$@"; }
distro_pkg_list_all() { "${DISTRO_ID}_pkg_list_all"; }
distro_pkgs() {
    local v="${DISTRO_ID}_pkgs_$1"
    echo "${!v:-}"
}
distro_snp_host_bin() {
    local v="${DISTRO_ID}_snp_host_bin"
    echo "${!v:-}"
}
distro_kbs_bin() {
    local v="${DISTRO_ID}_kbs_bin"
    echo "${!v:-}"
}
distro_kbs_client_bin() {
    local v="${DISTRO_ID}_kbs_client_bin"
    echo "${!v:-}"
}
distro_grpc_as_bin() {
    local v="${DISTRO_ID}_grpc_as_bin"
    echo "${!v:-}"
}
distro_trustee_needs_symlinks() {
    local v="${DISTRO_ID}_trustee_needs_symlinks"
    echo "${!v:-0}"
}
distro_ovmf_fwdir() {
    local v="${DISTRO_ID}_ovmf_fwdir"
    echo "${!v:-}"
}
distro_ovmf_snp_probe() { "${DISTRO_ID}_ovmf_snp_probe" "$@"; }
distro_ovmf_regular_probe() { "${DISTRO_ID}_ovmf_regular_probe" "$@"; }
distro_grub_snp_hint() { "${DISTRO_ID}_grub_snp_hint"; }
distro_ca_trust_refresh() { "${DISTRO_ID}_ca_trust_refresh"; }

# --- Guest-side dispatchers (resolve against GUEST_DISTRO) -------------------
GUEST_DISTRO=""

# Detect the guest distribution once over ssh (falls back to the host's when
# detection fails) and make sure its adapter is loaded.
ensure_guest_distro() {
    [[ -n "$GUEST_DISTRO" ]] && return 0
    local os id id_like
    os=$(ssh_guest '. /etc/os-release 2>/dev/null; echo "${ID:-} ${ID_LIKE:-}"' 2>/dev/null || echo "")
    id="${os%% *}"
    id_like="${os#* }"
    [[ "$id_like" == "$os" ]] && id_like=""
    GUEST_DISTRO=$(classify_distro "$id" "$id_like")
    if [[ "$GUEST_DISTRO" == "unknown" ]]; then
        GUEST_DISTRO="$DISTRO_ID"
        log "Guest distro detection failed; assuming host distro: ${GUEST_DISTRO}"
    else
        log "Guest distro: ${GUEST_DISTRO}"
    fi
    local adapter
    adapter="${SCRIPT_DIR}/lib/distros/${GUEST_DISTRO}.sh"
    [[ -f "$adapter" ]] || die "No distribution adapter for guest: ${GUEST_DISTRO} (expected ${adapter})"
    # shellcheck source=/dev/null
    source "$adapter"
    local stub_var="${GUEST_DISTRO}_stub"
    if [[ "${!stub_var:-0}" == "1" ]]; then
        die "Guest distribution adapter '${GUEST_DISTRO}' is not implemented yet (lib/distros/${GUEST_DISTRO}.sh is a stub)."
    fi
}

guest_distro_ca_trust_cmd() {
    ensure_guest_distro
    local v="${GUEST_DISTRO}_ca_trust_cmd"
    echo "${!v:-}"
}

guest_distro_pkgs() {
    ensure_guest_distro
    local v="${GUEST_DISTRO}_pkgs_$1"
    echo "${!v:-}"
}

guest_distro_kbs_client_bin() {
    ensure_guest_distro
    local v="${GUEST_DISTRO}_kbs_client_bin"
    echo "${!v:-}"
}

guest_distro_snp_guest_bin() {
    ensure_guest_distro
    local v="${GUEST_DISTRO}_snp_guest_bin"
    echo "${!v:-}"
}

guest_distro_pkg_install() {
    ensure_guest_distro
    "${GUEST_DISTRO}_guest_pkg_install" "$@"
}

# Register the SNP attestation package repository inside the guest. Adapters
# that need no extra repo can leave the hook undefined — this is a no-op then.
guest_distro_repo_add() {
    ensure_guest_distro
    local hook="${GUEST_DISTRO}_guest_repo_add"
    if declare -F "$hook" >/dev/null 2>&1; then
        "$hook"
    else
        log "No guest repo hook for ${GUEST_DISTRO}; assuming the SNP packages are in the default repos."
    fi
}
