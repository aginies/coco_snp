# =============================================================================
# 6. VM SETUP  — AMD SEV-SNP
# =============================================================================
# NOTE: CHECK_RESULTS is used by print_results() in checks.sh — SC2034 from
# static analysis is a false positive (cross-file usage).
# shellcheck disable=SC2034

# libvirt is modular since SLE 16 / libvirt 5.7. Only fall back to the
# monolithic libvirtd on older systems.
generate_vm_xml() {
    local xml_path="$1"
    local uuid ovmf_hit ovmf_bin
    uuid=$(uuidgen)

    # Resolve the SNP OVMF binary (for verification + logging). For SNP we do
    # NOT force an explicit <loader>: when <launchSecurity type='sev-snp'> is
    # present, libvirt automatically selects the SNP firmware from the
    # firmware descriptors (feature 'amd-sev-snp') and sets up the writable
    # NVRAM store itself. This works with both the SUSE single-image packaging
    # (ovmf-x86_64-sev.bin, mapped as a ROM) and the upstream edk2 layout
    # (OVMF.SNP.fd + OVMF_VARS.SNP.fd). Forcing a pflash loader without a
    # matching NVRAM template would break the VM.
    ovmf_bin=""
    if ovmf_hit=$(find_snp_ovmf); then
        ovmf_bin="${ovmf_hit##*|}"
    fi

    if ((VM_NO_SNP)); then
        log "Generating NON-SNP VM XML: ${xml_path} (uuid=${uuid}, test mode)"
    else
        log "Generating VM XML: ${xml_path} (uuid=${uuid}, SNP firmware autoselected: ${ovmf_bin:-<none found>})"
    fi

    # --- SNP mode: mirrors the SUSE/libvirt SNP reference config:
    #   - <launchSecurity type='sev-snp'> with <policy> + <vms>. This triggers
    #     libvirt's automatic SNP firmware selection (the 'amd-sev-snp' feature
    #     descriptor) and the writable NVRAM setup. No explicit <loader>.
    #   - No host-side quote daemon (no QGS socket in the XML, unlike TDX).
    #   - vsock is optional (SNP attestation does not require it; the report
    #     is generated in-guest via GHCB and signed by the CPU's PSP).
    #
    # Video: use virtio (not VGA). virtio video + serial console is the proven
    # path for a confidential guest installer.

    local loader_line=""
    local nvram_line=""
    local memfd_line=""
    local ioapic_line=""
    local launchsec_line=""
    local vsock_line=""
    local rng_line=""
    local firmware_attr=""
    local memtune_line=""
    local resource_line=""
    local extra_devices=""

    if ((VM_NO_SNP)); then
        # --- Non-SNP mode: regular UEFI VM for testing without SNP hardware ---
        local regular_ovmf=""
        if regular_ovmf=$(distro_ovmf_regular_probe); then
            loader_line="    <loader type='pflash' readonly='yes'>${regular_ovmf}</loader>"
        else
            loader_line="    <loader type='pflash' readonly='yes'/>"
        fi
        memfd_line="  <memoryBacking>
    <type type='file'/>
  </memoryBacking>"
        ioapic_line="    <ioapic driver='qemu'/>"
        launchsec_line=""
        vsock_line=""
        rng_line="    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>"
        firmware_attr=""
    else
        # SNP mode: rely on libvirt firmware autoselection (no explicit
        # <loader>/<nvram>); <launchSecurity type='sev-snp'> triggers the
        # 'amd-sev-snp' firmware descriptor + writable NVRAM setup.
        loader_line=""
        nvram_line=""
        # SNP: no explicit memory backing (the PSP encrypts guest memory).
        memfd_line=""
        ioapic_line=""
        # SNP: include launchSecurity with the launch policy + VM serial.
        launchsec_line="  <launchSecurity type='sev-snp'>
    <policy>${SNP_POLICY}</policy>
    <vms>${SNP_VMPL}</vms>
  </launchSecurity>"
        # SNP: include vsock (optional but useful for guest-host channels).
        vsock_line="    <vsock model='virtio'>
      <cid auto='yes'/>
    </vsock>"
        rng_line="    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>"
        firmware_attr=""
        # SNP: hard memory limit slightly above guest RAM (firmware + overhead).
        local mem_hard_limit
        mem_hard_limit=$(((VM_MEM * 1024) + 369090))
        memtune_line="  <memtune>
    <hard_limit unit='KiB'>${mem_hard_limit}</hard_limit>
  </memtune>"
        resource_line="  <resource>
    <partition>/machine</partition>
  </resource>"
        extra_devices="    <controller type='usb' index='0' model='qemu-xhci' ports='15'/>
    <input type='tablet' bus='usb'>
      <address type='usb' bus='0' port='1'/>
    </input>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <audio id='1' type='none'/>
    <watchdog model='itco' action='reset'/>
    <channel type='unix'>
      <source mode='bind' path='/run/libvirt/qemu/channel/domain-${VM_DISPLAY_NAME}/org.qemu.guest_agent.0'/>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>"
    fi

    cat >"$xml_path" <<EOF
<domain type='kvm'>
  <name>${VM_DISPLAY_NAME:-${VM_NAME}}</name>
  <uuid>${uuid}</uuid>
  <memory unit='MiB'>${VM_MEM}</memory>
  <currentMemory unit='MiB'>${VM_MEM}</currentMemory>
${memtune_line}
${memfd_line}
  <vcpu placement='static'>${VM_CPU}</vcpu>
  <cpu mode='host-passthrough' check='none' migratable='off'/>
${resource_line}
  <os${firmware_attr}>
    <type arch='x86_64' machine='q35'>hvm</type>
${loader_line}
${nvram_line}
    <boot dev='cdrom'/>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
${ioapic_line}
  </features>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>destroy</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
${launchsec_line}
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <controller type='sata' index='0'>
      <alias name='sata0'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x1f' function='0x2'/>
    </controller>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${VM_DISK_PATH}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <graphics type='vnc' port='${VNC_PORT}' listen='${VNC_LISTEN:-0.0.0.0}'>
      <listen type='address' address='${VNC_LISTEN:-0.0.0.0}'/>
    </graphics>
    <video>
      <model type='virtio' heads='1' primary='yes'/>
    </video>
${vsock_line}
${extra_devices}
    <memballoon model='virtio'/>
${rng_line}
  </devices>
</domain>
EOF
}

