# =============================================================================
# 4. CAPABILITY CHECKS (read-only probes)  — AMD SEV-SNP
# =============================================================================

# Each check_* function: prints "PASS|FAIL|WARN: message" and returns 0/1.
# Results collected in CHECK_RESULTS array by cmd_check.

CHECK_RESULTS=()

record() {
    local status="$1" msg="$2" hint="${3:-}"
    CHECK_RESULTS+=("${status}|${msg}|${hint}")
}

# Render CHECK_RESULTS as a table. Sets RESULT_FAILS to the number of FAIL rows.
# (Returns 0 so it never trips 'set -e' / the ERR trap on a nonzero count.)
RESULT_FAILS=0
print_results() {
    # Colorize the STATUS column when writing to a terminal (respect NO_COLOR).
    local c_pass="" c_fail="" c_warn="" c_reset=""
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        c_pass=$'\e[32m'       # green
        c_fail=$'\e[31m'       # red
        c_warn=$'\e[38;5;208m' # orange (256-color; falls back gracefully)
        c_reset=$'\e[0m'
    fi

    echo
    printf '%-6s %-52s %s\n' "STATUS" "CHECK" "HINT"
    printf '%-6s %-52s %s\n' "------" "-----" "----"
    local status msg hint entry color
    RESULT_FAILS=0
    for entry in "${CHECK_RESULTS[@]}"; do
        IFS='|' read -r status msg hint <<<"$entry"
        case "$status" in
        PASS) color="$c_pass" ;;
        FAIL) color="$c_fail" ;;
        WARN) color="$c_warn" ;;
        *) color="" ;;
        esac
        printf '%s%-6s%s %-52s %s\n' "$color" "$status" "$c_reset" "$msg" "$hint"
        [[ "$status" == "FAIL" ]] && RESULT_FAILS=$((RESULT_FAILS + 1))
    done
    echo
    return 0
}

# Validate a JSON file. rc 0 = valid, 1 = invalid, 2 = no validator available.
json_valid() {
    local f="$1" rc
    if command -v jq >/dev/null 2>&1; then
        jq . "$f" >/dev/null 2>&1
        rc=$?
        # jq exits 2/5 on parse errors; normalize any failure to 1.
        if ((rc == 0)); then
            return 0
        fi
        return 1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool "$f" >/dev/null 2>&1
    else
        return 2
    fi
}

check_cpu_snp() {
    # Host advertises 'sev_snp'; a guest advertises 'sev' / 'sev_snp' too.
    # As a fallback, the presence of /dev/sev proves SEV-SNP is active on the host.
    if grep -qwE 'sev_snp|sev' /proc/cpuinfo 2>/dev/null; then
        record "PASS" "CPU/kernel reports SEV-SNP (sev_snp/sev flag)"
    elif [[ -c /dev/sev ]]; then
        record "PASS" "SEV-SNP active on host (/dev/sev present)"
    else
        record "FAIL" "CPU does NOT report SEV-SNP support" \
            "Check CPU is an AMD EPYC with SEV-SNP (Rome/Genoa/Turin+) and SEV-SNP enabled in BIOS"
    fi
}

check_kvm() {
    if [[ -c /dev/kvm ]]; then
        local perms
        perms=$(stat -c '%A %U:%G' /dev/kvm)
        record "PASS" "KVM available: /dev/kvm (${perms})"
    else
        record "FAIL" "KVM not available: /dev/kvm missing" \
            "Enable SVM in BIOS, check 'lsmod | grep kvm', reload kvm_amd"
    fi
}

