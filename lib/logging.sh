# =============================================================================
# 2. LOGGING & ERROR HANDLING
# =============================================================================

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log() {
    local level="$1"
    shift
    local msg
    msg="[$(_ts)] [${level}] $*"
    if ((QUIET)) && [[ "$level" != "ERROR" ]]; then
        return 0
    fi
    echo "$msg" >&2
    if [[ -n "$LOG_FILE" ]] && ((EUID == 0)); then
        echo "$msg" >>"$LOG_FILE" 2>/dev/null || true
    fi
}

log() { _log "INFO" "$@"; }
warn() { _log "WARN" "$@"; }
error() { _log "ERROR" "$@"; }

# Render text in red when stderr is a terminal (respects NO_COLOR).
red() {
    if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
        printf '\033[31m%s\033[0m' "$*"
    else
        printf '%s' "$*"
    fi
}

# Print a human-readable explanation of the current step to the user.
# step "<what>" "<why / what will happen>"
step() {
    local what="$1" why="${2:-}"
    _log "STEP" ">>> ${what}"
    [[ -n "$why" ]] && _log "STEP" "    ${why}"
    return 0
}

# Render a command as a safely-quoted, copy-pasteable one-liner.
cmdline() { printf '%q ' "$@" | sed 's/ $//'; }

die() {
    error "$@"
    error "Aborting. Check $LOG_FILE for details."
    exit 1
}

# Execute a command, always printing the exact command line first so the user
# sees precisely what runs. In debug mode, full set -x trace is also shown.
run() {
    _log "CMD" "\$ $(cmdline "$@")"
    if ((DEBUG)); then
        set -x
        "$@"
        local rc=$?
        set +x
        return "$rc"
    else
        "$@"
    fi
}

on_error() {
    local exit_code=$?
    local line_no=$1
    error "Command failed at line ${line_no} (exit ${exit_code}): ${BASH_COMMAND}"
    error "Failing function: ${FUNCNAME[1]:-main}"
    error "Hints:"
    error "  - journalctl -k | grep -i sev         (kernel SEV-SNP errors)"
    error "  - journalctl -u grpc-as.service -n 50 (CoCo-AS logs)"
    error "  - snphost ok                          (SNP platform probe)"
    error "  - Re-run with -d for full trace"
}
trap 'on_error $LINENO' ERR

init_debug() {
    if ((DEBUG)); then
        export PS4='+ [$(date +%T)] ${FUNCNAME[0]}:${LINENO}: '
        log "Debug mode enabled (set -x active, PS4 with timestamps)"
    fi
}