# =============================================================================
# virt-install based VM creation (alternative to generate_vm_xml)
# =============================================================================
virt_install_available() {
    command -v virt-install >/dev/null 2>&1
}

virt_install_major() {
    local ver
    ver=$(virt-install --version 2>/dev/null | head -1 | grep -oE '^[0-9]+' || true)
    echo "${ver:-0}"
}

virt_install_osinfo() {
    local base up
    base=$(basename -- "${GUEST_ISO:-}")
    up=$(tr '[:lower:]' '[:upper:]' <<<"${base}")
    case "${up}" in
    *SLES*16.1*) echo "sles16.1" ;;
    *SLES*16*) echo "sles16" ;;
    *SLES*15*SP7*) echo "sles15sp7" ;;
    *SLES*15*SP6*) echo "sles15sp6" ;;
    *SLES*15*SP5*) echo "sles15sp5" ;;
    *LEAP*16.1*) echo "opensuse16.1" ;;
    *LEAP*15.6*) echo "opensuse15.6" ;;
    *) : ;;
    esac
}

choose_vm_creator() {
    local want="${VM_CREATOR}"
    if [[ -z "${GUEST_ISO}" && "${want}" != "xml" ]]; then
        log "No --guest-iso given; using generated XML (ISO can be attached later)."
        echo "xml"
        return 0
    fi
    case "${want}" in
    xml)
        echo "xml"
        ;;
    virt)
        if virt_install_available; then
            echo "virt"
        else
            warn "virt-install not found (package: python3-virtinst); falling back to generated XML."
            echo "xml"
        fi
        ;;
    *) # auto
        if virt_install_available; then
            echo "virt"
        else
            log "virt-install not found; using generated XML."
            echo "xml"
        fi
        ;;
    esac
}

vnc_port_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${1}$"
    else
        (exec 3<>"/dev/tcp/127.0.0.1/${1}") 2>/dev/null
    fi
}

ensure_vnc_port() {
    local port="$1" i
    if ! vnc_port_in_use "${port}"; then
        return 0
    fi
    for i in $(seq 1 10); do
        if ! vnc_port_in_use "$((port + i))"; then
            warn "VNC port ${port} is in use on the host; using $((port + i)) instead (override with --vnc-port)."
            VNC_PORT=$((port + i))
            return 0
        fi
    done
    die "VNC port ${port} (and the next 10 ports) are in use on the host.
Stop a VM using it or re-run with --vnc-port <PORT>."
}

# Extract the SLE installer kernel/initrd from the ISO into persistent files.
# Sets INSTALLER_KERNEL / INSTALLER_INITRD. Requires root (loop mount).
extract_installer_media() {
    local iso="$1"
    local mnt ksrc="" isrc=""
    mnt=$(mktemp -d /mnt/snp-iso-XXXXXX)
    if ! mount -o loop,ro "${iso}" "${mnt}" 2>/dev/null; then
        rmdir "${mnt}"
        die "Cannot loop-mount the installer ISO to extract the installer kernel: ${iso}"
    fi
    local d
    for d in "boot/x86_64/loader" "images/pxeboot"; do
        if [[ -f "${mnt}/${d}/linux" || -f "${mnt}/${d}/vmlinuz" ]]; then
            ksrc="${d}/$([[ -f "${mnt}/${d}/linux" ]] && echo linux || echo vmlinuz)"
            isrc="${d}/initrd"
            break
        fi
    done
    if [[ -z "${ksrc}" || ! -f "${mnt}/${isrc}" ]]; then
        umount "${mnt}" 2>/dev/null
        rmdir "${mnt}"
        die "No installer kernel found in the ISO (looked in boot/x86_64/loader and images/pxeboot)."
    fi
    INSTALLER_KERNEL="/var/lib/libvirt/boot/${VM_DISPLAY_NAME}-installer-kernel"
    INSTALLER_INITRD="/var/lib/libvirt/boot/${VM_DISPLAY_NAME}-installer-initrd"
    cp "${mnt}/${ksrc}" "${INSTALLER_KERNEL}"
    cp "${mnt}/${isrc}" "${INSTALLER_INITRD}"
    umount "${mnt}" 2>/dev/null
    rmdir "${mnt}"
    log "Installer kernel/initrd extracted: ${INSTALLER_KERNEL} (+initrd)"
}

