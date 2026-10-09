# =============================================================================
# SLES / openSUSE adapter (zypper + rpm)  — AMD SEV-SNP
# =============================================================================
# The proven behavior for SLE 15/16 and openSUSE. Package names are the actual
# SLE 16.1 names (verify with: zypper se <term>). Hook contract: see
# lib/distros/_detect.sh.
#
# All sles_* variables/functions are consumed cross-file via indirection
# (${!v} / "${DISTRO_ID}_<hook>") in lib/distros/_detect.sh, so single-file
# "unused variable" warnings are false positives.
# shellcheck disable=SC2034

sles_pkg_manager="zypper"

# Package sets by role (word lists; call sites word-split them on purpose).
# Host needs snphost (the SEV-SNP host CLI: platform probe, KDS fetch, cert
# chain verification). There is NO host-side quote daemon for SEV-SNP (unlike
# TDX's QGS) — report generation happens in-guest via GHCB.
sles_pkgs_snp_host="snphost"
# Guest needs snpguest (the SEV-SNP guest CLI: report generation/verification
# via /dev/sev-guest) plus the kernel module.
sles_pkgs_snp_guest="snpguest"
# Trustee: CoCo-AS (grpc-as), KBS, RVPS, kbs-client. The snp_verifier library
# is pulled in by the trustee package.
sles_pkgs_trustee="trustee"
sles_pkgs_libvirt="libvirt-daemon-driver-qemu libvirt-client"
sles_pkgs_qemu="qemu"
sles_pkgs_virt_customize="libguestfs-tools"
# SNP OVMF: the edk2 package provides OVMF.SNP.fd + OVMF_VARS.SNP.fd in the
# QEMU firmware descriptor dir.
sles_pkgs_ovmf="qemu-ovmf-x86_64 edk2-ovmf"
sles_pkgs_grpcurl="grpcurl"

# SUSE packaging layout.
sles_snp_host_bin="/usr/bin/snphost"
sles_snp_guest_bin="/usr/bin/snpguest"
sles_kbs_bin="/usr/libexec/kbs" # symlink to /usr/libexec/trustee/kbs (created by setup)
sles_kbs_client_bin="/usr/libexec/trustee/kbs-client"
sles_grpc_as_bin="/usr/libexec/grpc-as"
sles_trustee_needs_symlinks=1 # units reference /usr/libexec/<name>, pkg ships /usr/libexec/trustee/<name>
sles_ovmf_fwdir="/usr/share/qemu/firmware"

sles_pkg_refresh() { run zypper refresh; }
sles_pkg_installed() { rpm -q "$1" >/dev/null 2>&1; }
sles_pkg_install() { run zypper in -y "$@"; }
sles_pkg_list_all() { rpm -qa 2>/dev/null || true; }

# SLE refreshes the system trust store. Two generations of tooling:
# - SLES 15: update-ca-trust regenerates /etc/pki/tls/certs/ca-bundle.crt
#   from /etc/pki/ca-trust/source/anchors/.
# - SLES 16.1: Debian-style ca-certificates; update-ca-certificates
#   regenerates /etc/ssl/certs (hashed) + /var/lib/ca-certificates/
#   from the p11-kit store (`trust extract --filter=ca-anchors`).
sles_ca_trust_refresh() {
    if command -v update-ca-trust >/dev/null 2>&1; then
        run update-ca-trust
    elif command -v update-ca-certificates >/dev/null 2>&1; then
        run update-ca-certificates
    else
        log "no trust store refresh tool found; p11-kit DB is the system store"
        return 0
    fi
}

# Remote command that reads a CA certificate from stdin and installs it into
# every guest trust store (anchor dir, p11-kit DB, OpenSSL store).
sles_ca_trust_cmd="A=/etc/pki/ca-trust/source/anchors/amd-kds-ca.pem; sudo mkdir -p \$(dirname \"\$A\") && sudo install -m 0644 /dev/stdin \"\$A\" && (sudo trust anchor \"\$A\" 2>/dev/null || true) && if command -v update-ca-trust >/dev/null 2>&1; then sudo update-ca-trust; elif command -v update-ca-certificates >/dev/null 2>&1; then sudo update-ca-certificates; else f=\$(awk '/BEGIN CERT/{f=1;next}/END CERT/{f=0}f' \"\$A\" | head -1); grep -qF \"\$f\" /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null || sudo tee -a /etc/pki/tls/certs/ca-bundle.crt < \"\$A\" >/dev/null; fi"

sles_grub_snp_hint() {
    echo "Mandatory: ensure SEV-SNP is enabled in BIOS and kvm_amd is loaded with SNP support (kvm_amd.nested=1 not required; check 'dmesg | grep -i sev' after boot)"
}

# Regular (non-SNP) pflash OVMF: first firmware descriptor with a flash device
# that does not advertise SNP. Requires jq.
sles_ovmf_regular_probe() {
    command -v jq >/dev/null 2>&1 || return 1
    local f dev bin
    for f in /usr/share/qemu/firmware/*.json; do
        [[ -f "$f" ]] || continue
        # Skip SNP firmware descriptors
        if jq -e '(.features // []) | any(test("snp";"i"))' "$f" >/dev/null 2>&1; then
            continue
        fi
        dev=$(jq -r '.mapping.device // empty' "$f" 2>/dev/null)
        if [[ "$dev" == "flash" ]]; then
            bin=$(jq -r '.mapping.executable.filename // .mapping.filename // empty' "$f" 2>/dev/null)
            if [[ -n "$bin" && -f "$bin" ]]; then
                echo "$bin"
                return 0
            fi
        fi
    done
    return 1
}

# Scan SLE's QEMU firmware descriptors for a SNP-capable OVMF.
# Prints "descriptor|binary" on success, returns 1 otherwise.
# The SNP OVMF is a pflash firmware (mapping.executable.filename) with the
# "snp" feature — unlike TDX, which maps its OVMF as a stateless ROM.
sles_ovmf_snp_probe() {
    local fwdir="$sles_ovmf_fwdir" f bin
    [[ -d "$fwdir" ]] || return 1
    for f in "$fwdir"/*.json; do
        [[ -f "$f" ]] || continue
        # Does this descriptor advertise SNP in its features list?
        if command -v jq >/dev/null 2>&1; then
            jq -e '(.features // []) | any(test("snp";"i"))' "$f" >/dev/null 2>&1 || continue
            # SNP OVMF image path: pflash layout uses mapping.executable.filename;
            # the SUSE ROM-style single image uses mapping.filename (device: memory).
            bin=$(jq -r '.mapping.executable.filename // .mapping.filename // empty' "$f" 2>/dev/null)
        else
            grep -qi 'snp' "$f" || continue
            bin=$(grep -oP '"filename"\s*:\s*"\K[^"]+' "$f" | head -1)
        fi
        [[ -n "$bin" ]] || continue
        echo "${f}|${bin}"
        return 0
    done
    return 1
}

# Add the SNP attestation repo inside the guest (the snpguest / trustee
# packages are not in the default SLES 16.1 repos yet) and import its signing
# key. Idempotent: an already-registered repo is left alone.
sles_guest_repo_add() {
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
}

# Install packages inside the guest over ssh (single round-trip missing-check).
sles_guest_pkg_install() {
    ssh_guest "missing=; for p in $*; do rpm -q \$p >/dev/null 2>&1 || missing=\"\$missing \$p\"; done
if [ -z \"\$missing\" ]; then echo 'Already installed: $*'; else echo \"Installing:\$missing\"; sudo zypper refresh; sudo zypper in -y \$missing; fi"
}
