#!/usr/bin/env bash
# =============================================================================
# snp-attest.sh — AMD SEV-SNP attestation test & setup
#
# Copyright (C) 2026 aginies
# SPDX-License-Identifier: GPL-3.0-only
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, either version 3 of the License. See the
# LICENSE file for the full text (`show-w` / `show-c` print the terms).
#
# Based on the AMD SEV-SNP attestation documentation:
#   - amd-attestation-snphost.md   (SLES 16.1 snphost 0.7.0 host-side verify)
#   - amd-attestation-snpguest.md  (SLES 16.1 snpguest 0.10.0 guest-side report)
#
# Commands (host / SNP server):
#   check          Test host capabilities (read-only, no root required)
#   verify         Double-check attestation config is correct (read-only)
#   setup-host     Install snphost, verify host SEV-SNP, fetch KDS certs
#   setup-trustee  Install/configure/start Trustee stack (CoCo-AS, KBS, RVPS)
#   setup-vm       Create SNP VM (qcow2 + XML), inject SSH key, start
#   convert-snp    Convert an existing (non-SNP) VM to a SNP VM in-place
#   show-vm-info   List all VMs with status and IP address
#   secret-set     Store a secret in the KBS (admin), released after attestation
#   all            check -> setup-host -> setup-trustee -> setup-vm
#   clean          Destroy VM, stop services
#
# Commands (host, act inside SNP guest over ssh):
#   setup-guest    Inside guest (or via ssh): install snpguest, generate report
#   attest         Remote attestation: report -> CoCo-AS -> EAR token
#   secret-get     Fetch a KBS secret from inside the SNP guest
#
# Collateral source (--collateral):
#   kds     (default) fetch the ARK/ASK/VCEK chain directly from AMD's global KDS
#   offline use a locally-provisioned certificate store (air-gapped)
#
# Usage: snp-attest.sh <command> [options]
#        snp-attest.sh -h | --help
#
# Sections 8-9 below reference variables and helpers defined in lib/*.sh
# (sourced below) — SC2034/SC2153 "unused/unassigned" warnings from static
# analysis are expected cross-file references, SC2155 for the SCRIPT_DIR
# readonly assignment. Suppressed here, as in lib/constants.sh.
# shellcheck disable=SC2034,SC2153,SC2155
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# LIBRARY FILES
# =============================================================================
# The implementation is split into lib/*.sh, sourced in dependency order:
#   constants.sh   1. constants & defaults
#   logging.sh     2. logging & error handling
#   helpers.sh     3. generic helpers
#   license.sh     3b. license notices
#   checks.sh      4. capability checks + 4b. config verification
#   setup-host.sh  5. host setup (snphost, KDS collateral, Trustee)
#   setup-vm.sh    6. VM setup (libvirt, guest)
#   attest.sh      7. remote attestation + RVPS
#   secret.sh      7b. secret delivery (KBS)
# This file keeps only the orchestration (section 8) and CLI (section 9).
#
# Distribution adapters (lib/distros/): the install layer (package manager,
# package names, binary paths) is distro-specific. The host distro is
# detected from /etc/os-release and lib/distros/<id>.sh is sourced; the
# guest distro is detected separately over ssh (it may differ from the host).
# Override the host detection with SNP_ATTEST_DISTRO=sles|fedora|debian.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _lib in constants logging helpers license checks setup-host setup-vm attest secret; do
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/lib/${_lib}.sh"
done
unset _lib

# Distribution adapter: detect the host distro and load lib/distros/<id>.sh.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/distros/_detect.sh"
DISTRO_ID="$(detect_host_distro)"
[[ -f "${SCRIPT_DIR}/lib/distros/${DISTRO_ID}.sh" ]] ||
    die "Unsupported distribution (no adapter lib/distros/${DISTRO_ID}.sh); set SNP_ATTEST_DISTRO to force one."
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/distros/${DISTRO_ID}.sh"
_stub_var="${DISTRO_ID}_stub"
if [[ "${!_stub_var:-0}" == "1" ]]; then
    die "Distribution '${DISTRO_ID}' detected, but its adapter (lib/distros/${DISTRO_ID}.sh) is not implemented yet."
fi
log "Distribution: ${DISTRO_ID} (adapter: lib/distros/${DISTRO_ID}.sh)"

# =============================================================================
# 8. ORCHESTRATION
# =============================================================================