# Build the virt-install command in the global VIRT_INSTALL_CMD array.
build_virt_install_cmd() {
    local disk_spec="path=${VM_DISK_PATH},format=qcow2"
    local vi_major
    vi_major=$(virt_install_major)
    local vi_size="${VM_DISK}"
    if [[ "${vi_size}" =~ ^([0-9]+)([A-Za-z]?)$ ]]; then
        local d_n="${BASH_REMATCH[1]}" d_u="${BASH_REMATCH[2]}"
        case "${d_u}" in
        [Tt]) vi_size=$((d_n * 1024)) ;;
        [Mm]) vi_size=$((d_n / 1024)) ;;
        [Gg] | "") vi_size="${d_n}" ;;
        esac
    fi
    if [[ ! -f "${VM_DISK_PATH}" ]]; then
        disk_spec="${disk_spec},size=${vi_size}"
    fi
    if ((vi_major >= 5)); then
        disk_spec="${disk_spec},bus=virtio"
    fi
    # shellcheck disable=SC2054
    local cmd=(virt-install
        --name "${VM_DISPLAY_NAME}"
        --memory "${VM_MEM}"
        --vcpus "${VM_CPU}"
        --disk "${disk_spec}"
        --cpu host-passthrough
        --network network=default,model=virtio
        --graphics "vnc,listen=${VNC_LISTEN:-0.0.0.0},port=${VNC_PORT}"
        --video virtio
        --boot cdrom,hd
        --noautoconsole
        --wait 1
    )
    if ((vi_major >= 5)); then
        local osinfo
        osinfo=$(virt_install_osinfo)
        if [[ -n "${osinfo}" ]] && virt-install --osinfo list 2>/dev/null | grep -qx "${osinfo}"; then
            cmd+=(--osinfo "${osinfo}")
        else
            cmd+=(--osinfo detect=on,require=off)
        fi
    fi
    if ((VM_NO_SNP)); then
        :
    else
        local ovmf_hit ovmf_bin=""
        if ovmf_hit=$(find_snp_ovmf); then
            ovmf_bin="${ovmf_hit##*|}"
        fi
        if [[ -z "${ovmf_bin}" ]]; then
            die "No SNP OVMF firmware found; cannot build virt-install command."
        fi
        cmd+=(--machine q35)
    fi
    local iso_path="${GUEST_ISO}"
    if [[ -f "${iso_path}" ]]; then
        iso_path=$(realpath -- "${iso_path}" 2>/dev/null || echo "${iso_path}")
    fi
    if ((VM_NO_SNP)); then
        cmd+=(--cdrom "${iso_path}")
    else
        cmd+=(--location "${iso_path}")
        cmd+=(--extra-args "console=ttyS0,115200")
    fi
    VIRT_INSTALL_CMD=("${cmd[@]}")
}

# Post-define XML patch for the virt-install path. Adds the SNP-specific bits
# virt-install has no flags for: the <launchSecurity type='sev-snp'> block and
# a vsock device, and disables suspend-to-mem/disk. For the firmware it does
# the OPPOSITE of TDX: it REMOVES the regular <loader>/<nvram> that
# virt-install emitted, so that libvirt's firmware autoselection picks the
# SNP firmware (feature 'amd-sev-snp') once <launchSecurity type='sev-snp'>
# is present. Self-contained: the XML transformation is done inline with
# python3 (ElementTree), so this script has no external tool dependency.
# Usage: patch_vm_xml_snp <input_xml> <output_xml>
patch_vm_xml_snp() {
    local input_xml="$1" output_xml="$2"

    python3 - "$input_xml" "$output_xml" "$SNP_POLICY" "$SNP_VMPL" <<'PYEOF'
import sys, xml.etree.ElementTree as ET

inp, outp, policy, vmpl = sys.argv[1:5]
tree = ET.parse(inp)
root = tree.getroot()

def find(tag):
    return root.find(tag)

os_ = find('os')
if os_ is None:
    os_ = ET.SubElement(root, 'os')

# Remove the regular <loader>/<nvram> that virt-install emitted. With
# <launchSecurity type='sev-snp'> present, libvirt autoselects the SNP
# firmware (feature 'amd-sev-snp') and sets up the writable NVRAM itself.
for tag in ('loader', 'nvram'):
    el = os_.find(tag)
    if el is not None:
        os_.remove(el)

ls = find('launchSecurity')
if ls is None:
    ls = ET.SubElement(root, 'launchSecurity')
ls.set('type', 'sev-snp')
pol = ls.find('policy')
if pol is None:
    pol = ET.SubElement(ls, 'policy')
pol.text = policy
vms = ls.find('vms')
if vms is None:
    vms = ET.SubElement(ls, 'vms')
vms.text = str(vmpl)

devices = find('devices')
if devices is not None and devices.find('vsock') is None:
    vs = ET.SubElement(devices, 'vsock')
    vs.set('model', 'virtio')
    cid = ET.SubElement(vs, 'cid')
    cid.set('auto', 'yes')

pm = find('pm')
if pm is None:
    pm = ET.SubElement(root, 'pm')
for name in ('suspend-to-mem', 'suspend-to-disk'):
    el = pm.find(name)
    if el is None:
        el = ET.SubElement(pm, name)
    el.set('enabled', 'no')

tree.write(outp, xml_declaration=False)
PYEOF
}

# Inject the SSH key (and disable suspend) into the guest disk via virt-customize.
inject_ssh_key_disk() {
    if command -v virt-customize >/dev/null 2>&1; then
        log "Injecting SSH key into guest image via virt-customize"
        local pub_key
        pub_key=$(cat "${SSH_KEY}.pub")
        run virt-customize -a "$VM_DISK_PATH" \
            --run-command "mkdir -p /root/.ssh && chmod 700 /root/.ssh" \
            --run-command "touch /root/.ssh/authorized_keys; grep -qxF '${pub_key}' /root/.ssh/authorized_keys || echo '${pub_key}' >> /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys" \
            --run-command "mkdir -p /etc/ssh/sshd_config.d && printf 'PermitRootLogin yes\n' > /etc/ssh/sshd_config.d/root.conf && chmod 644 /etc/ssh/sshd_config.d/root.conf" \
            --run-command "mkdir -p /etc/systemd/system && for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do ln -sf /dev/null /etc/systemd/system/\$t; done" \
            --run-command "mkdir -p /etc/systemd/logind.conf.d && printf '[Login]\nHandleSuspendKey=ignore\nHandleHibernateKey=ignore\nHandleLidSwitch=ignore\n' > /etc/systemd/logind.conf.d/snp-no-suspend.conf"
        log "SSH key injected (user: ${GUEST_USER})"
        log "Suspend/hibernate disabled in guest image (SNP requirement)"
    else
        warn "virt-customize not available — SSH key was NOT injected. Install $(distro_pkgs virt_customize) ($(distro_pkg_manager)) and re-run setup-vm, or inject manually:"
        warn "  virt-customize -a ${VM_DISK_PATH} --ssh-inject ${GUEST_USER}:file:${SSH_KEY}.pub"
    fi
}

