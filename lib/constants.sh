# =============================================================================
# 1. CONSTANTS & DEFAULTS  (AMD SEV-SNP)
# =============================================================================
# NOTE: This file defines shared state consumed by functions across all other
# lib/*.sh files. SC2034 "appears unused" warnings from static analysis are
# expected and suppressed below — these variables are consumed cross-file.
# shellcheck disable=SC2034,SC2155

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
# SCRIPT_DIR is defined in the main script before sourcing these files.

# Platform check
CHECK_PLATFORM=0

# VM defaults
VM_NAME="snp-guest"
VM_NO_SNP=0
VM_NO_SNP_NAME="nonsnp-guest"
VM_DISPLAY_NAME=""
VM_MEM=16384 # MiB (16 GB)
VM_CPU=4
VM_DISK="32G"
VM_DISK_PATH="/var/lib/libvirt/images/snp-guest.qcow2"
VM_XML_PATH="/var/lib/libvirt/snp-guest.xml"
VM_NO_SNP_DISK_PATH="/var/lib/libvirt/images/nonsnp-guest.qcow2"
VM_NO_SNP_XML_PATH="/var/lib/libvirt/nonsnp-guest.xml"
# VNC listen address for the guest display. 0.0.0.0 so a remote VNC client
# can see the installer; use 127.0.0.1 to keep VNC host-local only.
VNC_LISTEN="0.0.0.0"
# Fixed VNC port for the guest display (libvirt default is autoport).
VNC_PORT="5900"
# VM creation engine: auto (virt-install if available, else generated XML),
# virt (force virt-install), xml (force generated XML)
VM_CREATOR="auto"
# setup-vm: print the virt-install command without executing
DRY_RUN=0
CONVERT_VM_NAME=""

# SNP launch policy (64-bit). 0x30000 is the SUSE/libvirt default for a
# production SNP guest (no DEBUG, single-socket, host-data + platform certs
# requirements). Override with --snp-policy for a specific deployment.
SNP_POLICY="0x30000"
# NOTE: the guest VMPL is deliberately not configurable here. libvirt's
# <launchSecurity type='sev-snp'> schema has no VMPL element; the guest OS
# runs at VMPL 0 and 'snpguest report --vmpl' selects the level per report.

# Attestation collateral source: AMD KDS (Key Distribution Service).
# Method 1 (kds):    fetch the ARK/ASK/VCEK certificate chain directly from
#                    AMD's global KDS — always authoritative, every fetch goes
#                    over the public internet.
# Method 2 (offline): use a locally-provisioned certificate store (air-gapped);
#                    import the chain once with 'snphost import' and reuse it.
KDS_URL="${KDS_URL:-https://kdsintf.amd.com/vcek/v1}"
# Local offline certificate store (method 2). 'snphost import' writes the
# ARK/ASK/VCEK chain here; 'snphost' reads it back for verification.
readonly SNP_CERT_DIR="/var/lib/sev-snp/certs"
readonly SNP_ARK_CERT="${SNP_CERT_DIR}/ark.pem"
readonly SNP_ASK_CERT="${SNP_CERT_DIR}/ask.pem"
readonly SNP_VCEK_CERT="${SNP_CERT_DIR}/vcek.pem"
# Collateral source: kds (method 1, global) or offline (method 2, local store).
COLLATERAL_MODE="kds"
# Whether to enforce TLS certificate validation when talking to KDS.
USE_SECURE_CERT="auto"

# Guest package repo for SNP attestation packages (SLE 16.1). The snphost /
# snpguest packages are not (yet) in the default SLES 16.1 repos, so
# setup-host / setup-guest add this repo, refresh, and install from it.
SNP_REPO_URL="https://download.opensuse.org/repositories/Virtualization:/SGX/16.1/"
SNP_REPO_NAME="SNP"

# CoCo-AS defaults to 127.0.0.1:3000 when the config has no listen field.
COCO_AS="127.0.0.1:3000"
KBS_PORT=8080
# KBS address reachable by BOTH host and guest (libvirt 'default' network).
KBS_HOST="192.168.122.1"
KBS_URL="" # derived from KBS_HOST:KBS_PORT if empty

# Secret delivery (KBS) defaults
SECRET_PATH="default/test/secret"
SECRET_FILE=""
# secret-get mode:
#   guest = run kbs-client inside the SNP VM (needs the SNP-enabled build)
#   host  = host-side attest (grpcurl) + KBS REST curl (no build needed)
SECRET_MODE="guest"
# Populated by attest_get_ear_token() with the EAR JWT from CoCo-AS.
EAR_TOKEN=""
# Last base64 SNP report fetched from the guest (set by attest_get_ear_token).
# Reused by the --register-rv flow to re-evaluate the SAME report instead of
# generating a fresh one (the report's report_data is a per-run nonce).
LAST_REPORT_B64=""
# Legacy source-built kbs-client path — no longer used (the distro 'trustee'
# package kbs-client ships the SNP attester, version-aligned with the host
# verifier). Kept only so setup can clean up stale installs.
KBS_CLIENT_GUEST_LEGACY="/usr/local/bin/kbs-client-snp"

# Guest access
GUEST_IP=""
GUEST_WORKDIR="/root/snp-attest"
# SNP report generator that binds caller-specified report data (built by
# setup-guest from tools/snp-report-gen.c). Needed for host-mode secret-get,
# where the report's report_data must equal sha384 of the runtime data; the
# distro's 'snpguest report' uses a random report_data by default.
SNP_REPORT_GEN_GUEST="/usr/local/bin/snp-report-gen"
SSH_KEY="$HOME/.ssh/id_ed25519"
GUEST_ISO=""
GUEST_USER="root"

# Logging
LOG_FILE="/var/log/snp-attest.log"
DEBUG=0
QUIET=0
FORCE=0
REGISTER_RV=0
RV_ID=""

# NOTE: package names and distro-specific binary paths live in the
# distribution adapter (lib/distros/<id>.sh), not here.

# Paths
# CoCo-AS config (KBS only accepts file:// or https:// for trusted_jwk_sets).
readonly GRPC_AS_CONF="/etc/grpc-as.json"
readonly KBS_CONF="/etc/kbs.json"
readonly KBS_JWKS_FILE="/etc/trustee/jwks.json"
readonly RVPS_CONF="/etc/rvps.json"
readonly AS_STORAGE_DIR="/var/lib/attestation-service/storage"

# Trustee / KBS admin material (for secret delivery)
readonly TRUSTEE_DIR="/etc/trustee"
readonly KBS_ADMIN_KEY="${TRUSTEE_DIR}/kbs-admin.key"
readonly KBS_ADMIN_PUB="${TRUSTEE_DIR}/kbs-admin.pub"
readonly KBS_POLICY="${TRUSTEE_DIR}/resource-policy.rego"

# CoCo-AS token signer (persistent EC key pair + self-signed cert). Without a
# signer, grpc-as uses an ephemeral key and KBS cannot verify attestation
# tokens. The KEY stays under the AS storage dir (owned by coco_as); the CERT
# lives in /etc/trustee so KBS (coco_kbs) can read it.
readonly AS_SIGNER_DIR="${AS_STORAGE_DIR}/signer"
readonly AS_SIGNER_KEY="${AS_SIGNER_DIR}/as-signer.key"
readonly AS_SIGNER_PUB="${AS_SIGNER_DIR}/as-signer.pub"
readonly AS_SIGNER_CERT="${TRUSTEE_DIR}/as-signer.crt"