cmd_all() {
    log "=== Full SEV-SNP attestation setup ==="

    log "--- Step 1/4: capability check ---"
    if ! cmd_check; then
        die "Capability check found hard failures. Fix them (see hints) and re-run."
    fi

    log "--- Step 2/4: host setup ---"
    cmd_setup_host

    log "--- Step 3/4: Trustee setup ---"
    cmd_setup_trustee

    log "--- Step 4/4: VM setup ---"
    cmd_setup_vm

    log "--- Verifying host-side configuration ---"
    cmd_verify || warn "Config verification reported failures (see table above)."

    cat <<'NEXT'

=== 'all' complete up to VM start ===
Remaining steps (manual guest install first, see printed instructions above):

  1. Install SLE in the VM:            virsh console snp-guest
  2. Find guest IP:                    virsh net-dhcp-leases default
  3. Setup guest + generate report:    sudo snp-attest.sh setup-guest --guest-ip <IP>
  4. Remote attestation:               sudo snp-attest.sh attest --guest-ip <IP>
NEXT
}

cmd_clean() {
    require_root
    log "=== Cleaning up SEV-SNP attestation environment ==="

    if ! confirm "Stop Trustee services and destroy/undefine VM '${VM_NAME}'?"; then
        log "Clean aborted."
        return 0
    fi

    local svc
    for svc in trustee.service rvps.service kbs.service grpc-as.service; do
        if systemctl is-active "$svc" >/dev/null 2>&1; then
            log "Stopping ${svc}"
            run systemctl stop "$svc" || warn "Failed to stop ${svc}"
        fi
    done

    if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
        log "Destroying VM ${VM_NAME}"
        run virsh destroy "$VM_NAME" || true
        log "Undefining VM ${VM_NAME}"
        if virsh undefine "$VM_NAME" 2>/dev/null; then
            log "VM undefined"
        elif virsh undefine --nvram "$VM_NAME" 2>/dev/null; then
            log "VM undefined (with NVRAM)"
        else
            warn "Failed to undefine VM ${VM_NAME}"
        fi
    else
        log "VM ${VM_NAME} not found, skipping"
    fi

    log "Clean complete. Disk image kept at ${VM_DISK_PATH} (remove manually if desired)."
    log "Also kept: /etc/trustee (keys, policy), /etc/grpc-as.json, /etc/kbs.json, /etc/rvps.json,"
    log "systemd drop-ins (kbs.service.d, grpc-as.service.d), ${SNP_CERT_DIR}, ${SSH_KEY}."
}

# =============================================================================
# 9. CLI PARSING & DISPATCH
# =============================================================================

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — AMD SEV-SNP attestation test & setup