# Boot parameters that enable SEV-SNP on the host: kvm_amd must be loaded
# with sev_snp=1 and the AMD IOMMU must be on. The effective module
# parameter lives in /sys/module/kvm_amd/parameters/sev_snp (covers both the
# kernel command line and /etc/modprobe.d); /proc/cmdline is scanned as a
# fallback when the module is not loaded yet.
check_boot_params() {
    local cmdline sev_snp="" modprobe_opts
    cmdline=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null || true)
    if [[ -r /sys/module/kvm_amd/parameters/sev_snp ]]; then
        sev_snp=$(cat /sys/module/kvm_amd/parameters/sev_snp)
    fi
    modprobe_opts=$(grep -hiE '^[[:space:]]*options[[:space:]]+kvm_amd([[:space:]]|$)' /etc/modprobe.d/*.conf 2>/dev/null || true)

    if [[ "$sev_snp" == "Y" ]]; then
        record "PASS" "Boot params: kvm_amd loaded with sev_snp=1"
    elif [[ "$sev_snp" == "N" ]]; then
        record "FAIL" "Boot params: kvm_amd loaded with sev_snp=N" \
            "Add 'options kvm_amd sev_snp=1' to /etc/modprobe.d/kvm.conf (or kvm_amd.sev_snp=1 on the kernel cmdline), then: modprobe -r kvm_amd && modprobe kvm_amd"
    elif grep -qxF 'kvm_amd.sev_snp=1' <<<"$cmdline" || grep -q 'sev_snp=1' <<<"$modprobe_opts"; then
        record "WARN" "Boot params: sev_snp=1 configured but kvm_amd not loaded" \
            "modprobe kvm_amd; check 'dmesg | grep -i sev'"
    else
        record "FAIL" "Boot params: kvm_amd.sev_snp=1 not set" \
            "Add 'options kvm_amd sev_snp=1' to /etc/modprobe.d/kvm.conf (or kvm_amd.sev_snp=1 on the kernel cmdline), then reload kvm_amd or reboot"
    fi

    # AMD IOMMU is required for SEV-SNP. Non-empty /sys/kernel/iommu_groups
    # proves it is active even without an explicit cmdline parameter.
    if [[ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
        record "PASS" "Boot params: AMD IOMMU enabled"
    elif grep -qxF 'amd_iommu=on' <<<"$cmdline"; then
        record "PASS" "Boot params: amd_iommu=on in /proc/cmdline"
    else
        record "WARN" "Boot params: AMD IOMMU not detected (required for SEV-SNP)" \
            "Add 'amd_iommu=on iommu=pt' to the kernel cmdline (GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub), then reboot"
    fi

    # AMD Memory Encryption (mem_encrypt) — the kernel-side SEV switch.
    # 'on' is explicit; the default ('auto') works when the CPU supports it,
    # and /dev/sev proves the driver came up. 'off' disables SEV entirely.
    local mem_encrypt
    mem_encrypt=$(grep -oE 'mem_encrypt=[a-z]+' <<<"$cmdline" | head -1 || true)
    case "$mem_encrypt" in
    mem_encrypt=on)
        record "PASS" "Boot params: mem_encrypt=on in /proc/cmdline"
        ;;
    mem_encrypt=off)
        record "FAIL" "Boot params: mem_encrypt=off disables SEV-SNP" \
            "Change to 'mem_encrypt=on' in the kernel cmdline (GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub), then reboot"
        ;;
    *)
        if [[ -c /dev/sev ]]; then
            record "PASS" "Boot params: mem_encrypt not set (default auto; /dev/sev present)"
        else
            record "WARN" "Boot params: mem_encrypt not set and /dev/sev missing" \
                "Add 'mem_encrypt=on' to the kernel cmdline (GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub), then reboot"
        fi
        ;;
    esac
}

# libvirt is modular since SLE 16 / libvirt 5.7: the monolithic libvirtd.service
# is replaced by per-driver daemons (virtqemud, virtnetworkd, virtstoraged),
# normally socket-activated. The functional probe below covers both layouts.
check_libvirt() {
    if ! command -v virsh >/dev/null 2>&1; then
        record "WARN" "libvirt client not installed (virsh missing)" \
            "$(distro_pkg_manager) in $(distro_pkgs libvirt) (required for setup-vm)"
        return
    fi
    if virsh -c qemu:///system version >/dev/null 2>&1; then
        record "PASS" "libvirt running: qemu:///system reachable"
        return
    fi
    # Unreachable: report the installed layout and its unit state.
    local unit state sock sock_state
    for unit in virtqemud.service libvirtd.service; do
        if systemctl cat "$unit" >/dev/null 2>&1; then
            state=$(systemctl is-active "$unit" 2>/dev/null || true)
            sock="${unit%.service}.socket"
            sock_state="n/a"
            if systemctl cat "$sock" >/dev/null 2>&1; then
                sock_state=$(systemctl is-active "$sock" 2>/dev/null || true)
            fi
            if [[ "$state" == "active" || "$sock_state" == "active" ]]; then
                record "WARN" "libvirt units present but qemu:///system unreachable (service=${state:-inactive}, socket=${sock_state})" \
                    "journalctl -u ${unit} -n 50; systemctl status ${sock}"
            else
                record "FAIL" "libvirt not running (${unit}=${state:-inactive}, ${sock}=${sock_state})" \
                    "sudo systemctl enable --now ${sock} (modular) or ${unit} (monolithic)"
            fi
            return
        fi
    done
    record "FAIL" "No libvirt daemon installed (virtqemud.service / libvirtd.service missing)" \
        "$(distro_pkg_manager) in $(distro_pkgs libvirt)"
}

check_qemu() {
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        record "FAIL" "qemu-system-x86_64 not installed" "$(distro_pkg_manager) in $(distro_pkgs qemu)"
        return
    fi
    local ver
    ver=$(qemu-system-x86_64 --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+' | head -1 || true)
    if [[ -z "$ver" ]]; then
        record "FAIL" "QEMU version unparseable" "Check: qemu-system-x86_64 --version"
        return
    fi
    local major="${ver%%.*}"
    if ((major >= 8)); then
        record "PASS" "QEMU version OK: ${ver} (>= 8.0)"
    else
        record "FAIL" "QEMU too old: ${ver} (need >= 8.0)" "Update qemu package"
    fi
}

check_virt_customize() {
    if command -v virt-customize >/dev/null 2>&1; then
        record "PASS" "virt-customize available (guestfs-tools)"
    else
        record "WARN" "virt-customize not installed (guestfs-tools missing)" \
            "$(distro_pkg_manager) in $(distro_pkgs virt_customize) (needed for SSH key injection in setup-vm)"
    fi
}

check_qemu_snp() {
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        record "WARN" "QEMU SNP machine support: skipped (qemu missing)"
        return
    fi
    # SNP is a QEMU *object* (sev-snp-guest), not a machine type. -machine help
    # never lists it; probe the object list instead.
    if qemu-system-x86_64 -object help 2>&1 | grep -qi 'sev-snp-guest'; then
        record "PASS" "QEMU supports SEV-SNP (sev-snp-guest object)"
    else
        record "FAIL" "QEMU has no SEV-SNP support (no sev-snp-guest object)" \
            "Reinstall qemu with SNP target (package: $(distro_pkgs qemu))"
    fi
}

# Locate a SNP-capable OVMF via the QEMU firmware descriptors. Echoes
# "<descriptor>|<ovmf_binary>" for the first SNP firmware found; rc 1 if none.
#
# Unlike TDX (which loads its OVMF as a stateless ROM via '-bios'), SEV-SNP
# uses a *pflash* OVMF with a writable NVRAM variable store (OVMF_VARS.SNP.fd).
# The SLE 16.1 descriptor points at OVMF.SNP.fd (feature "snp").
check_ovmf_snp() {
    local fwdir
    fwdir=$(distro_ovmf_fwdir)
    if [[ ! -d "$fwdir" ]]; then
        record "WARN" "QEMU firmware descriptor dir missing: ${fwdir}" \
            "Install edk2/OVMF ($(distro_pkgs ovmf))"
        return
    fi
    local hit desc bin
    if hit=$(find_snp_ovmf); then
        desc="${hit%%|*}"
        bin="${hit##*|}"
        if [[ -f "$bin" ]]; then
            record "PASS" "SNP OVMF present: ${bin}" "descriptor: ${desc}"
        else
            record "FAIL" "SNP firmware descriptor points to missing OVMF: ${bin}" \
                "Install the OVMF package providing ${bin} (from ${desc})"
        fi
    else
        record "FAIL" "No SNP-capable OVMF firmware descriptor in ${fwdir}" \
            "Install a SNP-enabled edk2/OVMF (descriptor must list the snp feature)"
    fi
}

# Host-side SEV-SNP readiness. The /dev/sev device node is the host's SEV-SNP
# control interface (it exists on the host, NOT inside the guest — the guest
# has /dev/sev-guest instead). kvm_amd must be loaded with SNP support.
check_host_snp() {
    if [[ ! -c /dev/sev ]]; then
        record "FAIL" "/dev/sev missing (SEV-SNP host device not present)" \
            "Load kvm_amd with SNP enabled; check BIOS SEV-SNP and 'dmesg | grep -i sev'"
        return
    fi
    local sev_state
    sev_state=$(snphost ok 2>/dev/null | head -1 || true)
    if command -v snphost >/dev/null 2>&1 && snphost ok >/dev/null 2>&1; then
        record "PASS" "Host SEV-SNP ready (/dev/sev present, snphost ok)"
    elif [[ -n "$sev_state" ]]; then
        record "PASS" "Host SEV-SNP ready (/dev/sev present; snphost not installed yet)"
    else
        record "WARN" "Host SEV-SNP: /dev/sev present but snphost probe not run" \
            "Install snphost ($(distro_pkg_manager) in $(distro_pkgs snp_host)) and re-run"
    fi
}

check_snp_pkgs() {
    local count
    count=$(distro_pkg_list_all | grep -cEi 'snp|sev' || true)
    if [[ "${count:-0}" -gt 0 ]]; then
        record "PASS" "SNP packages installed (${count} packages)"
    else
        record "WARN" "No SNP packages found" "$(distro_pkg_manager) in $(distro_pkgs snp_host) (setup-host)"
    fi
}

check_snphost() {
    if ! command -v snphost >/dev/null 2>&1; then
        record "WARN" "snphost not installed (host SNP verifier)" \
            "$(distro_pkg_manager) in $(distro_pkgs snp_host) (setup-host)"
        return
    fi
    local bin
    bin=$(distro_snp_host_bin)
    if [[ -f "$bin" ]]; then
        record "PASS" "snphost binary present: ${bin}"
    else
        record "WARN" "snphost binary not at expected path: ${bin}" "Check $(distro_pkgs snp_host)"
    fi
    # Certificate store populated?
    if [[ -s "$SNP_ARK_CERT" ]]; then
        record "PASS" "SNP certificate store present: ${SNP_ARK_CERT}"
    else
        record "WARN" "SNP certificate store empty (no ARK at ${SNP_ARK_CERT})" \
            "Run: sudo ${SCRIPT_NAME} setup-host (fetches ARK/ASK/VCEK from KDS)"
    fi
}

check_trustee() {
    local svc
    local missing=()
    for svc in grpc-as.service kbs.service rvps.service; do
        if ! systemctl cat "$svc" >/dev/null 2>&1; then
            missing+=("$svc (not installed)")
        elif [[ "$(systemctl is-active "$svc" 2>/dev/null)" != "active" ]]; then
            missing+=("$svc (not running)")
        fi
    done
    if ((${#missing[@]} == 0)); then
        record "PASS" "Trustee stack running (grpc-as, kbs, rvps)"
    else
        local trustee_pkg
        trustee_pkg=$(distro_pkgs trustee | awk '{print $1}')
        record "WARN" "Trustee stack incomplete: ${missing[*]}" \
            "$(distro_pkg_manager) in ${trustee_pkg}; setup-trustee command"
    fi

    if command -v grpcurl >/dev/null 2>&1; then
        record "PASS" "grpcurl available (for host-side attestation)"
    else
        record "WARN" "grpcurl not installed (needed for host-side attest command)" \
            "$(distro_pkg_manager) in grpcurl (or prebuilt: curl -sSL https://github.com/fullstorydev/grpcurl/releases/download/v1.9.3/grpcurl_1.9.3_linux_x86_64.tar.gz | sudo tar -xz -C /usr/local/bin grpcurl)"
    fi
}

check_ports() {
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${COCO_AS##*:}$"; then
        record "PASS" "CoCo-AS listening on port ${COCO_AS##*:}"
    else
        record "WARN" "CoCo-AS port ${COCO_AS##*:} not listening" "Start grpc-as.service (setup-trustee)"
    fi
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${KBS_PORT}$"; then
        record "PASS" "KBS listening on port ${KBS_PORT}"
    else
        record "WARN" "KBS port ${KBS_PORT} not listening" "Start kbs.service (setup-trustee)"
    fi
}

check_kds_net() {
    if [[ "$COLLATERAL_MODE" == "offline" ]]; then
        if [[ -s "$SNP_ARK_CERT" && -s "$SNP_VCEK_CERT" ]]; then
            record "PASS" "Offline collateral store populated (${SNP_CERT_DIR})"
        else
            record "FAIL" "Offline collateral mode but cert store is empty" \
                "Import the ARK/ASK/VCEK chain: snphost import (see --collateral offline)"
        fi
        return
    fi
    local url
    url=$(kds_url)
    if probe_kds_url "$url"; then
        record "PASS" "Network reach to AMD KDS (${COLLATERAL_MODE}): ${url}"
    else
        record "WARN" "Cannot reach AMD KDS (${COLLATERAL_MODE}): ${url}" \
            "KDS: allow outbound HTTPS; or use --collateral offline with a local cert store"
    fi
}

cmd_check_platform() {
    log "=== Checking SEV-SNP platform validity against AMD KDS ==="
    step "Fetch the platform certificate chain and verify TCB status on AMD KDS" \
        "Uses snphost to fetch the ARK/ASK/VCEK chain from KDS and verify the chain + TCB OIDs."
    require_cmd snphost
    local url
    url=$(kds_url)
    if [[ -z "$url" ]]; then
        die "check-platform requires a KDS endpoint (--collateral kds, --kds-url <URL>)."
    fi
    log "Fetching platform certificate chain from KDS: ${url}"
    local rc=0
    run snphost fetch --kds-url "$url" || rc=$?
    if ((rc != 0)); then
        trap - ERR
        return $rc
    fi
    log "Verifying certificate chain (ARK -> ASK -> VCEK) and TCB OIDs"
    rc=0
    run snphost verify certs || rc=$?
    if ((rc != 0)); then
        trap - ERR
        return $rc
    fi
    # Turin+ platforms also carry a VLEK hashstick; verify it when present.
    if snphost verify vlek-hashstick >/dev/null 2>&1; then
        log "VLEK hashstick verified (Turin+ platform)"
    fi
    log "Platform certificate chain and TCB status verified on AMD KDS."
    return 0
}

cmd_check() {
    log "=== SEV-SNP host capability check ==="
    step "Probe host for SEV-SNP readiness (read-only, no changes made)" \
        "Checks CPU/BIOS SEV-SNP, KVM, boot params (kvm_amd sev_snp, mem_encrypt, IOMMU), libvirt, QEMU, guestfs-tools, /dev/sev, snphost, Trustee services, ports, KDS reachability."
    CHECK_RESULTS=()

    check_cpu_snp
    check_kvm
    check_boot_params
    check_libvirt
    check_qemu
    check_virt_customize
    check_qemu_snp
    check_ovmf_snp
    check_host_snp
    check_snp_pkgs
    check_snphost
    check_trustee
    check_ports
    check_kds_net
    if ((CHECK_PLATFORM)); then
        cmd_check_platform || warn "Platform validity check reported a problem (see above)."
    fi

    local fails=0
    print_results
    fails=$RESULT_FAILS

    if ((fails > 0)); then
        warn "${fails} check(s) FAILED. See hints above."
        trap - ERR
        return 1
    fi
    log "All checks passed (warnings, if any, are non-fatal)."
    return 0
}

# =============================================================================
# 4b. CONFIG VERIFICATION (deep post-setup validation)
# =============================================================================
#
# 'verify' double-checks that everything written/started by the setup steps is
# actually correct and consistent: config files exist, parse, and point at the
# same endpoints; services run; ports listen; libraries resolve; the VM domain
# really has SEV-SNP launchSecurity. Read-only, safe to run repeatedly.

# Check a config file exists, then optionally validate JSON syntax.
verify_conf_file() {
    local label="$1" path="$2" kind="${3:-text}"
    if [[ ! -f "$path" ]]; then
        record "FAIL" "${label} missing: ${path}" "Run the matching setup-* command"
        return
    fi
    if [[ "$kind" == "json" ]]; then
        local rc=0
        json_valid "$path" || rc=$?
        case $rc in
        0) record "PASS" "${label} present and valid JSON: ${path}" ;;
        1) record "FAIL" "${label} is INVALID JSON: ${path}" "Re-run setup-* or fix by hand" ;;
        2) record "WARN" "${label} present (JSON not validated: install jq or python3): ${path}" ;;
        *) record "FAIL" "${label} is INVALID JSON: ${path}" "Re-run setup-* or fix by hand" ;;
        esac
    else
        record "PASS" "${label} present: ${path}"
    fi
}

# Confirm a config file contains an expected substring.
verify_conf_contains() {
    local label="$1" path="$2" needle="$3" hint="${4:-}"
    if [[ -f "$path" ]] && grep -qF "$needle" "$path"; then
        record "PASS" "${label}: found '${needle}'"
    else
        record "FAIL" "${label}: '${needle}' not found in ${path}" "$hint"
    fi
}

verify_service() {
    local svc="$1"
    if ! systemctl cat "$svc" >/dev/null 2>&1; then
        record "FAIL" "${svc} not installed" "Run the matching setup-* command"
        return
    fi
    local state
    state=$(systemctl is-active "$svc" 2>/dev/null || true)
    state="${state:-inactive}"
    if [[ "$state" == "active" ]]; then
        record "PASS" "${svc} is active"
    else
        record "FAIL" "${svc} is ${state}" "journalctl -u ${svc} -n 50"
    fi
}

verify_port() {
    local label="$1" port="$2" hint="$3"
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
        record "PASS" "${label} listening on port ${port}"
    else
        record "FAIL" "${label} port ${port} not listening" "$hint"
    fi
}

# Confirm the KBS points at the configured CoCo-AS address.
verify_kbs_as_addr() {
    verify_conf_contains "KBS -> CoCo-AS addr" "$KBS_CONF" "http://${COCO_AS}" \
        "kbs.json as_addr must match --coco-as (${COCO_AS})"
}

verify_grpc_as_libs() {
    local grpc_as_bin
    grpc_as_bin=$(distro_grpc_as_bin)
    if [[ ! -f "$grpc_as_bin" ]]; then
        record "WARN" "grpc-as binary not found: ${grpc_as_bin}" "setup-trustee"
        return
    fi
    local missing
    missing=$(ldd "$grpc_as_bin" 2>/dev/null | grep 'not found' || true)
    if [[ -z "$missing" ]]; then
        record "PASS" "grpc-as dynamic libraries all resolve"
    else
        record "FAIL" "grpc-as has unresolved libraries" \
            "$(echo "$missing" | tr '\n' ' ')"
    fi
}

# Confirm the VM domain really has SEV-SNP launchSecurity + a pflash loader.
verify_vm_snp() {
    if ! command -v virsh >/dev/null 2>&1; then
        record "WARN" "virsh not available; skipping VM SNP checks" ""
        return
    fi
    if ! virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
        record "WARN" "VM '${VM_NAME}' not defined; skipping VM SNP checks" "setup-vm"
        return
    fi
    local xml
    xml=$(virsh dumpxml "$VM_NAME" 2>/dev/null || true)
    if grep -q "launchSecurity type='sev-snp'" <<<"$xml"; then
        record "PASS" "VM '${VM_NAME}' has launchSecurity type='sev-snp'"
    else
        record "FAIL" "VM '${VM_NAME}' has NO SEV-SNP launchSecurity" \
            "Re-create with setup-vm (guest will not be a real SNP VM)"
    fi
    local loader_type
    loader_type=$(grep -oP "<loader[^>]*type='\K[^']+" <<<"$xml" 2>/dev/null || true)
    if [[ "$loader_type" == "pflash" ]]; then
        record "PASS" "VM '${VM_NAME}' has pflash loader (SNP OVMF)"
    else
        record "FAIL" "VM '${VM_NAME}' loader type: '${loader_type:-none}' (expected 'pflash')" \
            "SNP OVMF must be a pflash loader with NVRAM (unlike TDX's ROM loader)"
    fi
    if grep -q "<vsock" <<<"$xml"; then
        record "PASS" "VM '${VM_NAME}' has a vsock device"
    else
        record "WARN" "VM '${VM_NAME}' has no vsock device (not required for SNP attestation)" ""
    fi
}

cmd_verify() {
    log "=== Verifying attestation configuration ==="
    step "Double-check every config written by the setup steps is correct" \
        "Validates config files (existence + JSON syntax), endpoint consistency, running services, listening ports, grpc-as libraries, and VM SEV-SNP/pflash. Read-only."
    CHECK_RESULTS=()

    # --- Config files exist and parse ---
    verify_conf_file "CoCo-AS config" "$GRPC_AS_CONF" json
    verify_conf_file "RVPS config" "$RVPS_CONF" json
    verify_conf_file "KBS config" "$KBS_CONF" text

    # --- Config content is consistent ---
    verify_conf_contains "CoCo-AS SNP verifier" "$GRPC_AS_CONF" '"snp_verifier"' \
        "CoCo-AS must use the snp_verifier for SEV-SNP reports"
    verify_kbs_as_addr

    # --- Secret delivery (KBS) plumbing ---
    if [[ -f "$KBS_ADMIN_KEY" && -f "$KBS_ADMIN_PUB" ]]; then
        record "PASS" "KBS admin keypair present: ${KBS_ADMIN_KEY}"
    else
        record "FAIL" "KBS admin keypair missing" "setup-trustee generates it (needed for secret-set)"
    fi
    if [[ -f "$KBS_CONF" ]] && grep -qF '"authorization_mode": "InsecureAllowAll"' "$KBS_CONF"; then
        record "PASS" "KBS admin auth: InsecureAllowAll (LAB setting, no admin key required)"
    else
        verify_conf_contains "KBS admin key wired" "$KBS_CONF" "$KBS_ADMIN_PUB" \
            "kbs.json [admin] auth_public_key must point at ${KBS_ADMIN_PUB}"
    fi
    if [[ -f "$KBS_POLICY" ]]; then
        record "PASS" "KBS resource policy present: ${KBS_POLICY}"
    else
        record "WARN" "KBS resource policy file missing" "setup-trustee writes ${KBS_POLICY}"
    fi
    # --- Guest kbs-client has the SNP attester (only when a guest is reachable) ---
    if [[ -n "$GUEST_IP" ]] && ssh_guest "true" 2>/dev/null; then
        local pkg_client
        pkg_client=$(guest_distro_kbs_client_bin)
        if ssh_guest "test -x ${pkg_client}" 2>/dev/null && kbs_client_supports_snp_guest "$pkg_client"; then
            record "PASS" "Guest package kbs-client has SNP attester: ${pkg_client}"
        elif ssh_guest "test -x ${pkg_client}" 2>/dev/null; then
            record "WARN" "Guest kbs-client lacks SNP attester (package too old)" \
                "Upgrade the guest 'trustee' package and re-run setup-guest"
        else
            record "WARN" "No kbs-client found in guest" \
                "Run 'setup-guest' or install the 'trustee' package"
        fi
    fi

    # --- Host SEV-SNP plumbing (guest-only nodes like /dev/sev-guest are NOT here) ---
    check_host_snp
    check_ovmf_snp

    # --- Certificate store ---
    if [[ "$COLLATERAL_MODE" == "offline" ]]; then
        if [[ -s "$SNP_ARK_CERT" && -s "$SNP_VCEK_CERT" ]]; then
            record "PASS" "Offline cert store populated (ARK + VCEK)"
        else
            record "FAIL" "Offline cert store incomplete" \
                "Import the ARK/ASK/VCEK chain (snphost import)"
        fi
    fi

    # --- Services running ---
    verify_service grpc-as.service
    verify_service kbs.service
    verify_service rvps.service

    # --- Ports listening ---
    verify_port "CoCo-AS" "${COCO_AS##*:}" "Start grpc-as.service (setup-trustee)"
    verify_port "KBS" "${KBS_PORT}" "Start kbs.service (setup-trustee)"

    # --- Libraries resolve ---
    verify_grpc_as_libs

    # --- VM really is an SNP VM ---
    verify_vm_snp

    # --- Collateral source reachable ---
    if [[ "$COLLATERAL_MODE" == "offline" ]]; then
        record "PASS" "Collateral source: offline cert store (${SNP_CERT_DIR})"
    else
        local coll_url
        coll_url=$(kds_url)
        if probe_kds_url "$coll_url"; then
            record "PASS" "Collateral source reachable (${COLLATERAL_MODE}): ${coll_url}"
        else
            record "WARN" "Collateral source not reachable (${COLLATERAL_MODE}): ${coll_url}" \
                "KDS: check outbound HTTPS; or use --collateral offline"
        fi
    fi

    local fails=0
    print_results
    fails=$RESULT_FAILS

    if ((fails > 0)); then
        warn "${fails} configuration check(s) FAILED. Fix the items above, then re-run 'verify'."
        trap - ERR
        return 1
    fi
    log "Attestation configuration verified: all critical checks passed."
    return 0
}