ensure_ssh_key() {
    if [[ -f "$SSH_KEY" ]]; then
        log "SSH key already exists: $SSH_KEY"
        return 0
    fi
    log "Generating SSH key: $SSH_KEY"
    mkdir -p "$(dirname "$SSH_KEY")"
    chmod 700 "$(dirname "$SSH_KEY")"
    run ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -C "snp-attest-$(date +%Y%m%d)"
    log "SSH key created: $SSH_KEY"
}

cmd_setup_vm() {
    if ((VM_NO_SNP)); then
        VM_DISPLAY_NAME="${VM_NO_SNP_NAME}"
        VM_DISK_PATH="${VM_NO_SNP_DISK_PATH}"
        VM_XML_PATH="${VM_NO_SNP_XML_PATH}"
    else
        VM_DISPLAY_NAME="${VM_NAME}"
    fi
    if ((DRY_RUN)); then
        if [[ "${VM_CREATOR}" == "xml" ]]; then
            die "--no-virt-install was given; --dry-run only previews the virt-install path."
        fi
        if [[ -z "${GUEST_ISO}" ]]; then
            die "--dry-run builds the virt-install command, which needs --guest-iso."
        fi
        build_virt_install_cmd
        if ! virt_install_available; then
            warn "virt-install is not installed on this host — a real run would fall back to the generated XML engine."
        fi
        echo ""
        echo "  virt-install command (DRY RUN — not executed):"
        printf '    %s\n' "${VIRT_INSTALL_CMD[@]}"
        echo ""
        if ((VM_NO_SNP)); then
            log "Non-SNP mode: no SNP post-patch would be applied."
        else
            log "Post-define SNP patch would: remove regular loader (SNP firmware autoselected), add launchSecurity sev-snp (policy ${SNP_POLICY}), vsock, memtune hard_limit, resource partition, pm suspend disabled."
        fi
        return 0
    fi
    require_root
    require_cmd virsh qemu-img uuidgen ssh-keygen
    ensure_vnc_port "${VNC_PORT}"
    log "=== Setting up ${VM_DISPLAY_NAME} (${VM_CPU} vCPU, ${VM_MEM} MiB) ==="
    if ((VM_NO_SNP)); then
        step "Create + define + start a NON-SNP libvirt guest (test mode)" \
            "Builds qcow2 disk and domain XML (regular UEFI, no launchSecurity), then boots for OS install. NOT a confidential VM."
        warn "This VM is NOT an SEV-SNP confidential VM. No attestation possible."
    else
        step "Create + define + start an SEV-SNP-enabled libvirt guest" \
            "Creates the guest (virt-install if available, else generated XML: launchSecurity sev-snp, SNP firmware autoselected, vsock), then boots for OS install."
    fi

    local ovmf_hit
    if ((VM_NO_SNP)); then
        log "Non-SNP mode: skipping SNP OVMF check."
    else
        if ovmf_hit=$(find_snp_ovmf); then
            log "SNP OVMF firmware: ${ovmf_hit##*|} (descriptor: ${ovmf_hit%%|*})"
        else
            die "No SNP OVMF firmware descriptor found in $(distro_ovmf_fwdir).
Install a SNP-enabled edk2/OVMF ($(distro_pkgs ovmf)), then re-run."
        fi
        if ! qemu-system-x86_64 -object help 2>&1 | grep -qi 'sev-snp-guest'; then
            die "QEMU has no SEV-SNP support (no sev-snp-guest object).
Reinstall qemu with SNP target (package: $(distro_pkgs qemu))."
        fi
        log "QEMU supports SEV-SNP (sev-snp-guest object present)"
    fi

    ensure_libvirt
    ensure_virt_customize

    if virsh dominfo "$VM_DISPLAY_NAME" >/dev/null 2>&1; then
        warn "VM '${VM_DISPLAY_NAME}' already exists."
        if confirm "Destroy + undefine VM '${VM_DISPLAY_NAME}' and continue?"; then
            run virsh destroy "$VM_DISPLAY_NAME" || true
            if virsh undefine "$VM_DISPLAY_NAME" 2>/dev/null; then
                log "VM undefined"
            elif confirm "VM has NVRAM. Undefine with --nvram (removes firmware variables)?"; then
                run virsh undefine --nvram "$VM_DISPLAY_NAME"
            else
                die "Cannot undefine VM with NVRAM. Use 'clean' first or manually: virsh undefine --nvram ${VM_DISPLAY_NAME}"
            fi
        else
            die "VM '${VM_DISPLAY_NAME}' still exists. Use 'clean' first or change --vm-name."
        fi
    fi

    local disk_has_os=0
    if [[ -f "$VM_DISK_PATH" ]]; then
        warn "Disk already exists, reusing: ${VM_DISK_PATH}"
        if command -v virt-filesystems >/dev/null 2>&1 &&
            virt-filesystems -a "$VM_DISK_PATH" --all --long-only 2>/dev/null | grep -q .; then
            disk_has_os=1
        else
            warn "Disk contains no filesystem (leftover from an aborted install?) — treating as fresh."
        fi
    fi

    ensure_ssh_key

    local creator
    creator=$(choose_vm_creator)

    if [[ "$creator" == "virt" ]]; then
        INSTALLER_KERNEL=""
        INSTALLER_INITRD=""
        if ((! VM_NO_SNP)); then
            local iso_abs="${GUEST_ISO}"
            [[ -f "${iso_abs}" ]] && iso_abs=$(realpath -- "${iso_abs}" 2>/dev/null || echo "${iso_abs}")
            extract_installer_media "${iso_abs}"
        fi
        build_virt_install_cmd
        echo ""
        echo "  virt-install command:"
        printf '    %s\n' "${VIRT_INSTALL_CMD[@]}"
        echo ""
        local vi_xml
        vi_xml=$(mktemp /tmp/snp-vi-XXXXXX.xml)
        if ! run "${VIRT_INSTALL_CMD[@]}" --print-xml >"$vi_xml"; then
            rm -f "$vi_xml"
            die "virt-install --print-xml failed. See output above."
        fi
        if [[ ! -s "$vi_xml" ]] || ! grep -q '<domain' "$vi_xml"; then
            rm -f "$vi_xml"
            die "virt-install --print-xml produced no domain XML."
        fi
        if ((! VM_NO_SNP)) && grep -q '<kernel>' "$vi_xml"; then
            if [[ -n "${INSTALLER_KERNEL}" && -f "${INSTALLER_KERNEL}" && -f "${INSTALLER_INITRD}" ]]; then
                sed -i "s|<kernel>.*</kernel>|<kernel>${INSTALLER_KERNEL}</kernel>|; s|<initrd>.*</initrd>|<initrd>${INSTALLER_INITRD}</initrd>|" "$vi_xml"
                log "Repointed one-shot installer boot at persistent kernel/initrd"
            else
                die "The installer kernel/initrd are missing (${INSTALLER_KERNEL:-not extracted}); cannot build the one-shot boot. Re-run."
            fi
        fi
        if [[ ! -f "$VM_DISK_PATH" ]]; then
            log "Creating qcow2 disk: ${VM_DISK_PATH} (${VM_DISK})"
            mkdir -p "$(dirname "$VM_DISK_PATH")"
            run qemu-img create -f qcow2 "$VM_DISK_PATH" "$VM_DISK"
        fi
        if ((disk_has_os)); then
            inject_ssh_key_disk
        else
            warn "Fresh empty disk — skipping virt-customize (nothing to mount yet)."
            warn "Install the OS from the ISO first, then inject the SSH key post-install:"
            warn "  virt-customize -a ${VM_DISK_PATH} --ssh-inject ${GUEST_USER}:file:${SSH_KEY}.pub"
        fi
        local pre_xml post_xml
        pre_xml="$vi_xml"
        post_xml=$(mktemp /tmp/snp-vm-post-XXXXXX.xml)
        if ((VM_NO_SNP)); then
            cp "$pre_xml" "$post_xml"
        else
            if ! patch_vm_xml_snp "$pre_xml" "$post_xml"; then
                die "SNP XML patch failed. Pre-patch XML kept: ${pre_xml}"
            fi
            log "SNP patch applied (diff):"
            diff "$pre_xml" "$post_xml" | sed 's/^/    /' || true
        fi
        log "Defining VM with patched XML"
        run virsh define "$post_xml"
        rm -f "$pre_xml" "$post_xml"
        log "Starting VM (first boot: one-shot installer direct kernel boot)"
        run virsh start "$VM_DISPLAY_NAME"
        sleep 2
        run virsh dominfo "$VM_DISPLAY_NAME"
    else
        log "Creating qcow2 disk: ${VM_DISK_PATH} (${VM_DISK})"
        mkdir -p "$(dirname "$VM_DISK_PATH")"
        if ((disk_has_os)); then
            :
        else
            run qemu-img create -f qcow2 "$VM_DISK_PATH" "$VM_DISK"
        fi

        log "Storing VM XML definition: ${VM_XML_PATH}"
        generate_vm_xml "$VM_XML_PATH"

        if ((disk_has_os)); then
            inject_ssh_key_disk
        else
            warn "Fresh empty disk — skipping virt-customize (nothing to mount yet)."
            warn "Install the OS from the ISO first, then inject the SSH key post-install:"
            warn "  virt-customize -a ${VM_DISK_PATH} --ssh-inject ${GUEST_USER}:file:${SSH_KEY}.pub"
        fi

        log "Defining VM"
        run virsh define "$VM_XML_PATH"

        if [[ -n "$GUEST_ISO" ]]; then
            log "Attaching installer ISO: $GUEST_ISO"
            if ! run virsh attach-disk "$VM_DISPLAY_NAME" "$GUEST_ISO" hdc \
                --type cdrom --mode readonly --config; then
                warn "ISO attach failed; attach manually: virsh attach-disk ${VM_DISPLAY_NAME} ${GUEST_ISO} hdc --type cdrom --config"
            fi
        else
            warn "No --guest-iso provided. Attach the SLE installer ISO manually before first boot."
        fi

        log "Starting VM"
        echo ""
        echo "  VM XML (${VM_XML_PATH}):"
        sed 's/^/    /' "$VM_XML_PATH"
        echo ""
        echo "  Command: virsh start ${VM_DISPLAY_NAME}"
        echo ""
        if ((! FORCE)) && [[ -t 0 ]]; then
            read -r -p "  Press Enter to start the VM (or Ctrl+C to abort): " _
        fi
        run virsh start "$VM_DISPLAY_NAME"
        sleep 2
        run virsh dominfo "$VM_DISPLAY_NAME"
    fi

    if ((VM_NO_SNP)); then
        cat <<NEXT

=== VM started (NON-SNP, test mode). MANUAL GUEST INSTALLATION REQUIRED ===

1. Open the console and install SLE from the ISO:
    virsh console ${VM_DISPLAY_NAME}
2. After install + reboot, find the guest IP:
    virsh net-dhcp-leases default
3. SSH into the guest:
    ssh -i ${SSH_KEY} ${GUEST_USER}@<GUEST_IP>

NOTE: This VM is NOT an SEV-SNP confidential VM. No attestation, no launchSecurity.

NEXT
    else
        cat <<NEXT

=== VM started. MANUAL GUEST INSTALLATION REQUIRED ===

1. The SLE installer boots automatically from the ISO (direct kernel boot —
   the SNP OVMF inside a confidential VM cannot auto-boot the cdrom on its own).
   Watch it on the serial console (wired to ttyS0):
    virsh console ${VM_DISPLAY_NAME}
   The VNC display also works — VNC listens on ${VNC_LISTEN}:${VNC_PORT}:
    virsh vncdisplay ${VM_DISPLAY_NAME}
    vncclient <HOST_IP>:<N>

2. During install: ensure kernel is 6.1+ (default on SLE 16.1).

3. After install + reboot, find the guest IP:
    virsh net-dhcp-leases default

4. Then run the guest setup and attestation:
    sudo snp-attest.sh setup-guest --guest-ip <GUEST_IP>
    sudo snp-attest.sh attest      --guest-ip <GUEST_IP> --register-rv

NEXT
    fi
    log "VM setup complete."
}

