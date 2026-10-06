#!/usr/bin/env bash
# =============================================================================
# make-tarball.sh — Build a versioned tarball of the coco_tdx scripts
#
# Usage: ./make-tarball.sh [OUTPUT_DIR]
#   OUTPUT_DIR  Directory where the tarball will be written (default: .)
#
# Output: coco_tdx-<VERSION>.tar.gz
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Version ──────────────────────────────────────────────────────────────────
VERSION_FILE="${SCRIPT_DIR}/lib/constants.sh"
if [[ ! -f "$VERSION_FILE" ]]; then
 echo "ERROR: Version file not found: ${VERSION_FILE}" >&2
 exit 1
fi
VERSION=$(grep -oP 'SCRIPT_VERSION="\K[0-9.]+' "$VERSION_FILE")
if [[ -z "$VERSION" ]]; then
 echo "ERROR: Could not parse version from ${VERSION_FILE}" >&2
 exit 1
fi
echo "Version: ${VERSION}"

# ── Output directory ─────────────────────────────────────────────────────────
OUTPUT_DIR="${1:-.}"
mkdir -p "$OUTPUT_DIR"

# ── Tarball name ─────────────────────────────────────────────────────────────
TARBALL_NAME="coco_tdx-${VERSION}.tar.gz"
TARBALL_PATH="${OUTPUT_DIR}/${TARBALL_NAME}"

# ── Temp staging directory ───────────────────────────────────────────────────
STAGING_DIR=$(mktemp -d)
trap 'rm -rf "${STAGING_DIR}"' EXIT
STAGING_TAR="${STAGING_DIR}/coco_tdx-${VERSION}"
mkdir -p "${STAGING_TAR}"

# Copy files into versioned staging directory
cp -a "${SCRIPT_DIR}/README.md" "${SCRIPT_DIR}/LICENSE" \
 "${SCRIPT_DIR}/CHANGELOG.md" \
 "${SCRIPT_DIR}/tdx-attest.sh" "${SCRIPT_DIR}/pccs-check.sh" \
 "${SCRIPT_DIR}/convert_doc.py" \
 "${STAGING_TAR}/"
cp -a "${SCRIPT_DIR}/lib" "${STAGING_TAR}/"
# tools/ is required at runtime: setup-vm.sh calls tools/patch_vm_xml.py and
# setup-guest builds tools/tdx-quote-gen.c in the guest.
cp -a "${SCRIPT_DIR}/tools" "${STAGING_TAR}/"

# ── Build tarball ────────────────────────────────────────────────────────────
echo "Creating ${TARBALL_PATH} ..."

tar czf "$TARBALL_PATH" \
 --exclude='.git' \
 --exclude='.gitmodules' \
 --exclude='.claude' \
 --exclude='.vscode' \
 --exclude='.idea' \
 --exclude='.ruff_cache' \
 --exclude='*.pyc' \
 --exclude='__pycache__' \
 --exclude='*.html' \
 -C "${STAGING_DIR}" \
 "coco_tdx-${VERSION}"

# ── Verify ───────────────────────────────────────────────────────────────────
echo "Tarball created successfully:"
echo "  File:   ${TARBALL_PATH}"
echo "  Size:   $(du -h "$TARBALL_PATH" | cut -f1)"
echo "  Contents:"
tar tzf "$TARBALL_PATH" | sed 's/^/    /'
