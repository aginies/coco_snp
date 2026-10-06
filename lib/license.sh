# =============================================================================
# lib/license.sh — GPLv3 license notice helpers
#
# Implements the classic GPL "interactive mode" notice:
#
#   <program>  Copyright (C) <year>  <name of author>
#   This program comes with ABSOLUTELY NO WARRANTY; for details type `show w'.
#   This is free software, and you are welcome to redistribute it
#   under certain conditions; type `show c' for details.
#
# The hypothetical `show w' / `show c' commands are exposed as this script's
# `show-w' / `show-c' subcommands (see snp-attest.sh). Full license text:
# the LICENSE file next to the script (GPLv3).
# =============================================================================

readonly LICENSE_PROGRAM="snp-attest"
readonly LICENSE_YEAR="2026"
readonly LICENSE_AUTHOR="SUSE"
readonly LICENSE_FILE="${SCRIPT_DIR}/LICENSE"

# Classic 4-line notice (printed at startup in interactive mode).
license_notice() {
  cat <<EOF
${LICENSE_PROGRAM}  Copyright (C) ${LICENSE_YEAR}  ${LICENSE_AUTHOR}
This program comes with ABSOLUTELY NO WARRANTY; for details type \`show w'.
This is free software, and you are welcome to redistribute it
under certain conditions; type \`show c' for details.
EOF
}

# `show w' — the warranty terms (from the GNU GPL preamble).
license_show_warranty() {
  cat <<EOF
  ${LICENSE_PROGRAM} is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License, version 3, for more details.

  Full license text: ${LICENSE_FILE}
EOF
}

# `show c' — the copyright & license terms (from the GNU GPL preamble).
license_show_copyright() {
  cat <<EOF
  Copyright (C) ${LICENSE_YEAR}  ${LICENSE_AUTHOR}

  ${LICENSE_PROGRAM} is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 3 of the License.

  You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

  Full license text: ${LICENSE_FILE}
EOF
}

# Print the classic notice when running interactively (stdin is a TTY —
# a human is at the terminal). Silent in automated/piped runs.
license_banner() {
  if [[ -t 0 ]]; then
    license_notice >&2
    echo >&2
  fi
}
