#!/usr/bin/env bash
# =============================================================================
# tekhton.sh — m20 dispatcher.
#
# Run-flags (--task / --complete / --resume / --human / --milestone /
# --auto-advance / --dry-run / --no-tui) exec the Go binary `tekhton run`.
# Everything else falls through to tekhton-legacy.sh — the V3 bash entry
# point retained for unmigrated subsystems (--init, --plan, --rescan,
# --status, --metrics, --migrate, --health, --rollback, --notes, bare
# positional task strings, etc.). Phase 5 ports one legacy flag at a time
# out of tekhton-legacy.sh into Go; see docs/v4-phase5-stub.md.
#
# Set TEKHTON_DEBUG_DISPATCHER=1 to trace the routing decision.
# =============================================================================

set -euo pipefail

# --- Bash version guard (3.2-compatible syntax) ------------------------------
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
    echo "ERROR: Tekhton requires bash 4.3+ but found bash ${BASH_VERSION}." >&2
    [ "$(uname -s)" = "Darwin" ] && echo "Install modern bash via: brew install bash" >&2
    exit 1
fi

# --- Path resolution ---------------------------------------------------------
TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEKHTON_BIN="${TEKHTON_BIN:-${TEKHTON_HOME}/bin/tekhton}"
TEKHTON_LEGACY_BIN="${TEKHTON_LEGACY_BIN:-${TEKHTON_HOME}/tekhton-legacy.sh}"
export TEKHTON_HOME TEKHTON_BIN TEKHTON_LEGACY_BIN

# --- --version / -v (handled in-dispatcher so legacy is not required) --------
if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    [[ -f "${TEKHTON_HOME}/VERSION" ]] \
        && echo "Tekhton $(tr -d '[:space:]' < "${TEKHTON_HOME}/VERSION")" \
        || echo "Tekhton 0.0.0"
    exit 0
fi

# --- Helpers: run-flag detection + on-demand binary build --------------------
_tekhton_argv_has_run_flag() {
    local a
    for a in "$@"; do
        case "$a" in
            --task|--complete|--resume|--human|--milestone|--auto-advance|--dry-run|--no-tui)
                return 0 ;;
        esac
    done
    return 1
}

_tekhton_ensure_bin() {
    [[ -x "$TEKHTON_BIN" ]] && return 0
    echo "[tekhton] Building Go binary (first run)..." >&2
    (cd "$TEKHTON_HOME" && make build) >&2 || {
        echo "[tekhton] make build failed; cannot dispatch run-flag." >&2; exit 1
    }
}

# --help routes to `tekhton run --help` per m20 acceptance criteria.
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && [[ "${2:-}" != "--all" ]]; then
    _tekhton_ensure_bin
    [[ "${TEKHTON_DEBUG_DISPATCHER:-0}" == "1" ]] && echo "[tekhton-dispatcher] exec ${TEKHTON_BIN} run --help" >&2
    exec "$TEKHTON_BIN" run --help
fi

if _tekhton_argv_has_run_flag "$@"; then
    _tekhton_ensure_bin
    [[ "${TEKHTON_DEBUG_DISPATCHER:-0}" == "1" ]] && echo "[tekhton-dispatcher] exec ${TEKHTON_BIN} run $*" >&2
    exec "$TEKHTON_BIN" run "$@"
fi

# --- Legacy fallback (everything else: --init, --plan, --status, etc.) -------
# TEKHTON_LEGACY_BIN is overridable so tests can stub the legacy entry point
# without launching real pipeline runs for bogus task strings.
[[ "${TEKHTON_DEBUG_DISPATCHER:-0}" == "1" ]] && echo "[tekhton-dispatcher] exec bash ${TEKHTON_LEGACY_BIN} $*" >&2
exec bash "${TEKHTON_LEGACY_BIN}" "$@"