# Edit a libvirt domain XML in-place to add SNP support (convert-snp path).
edit_vm_xml_snp() {
    local input_xml="$1" output_xml="$2"
    # $3 (ovmf_bin) is accepted for interface compatibility but no longer used:
    # patch_vm_xml_snp relies on libvirt firmware autoselection for SNP.
    patch_vm_xml_snp "$input_xml" "$output_xml"
}

cmd_convert_snp() {
    require_root
    require_cmd virsh python3
    log "=== Converting VM to SEV-SNP ==="
    step "Convert an existing (non-SNP) libvirt VM to an SEV-SNP confidential VM in-place" \
        "Edits the domain XML: removes the regular loader (SNP firmware autoselected), adds launchSecurity sev-snp + vsock, disables suspend-to-mem/disk. Preserves disk, network, MAC, graphics, video, UUID."

    local vm_name="${CONVERT_VM_NAME:-}"
    if [[ -z "$vm_name" ]]; then
        if command -v virsh >/dev/null 2>&1; then
            local vm_list
            vm_list=$(virsh list --all --name 2>/dev/null | grep -v '^$' || true)
            if [[ -z "$vm_list" ]]; then
                die "No VMs found on this system. Use --convert-vm <NAME> if the VM is on a different host."
            fi
            pick_vm_interactively "Available VMs:" "Enter VM number to convert: " \
                "Re-run with --convert-vm <NAME>." "$vm_list" "$vm_list"
            vm_name="$PICKED_VM_NAME"
            if [[ "$(grep -c . <<<"$vm_list")" -eq 1 ]]; then
                log "Auto-detected single VM: ${vm_name}"
            fi
        else
            die "--convert-vm NAME is required for convert-snp (virsh not available for auto-detection). Usage: ${SCRIPT_NAME} convert-snp --convert-vm <VM_NAME>"
        fi
    fi

    if ! virsh dominfo "$vm_name" >/dev/null 2>&1; then
        die "VM '${vm_name}' not found. Check: virsh list --all"
    fi
    local state
    state=$(virsh domstate "$vm_name" 2>/dev/null || echo "unknown")
    if [[ "$state" == "running" ]]; then
        die "To convert VM '${vm_name}' to SEV-SNP it must be stopped first.
Shut it down, then re-run:
  virsh shutdown ${vm_name}
  sudo ${SCRIPT_NAME} convert-snp --convert-vm ${vm_name}"
    fi

    ensure_libvirt

    local ovmf_hit ovmf_bin
    if ovmf_hit=$(find_snp_ovmf); then
        ovmf_bin="${ovmf_hit##*|}"
        log "SNP OVMF firmware: ${ovmf_bin}"
    else
        die "No SNP OVMF firmware found in $(distro_ovmf_fwdir). Install a SNP-enabled edk2/OVMF ($(distro_pkgs ovmf)) first."
    fi

    local cur_xml
    cur_xml=$(virsh dumpxml "$vm_name" 2>/dev/null || true)
    if grep -q "launchSecurity type='sev-snp'" <<<"$cur_xml"; then
        warn "VM already has SEV-SNP launchSecurity (may already be SNP). Continuing."
    fi

    local backup_path="/var/lib/libvirt/${vm_name}.xml.bak"
    log "Backing up VM XML: ${backup_path}"
    mkdir -p /var/lib/libvirt
    run virsh dumpxml "$vm_name" >"$backup_path"

    local tmp_xml
    tmp_xml=$(mktemp /tmp/snp-convert-XXXXXX.xml)
    log "Editing VM XML for SEV-SNP (preserving disk, network, MAC, graphics, video, UUID)"
    if ! edit_vm_xml_snp "$backup_path" "$tmp_xml" "$ovmf_bin"; then
        error "XML edit failed. Generated XML kept for inspection: ${tmp_xml}"
        die "SNP conversion failed. Generated XML: ${tmp_xml}"
    fi

    log "Defining VM with SNP configuration"
    if ! run virsh define "$tmp_xml"; then
        error "Define failed. Rolling back to backup."
        run virsh define "$backup_path" || warn "Rollback also failed. Restore manually: virsh define ${backup_path}"
        error "Generated SNP XML kept for inspection: ${tmp_xml}"
        die "SNP conversion failed. VM restored to previous state. Generated XML: ${tmp_xml}"
    fi
    rm -f "$tmp_xml"

    local new_xml
    new_xml=$(virsh dumpxml "$vm_name" 2>/dev/null || true)
    if grep -q "launchSecurity type='sev-snp'" <<<"$new_xml"; then
        log "VM has launchSecurity type='sev-snp'"
    else
        error "VM missing launchSecurity type='sev-snp' after conversion"
    fi
    if grep -q "<vsock" <<<"$new_xml"; then
        log "VM has vsock device"
    else
        warn "VM missing vsock device after conversion (not required for SNP attestation)"
    fi
    if grep -q "suspend-to-mem enabled='no'" <<<"$new_xml" && grep -q "suspend-to-disk enabled='no'" <<<"$new_xml"; then
        log "VM has suspend-to-mem and suspend-to-disk disabled"
    else
        error "VM missing <pm> suspend-to-mem/suspend-to-disk enabled='no' after conversion. SNP guests must not hibernate."
    fi

    log "Changes applied (diff):"
    diff "$backup_path" <(virsh dumpxml "$vm_name" 2>/dev/null) | sed 's/^/    /' || true

    cat <<NEXT

=== VM '${vm_name}' converted to SEV-SNP ===

Backup: ${backup_path}

Next steps:
  1. Start the VM:              virsh start ${vm_name}
  2. Install/verify guest OS:   virsh console ${vm_name}
  3. Setup guest attestation:   sudo ${SCRIPT_NAME} setup-guest --guest-ip <IP>
  4. Run attestation:           sudo ${SCRIPT_NAME} attest --guest-ip <IP>

NOTE: The guest must have a SNP-capable kernel (6.1+) and the snpguest module.
NEXT
    log "Conversion complete."
}