License: GPLv3 — see the LICENSE file next to the script.
\`show-w\` / \`show-c\` print the warranty / copyright terms.

Usage: ${SCRIPT_NAME} <command> [options]
       Options come AFTER the command: '${SCRIPT_NAME} all -d'

Output: each step prints a [STEP] explanation of what it does and why, and
every command executed is echoed as '[CMD] \$ ...' before it runs (guest
commands are tagged with the target). Use -q to show errors only.

=== DIAGNOSTICS (read-only, no root) ===
  check            Test host capabilities (SEV-SNP, QEMU, libvirt, kernel)
  check-platform   Validate platform TCB/collateral on AMD KDS
  verify           Audit attestation config (files, services, ports, VM)
  show-vm-info     List all VMs with status and IP address

=== HOST SETUP (root) ===
  setup-host       Install snphost, verify host SEV-SNP, fetch KDS certificates
  setup-trustee    Install/configure/start Trustee (CoCo-AS, KBS, RVPS)
  setup-vm         Create SNP VM (qcow2 + XML), inject SSH key, start
  convert-snp      Convert an existing (non-SNP) VM to a SNP VM in-place
  all              check -> setup-host -> setup-trustee -> setup-vm

=== GUEST (run on host, acts inside the SNP VM over ssh) ===
  setup-guest      Install guest libs, verify SNP VM, generate a report
  attest           Remote attestation: report -> CoCo-AS -> EAR token
  register-rv      Enroll guest identity into RVPS
  query-rv         Query an RVPS reference value
  secret-set       Store a secret in KBS (admin)
  secret-get       Fetch a KBS secret (gated by attestation)

=== LIFECYCLE ===
  clean            Stop services, destroy/undefine VM

=== LICENSE & HELP ===
  show-w           Show the warranty terms (no warranty)
  show-c           Show the copyright & license terms (GPLv3, see LICENSE)
  help             Show this help

Typical workflow:
  1. sudo ${SCRIPT_NAME} check
  2. sudo ${SCRIPT_NAME} all --guest-iso /path/to/SLE-16.1.x86_64.iso
  3. (manual) install SLES in the VM, find its IP (show-vm-info)
  4. sudo ${SCRIPT_NAME} setup-guest --guest-ip <GUEST_IP>
  5. sudo ${SCRIPT_NAME} attest --guest-ip <GUEST_IP>
  6. sudo ${SCRIPT_NAME} secret-set --file /tmp/my-secret --path ${SECRET_PATH}
  7. sudo ${SCRIPT_NAME} secret-get --guest-ip <GUEST_IP> --path ${SECRET_PATH}

Options:
  General:
    -d, --debug            Debug mode: set -x trace with timestamps
    -v, --verbose          Info-level logging (default)
    -q, --quiet            Errors only
    -f, --force            Skip confirmations
    --log-file FILE        Log file (default: ${LOG_FILE})
  Platform & collateral:
    --check-platform       Also run platform validity check during 'check'
    --collateral MODE      kds (global AMD KDS, default) or offline (local store)
    --kds-url URL          AMD KDS endpoint (default: ${KDS_URL})
    --insecure             Disable TLS certificate verification for KDS
  Attestation:
    --coco-as HOST:PORT    CoCo-AS endpoint (default: ${COCO_AS})
    --register-rv          Auto-enroll RVPS reference values during 'attest'
    --id NAME              Reference value id for query-rv (default: id_block)
  VM:
    --guest-iso PATH       SLE installer ISO to attach to the VM
    --vm-name NAME         VM name (default: ${VM_NAME})
    --vm-mem MB            VM memory in MiB (default: ${VM_MEM})
    --vm-cpu N             VM vCPUs (default: ${VM_CPU})
    --vm-disk SIZE         VM disk size (default: ${VM_DISK})
    --vnc-listen ADDR      VNC listen address (default: ${VNC_LISTEN})
    --vnc-port PORT        VNC port (default: ${VNC_PORT})
    --virt-install         Use virt-install for VM creation (default: auto-detect)
    --no-virt-install      Use generated XML instead of virt-install
    --dry-run              setup-vm: print the virt-install command, do not run
    --no-snp               Create VM without SNP launch security (test-only)
    --convert-vm NAME      VM to convert to SNP (convert-snp, auto-detected)
    --ssh-key PATH         SSH key for guest (default: ${SSH_KEY}, auto-created)
  Guest & KBS:
    --guest-ip IP          Guest IP for ssh (setup-guest, attest, secret-get, ...)
    --kbs-url URL          KBS URL (default: http://${KBS_HOST}:${KBS_PORT})
    --kbs-host HOST        KBS host reachable by guest (default: ${KBS_HOST})
    --path PATH            KBS resource path (default: ${SECRET_PATH})
    --file PATH            Secret file: source (secret-set) / dest (secret-get)
    --mode MODE            secret-get: guest (in-guest kbs-client, default)
                           or host (host-side attest with a host TEE key +
                           JWE decrypt; no kbs-client needed)

Advanced examples:
  sudo ${SCRIPT_NAME} all --collateral offline
  sudo ${SCRIPT_NAME} convert-snp --convert-vm nonsnp-guest
  sudo ${SCRIPT_NAME} secret-get --guest-ip <GUEST_IP> --path ${SECRET_PATH} --mode host
  sudo ${SCRIPT_NAME} attest --guest-ip <GUEST_IP> --register-rv
  sudo ${SCRIPT_NAME} all -d --log-file /tmp/snp.log
EOF
}

req_val() {
    if [[ -z "${2:-}" ]]; then
        die "Option $1 requires a value"
    fi
}

parse_args() {
    if (($# == 0)); then
        usage
        exit 1
    fi

    local command=""
    if [[ "$1" != -* ]]; then
        command="$1"
        shift
    fi

    while (($# > 0)); do
        case "$1" in
        -d | --debug) DEBUG=1 ;;
        -v | --verbose) ;;
        -q | --quiet) QUIET=1 ;;
        -f | --force) FORCE=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        --check-platform)
            CHECK_PLATFORM=1
            ;;
        --collateral)
            req_val "$1" "${2:-}"
            COLLATERAL_MODE="$2"
            shift
            ;;
        --kds-url)
            req_val "$1" "${2:-}"
            KDS_URL="$2"
            shift
            ;;
        --insecure | --no-secure-cert)
            USE_SECURE_CERT="false"
            ;;
        --use-secure-cert)
            USE_SECURE_CERT="true"
            ;;
        --coco-as)
            req_val "$1" "${2:-}"
            COCO_AS="$2"
            shift
            ;;
        --guest-ip)
            req_val "$1" "${2:-}"
            GUEST_IP="$2"
            shift
            ;;
        --guest-iso)
            req_val "$1" "${2:-}"
            GUEST_ISO="$2"
            shift
            ;;
        --vnc-listen)
            req_val "$1" "${2:-}"
            VNC_LISTEN="$2"
            shift
            ;;
        --vnc-port)
            req_val "$1" "${2:-}"
            VNC_PORT="$2"
            shift
            ;;
        --virt-install) VM_CREATOR="virt" ;;
        --no-virt-install) VM_CREATOR="xml" ;;
        --dry-run) DRY_RUN=1 ;;
        --register-rv)
            REGISTER_RV=1
            ;;
        --id)
            req_val "$1" "${2:-}"
            RV_ID="$2"
            shift
            ;;
        --kbs-url)
            req_val "$1" "${2:-}"
            KBS_URL="$2"
            shift
            ;;
        --kbs-host)
            req_val "$1" "${2:-}"
            KBS_HOST="$2"
            shift
            ;;
        --path)
            req_val "$1" "${2:-}"
            SECRET_PATH="$2"
            shift
            ;;
        --file)
            req_val "$1" "${2:-}"
            SECRET_FILE="$2"
            shift
            ;;
        --mode)
            req_val "$1" "${2:-}"
            SECRET_MODE="$2"
            shift
            ;;
        --ssh-key)
            req_val "$1" "${2:-}"
            SSH_KEY="$2"
            shift
            ;;
        --vm-name)
            req_val "$1" "${2:-}"
            VM_NAME="$2"
            VM_DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
            VM_XML_PATH="/var/lib/libvirt/${VM_NAME}.xml"
            VM_NO_SNP_DISK_PATH="/var/lib/libvirt/images/${VM_NO_SNP_NAME}.qcow2"
            VM_NO_SNP_XML_PATH="/var/lib/libvirt/${VM_NO_SNP_NAME}.xml"
            shift
            ;;
        --vm-mem)
            req_val "$1" "${2:-}"
            VM_MEM="$2"
            shift
            ;;
        --vm-cpu)
            req_val "$1" "${2:-}"
            VM_CPU="$2"
            shift
            ;;
        --vm-disk)
            req_val "$1" "${2:-}"
            VM_DISK="$2"
            shift
            ;;
        --log-file)
            req_val "$1" "${2:-}"
            LOG_FILE="$2"
            shift
            ;;
        --no-snp) VM_NO_SNP=1 ;;
        --convert-vm)
            req_val "$1" "${2:-}"
            CONVERT_VM_NAME="$2"
            shift
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
        esac
        shift
    done

    [[ -n "$command" ]] || {
        usage
        exit 1
    }

    case "$SECRET_MODE" in
    guest | host) ;;
    *) die "Invalid --mode '${SECRET_MODE}' (must be 'guest' or 'host')" ;;
    esac

    case "$COLLATERAL_MODE" in
    kds | offline) ;;
    *) die "Invalid --collateral '${COLLATERAL_MODE}' (must be 'kds' or 'offline')" ;;
    esac

    # Classic GPL notice when a human is at the terminal (interactive mode);
    # silent in automated/piped runs (see lib/license.sh).
    license_banner

    case "$command" in
    check)
        init_debug
        cmd_check
        ;;
    check-platform)
        init_debug
        cmd_check_platform
        ;;
    verify)
        init_debug
        cmd_verify
        ;;
    setup-host)
        init_debug
        cmd_setup_host
        ;;
    setup-trustee)
        init_debug
        cmd_setup_trustee
        ;;
    setup-vm)
        init_debug
        cmd_setup_vm
        ;;
    convert-snp)
        init_debug
        cmd_convert_snp
        ;;
    show-vm-info)
        init_debug
        cmd_show_vm_info
        ;;
    setup-guest)
        init_debug
        cmd_setup_guest
        ;;
    attest)
        init_debug
        cmd_attest
        ;;
    register-rv | rvps-register)
        init_debug
        cmd_register_rv
        ;;
    query-rv | rvps-query)
        init_debug
        cmd_query_rv
        ;;
    secret-set)
        init_debug
        cmd_secret_set
        ;;
    secret-get)
        init_debug
        cmd_secret_get
        ;;
    all)
        init_debug
        cmd_all
        ;;
    clean)
        init_debug
        cmd_clean
        ;;
    show-w)
        license_show_warranty
        ;;
    show-c)
        license_show_copyright
        ;;
    help) usage ;;
    *)
        error "Unknown command: ${command}"
        usage
        exit 1
        ;;
    esac
}

main() {
    parse_args "$@"
}

main "$@"