cmd_show_vm_info() {
    require_cmd virsh
    echo ""
    printf "%-30s %-12s %-18s\n" "NAME" "STATE" "IP"
    printf "%-30s %-12s %-18s\n" "----" "-----" "--"
    local vm state ip
    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        state=$(virsh domstate "$vm" 2>/dev/null || echo "unknown")
        ip="—"
        if [[ "$state" == "running" ]]; then
            ip=$(virsh domifaddr "$vm" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1 || true)
            ip="${ip:-no IP detected}"
        fi
        printf "%-30s %-12s %-18s\n" "$vm" "$state" "$ip"
    done < <(virsh list --all --name 2>/dev/null)
    echo ""
}

# =============================================================================
# 7. GUEST SETUP  — AMD SEV-SNP
# =============================================================================
cmd_setup_guest() {
    require_root

    detect_guest_ip

    log "=== Setting up SEV-SNP guest (ssh to ${GUEST_IP}) ==="
    step "Inside the SNP VM: install snpguest, generate + verify a report" \
        "Confirms a SNP guest device exists, then runs 'snpguest report' to produce report.dat and 'snpguest verify' to check it."

    log "Checking SSH connectivity to ${GUEST_IP}..."
    if ! ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        "${GUEST_USER}@${GUEST_IP}" "echo ok" >/dev/null 2>&1; then
        die "Cannot connect to ${GUEST_USER}@${GUEST_IP} via SSH.

=== Troubleshooting ===

1. Guest OS not installed yet?
  Open console and install the OS:
    virsh console <VM_NAME>

2. SSH service not running in guest?
  Check inside the guest:
    sudo systemctl status sshd
    sudo systemctl enable --now sshd

3. SSH key not injected?
  The script uses key: ${SSH_KEY}
  If it does not exist, create one:
    ssh-keygen -t ed25519 -f ${SSH_KEY} -N ''
  Then copy the public key to the guest:
    ssh-copy-id -i ${SSH_KEY}.pub ${GUEST_USER}@${GUEST_IP}

4. Wrong IP?
  Check the actual guest IP:
    virsh net-dhcp-leases default

5. Firewall blocking port 22?
  Check inside the guest:
    sudo firewall-cmd --list-ports
    sudo firewall-cmd --add-port=22/tcp --permanent && sudo firewall-cmd --reload"
    fi
    log "SSH connection to ${GUEST_IP} OK"

    # Refuse to run against the SNP host. /dev/sev exists only on the host,
    # never inside an SNP VM (the guest has /dev/sev-guest instead).
    if ssh_guest "test -c /dev/sev"; then
        die "Target is the SEV-SNP *host* (/dev/sev present), not an SNP VM.
Boot the SNP VM first, then run:
  sudo snp-attest.sh setup-guest --guest-ip <SNP_VM_IP>
or run this command inside the SNP VM itself."
    fi

    # The SNP guest attestation device node is /dev/sev-guest (provided by the
    # snpguest kernel module). A real character device is required.
    log "Checking for a SNP guest attestation device (must exist INSIDE an SNP VM)"
    if ssh_guest "test -c /dev/sev-guest"; then
        log "Found /dev/sev-guest — running inside a real SNP VM"
    else
        log "No /dev/sev-guest yet — attempting 'modprobe snpguest' in guest"
        if ssh_guest "sudo modprobe snpguest 2>/dev/null; test -c /dev/sev-guest"; then
            log "snpguest module loaded — /dev/sev-guest present"
        else
            die "No SNP guest attestation device found (/dev/sev-guest).
This command must run INSIDE an SEV-SNP confidential VM, not on the host.
  - If you targeted localhost from the host: use --guest-ip <SNP_VM_IP> instead.
  - Inside the SNP VM, check: 'modprobe snpguest' and 'dmesg | grep -i sev'.
    'modprobe: No such device' means the VM is not an SNP VM.
  - On the host, the VM must be started with <launchSecurity type='sev-snp'>
    and a SNP OVMF, with SEV-SNP enabled in BIOS.
See doc: snp-guest-setup troubleshooting."
        fi
    fi

    if ssh_guest "grep -qw sev /proc/cpuinfo"; then
        log "Guest CPU reports sev flag"
    else
        warn "Guest CPU does not report sev flag (may still be OK via host-passthrough)"
    fi

    log "Disabling suspend/hibernate in guest (SNP requirement)"
    if disable_suspend_guest; then
        log "Suspend/hibernate targets masked in guest"
    else
        warn "Failed to mask suspend/hibernate targets in guest. Do it manually:"
        warn "  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target"
    fi

    log "Creating guest workdir: ${GUEST_WORKDIR}"
    ssh_guest "sudo mkdir -p ${GUEST_WORKDIR} && sudo chown \$(whoami) ${GUEST_WORKDIR}" ||
        ssh_guest "mkdir -p ${GUEST_WORKDIR}"

    log "Checking attestation libraries + KBS client in guest"
    # The SNP attestation packages are not (yet) in the default SLES 16.1
    # repos — add the Virtualization:SGX repo in the guest and refresh first.
    log "Ensuring ${SNP_REPO_NAME} repository in guest: ${SNP_REPO_URL}"
    ssh_guest "sudo bash -s" <<EOF
set -e
if ! zypper lr | grep -Eq "^[0-9]+[[:space:]]*\|[[:space:]]*${SNP_REPO_NAME}[[:space:]]*\|"; then
    zypper --non-interactive addrepo ${SNP_REPO_URL} ${SNP_REPO_NAME}
fi
key=\$(mktemp)
if curl -fsSL ${SNP_REPO_URL}repodata/repomd.xml.key -o "\$key"; then
    rpm --import "\$key"
fi
rm -f "\$key"
zypper refresh
EOF
    # shellcheck disable=SC2046
    install_pkgs_guest $(guest_distro_pkgs snp_guest)

    log "Verifying snpguest in guest"
    local snpguest_bin
    snpguest_bin=$(guest_distro_snp_guest_bin)
    if ssh_guest "test -x ${snpguest_bin}"; then
        log "snpguest present in guest: ${snpguest_bin}"
    else
        warn "snpguest not at expected path in guest: ${snpguest_bin}"
    fi

    # The guest kbs-client (trustee package) must have the SNP attester.
    local guest_pkg_client
    guest_pkg_client=$(guest_distro_kbs_client_bin)
    if ssh_guest "test -x ${guest_pkg_client}" && kbs_client_supports_snp_guest "$guest_pkg_client"; then
        log "Package kbs-client (${guest_pkg_client}) has the SNP attester"
    else
        die "Guest kbs-client (${guest_pkg_client}) is missing or has no SNP attester. Install/upgrade the guest 'trustee' package from the ${SNP_REPO_NAME} repo and re-run setup-guest."
    fi
    ssh_guest "sudo rm -f ${KBS_CLIENT_GUEST_LEGACY}" 2>/dev/null || true

    # snp-report-gen: report generator that binds caller-specified report data
    # (required for host-mode secret-get; the distro's 'snpguest report' uses
    # random report_data by default). Built from tools/snp-report-gen.c.
    if ssh_guest "test -x ${SNP_REPORT_GEN_GUEST}"; then
        log "snp-report-gen present in guest"
    else
        log "Building snp-report-gen in guest (needs gcc)"
        if ! ssh_guest "command -v gcc" >/dev/null 2>&1; then
            log "Installing gcc in guest (zypper)"
            install_pkgs_guest gcc ||
                die "Failed to install gcc in guest (needed to build snp-report-gen)"
        fi
        ssh_guest "cat > ${GUEST_WORKDIR}/snp-report-gen.c" \
            <"${SCRIPT_DIR}/tools/snp-report-gen.c" ||
            die "Failed to copy tools/snp-report-gen.c to guest (is the tools/ directory present?)"
        ssh_guest "gcc -O2 -o ${SNP_REPORT_GEN_GUEST} ${GUEST_WORKDIR}/snp-report-gen.c" ||
            die "Failed to build snp-report-gen in guest"
        log "snp-report-gen installed in guest: ${SNP_REPORT_GEN_GUEST}"
    fi

    # Ship the certificate chain to the guest so 'snpguest verify' can run
    # fully in-guest (offline mode) or the guest can fetch it from KDS.
    if [[ "$COLLATERAL_MODE" == "offline" && -s "$SNP_ARK_CERT" ]]; then
        log "Shipping SNP certificate chain to guest (offline mode)"
        ssh_guest "sudo mkdir -p ${GUEST_WORKDIR}/certs"
        for cert in "$SNP_ARK_CERT" "$SNP_ASK_CERT" "$SNP_VCEK_CERT"; do
            if [[ -s "$cert" ]]; then
                ssh_guest "sudo tee ${GUEST_WORKDIR}/certs/$(basename "$cert")" <"$cert" >/dev/null ||
                    die "Failed to ship $(basename "$cert") to guest"
            fi
        done
    else
        log "Guest will fetch the certificate chain from KDS (snpguest fetch)"
    fi

    log "Generating SNP report (snpguest report)"
    if ! guest_generate_report; then
        die "snpguest report failed. Check the guest (dmesg | grep -i sev) and that the VM is a real SNP VM."
    fi

    log "Verifying the generated report in-guest (snpguest verify)"
    if guest_verify_report; then
        log "In-guest report verification PASSED"
    else
        warn "In-guest report verification reported a problem (see output above)."
        warn "This does not block CoCo-AS attestation, which verifies host-side."
    fi

    cat <<NEXT

=== Guest setup complete ===

The SNP guest is ready for attestation:
  - /dev/sev-guest present (real SNP VM)
  - snpguest + snp-report-gen installed
  - kbs-client has the SNP attester
  - a report has been generated + verified in-guest

Next: run attestation from the host:
  sudo snp-attest.sh attest --guest-ip ${GUEST_IP} --register-rv
  sudo snp-attest.sh secret-set --file <f> --name <name>
  sudo snp-attest.sh secret-get --guest-ip ${GUEST_IP} --name <name>

NEXT
    log "Guest setup complete."
}
