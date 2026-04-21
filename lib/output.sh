#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# output.sh — Output Bus foundation: context store + unified routing.
#
# Sourced by lib/common.sh after _tui_strip_ansi and _tui_notify are defined.
# Do not run directly.
#
# Provides:
#   _OUT_CTX            — associative array holding all run-state that affects
#                         user-facing display
#   out_init            — initialise _OUT_CTX with safe defaults
#   out_set_context K V — store a key/value pair in _OUT_CTX
#   out_ctx K           — retrieve a key from _OUT_CTX (empty string if unset)
#   _out_emit LVL MSG   — unified routing core shared by log/warn/error/...
#   out_log/warn/error/success/header — convenience wrappers for new callers
# =============================================================================

# shellcheck disable=SC2034  # _OUT_CTX is read by callers via out_ctx
declare -gA _OUT_CTX=()

# out_init — set all known keys to empty-but-defined strings so that any
# consumer (e.g. `out_ctx missing_key`) returns "" instead of tripping `set -u`.
out_init() {
    declare -gA _OUT_CTX
    _OUT_CTX[mode]=""
    _OUT_CTX[attempt]="1"
    _OUT_CTX[max_attempts]="1"
    _OUT_CTX[task]=""
    _OUT_CTX[milestone]=""
    _OUT_CTX[milestone_title]=""
    _OUT_CTX[stage_order]=""
    _OUT_CTX[cli_flags]=""
    _OUT_CTX[current_stage]=""
    _OUT_CTX[current_model]=""
    _OUT_CTX[action_items]=""
}

# out_reset_pass — Clear per-pass display state so multi-pass loops
# (--fix nb, --fix drift, --human --complete) start each pass with a fresh
# Action Items list and no stale current-stage carry-over. Preserves run
# identity (mode, task, cli_flags, max_attempts, milestone*, stage_order)
# and the attempt counter, which the caller owns and advances itself.
out_reset_pass() {
    _OUT_CTX[action_items]=""
    _OUT_CTX[current_stage]=""
    _OUT_CTX[current_model]=""
}

# out_set_context KEY VALUE — store a key in _OUT_CTX.
out_set_context() {
    local key="${1:-}"
    local value="${2:-}"
    [[ -z "$key" ]] && return 0
    _OUT_CTX[$key]="$value"
}

# out_ctx KEY — print the stored value (empty string if unset).
out_ctx() {
    local key="${1:-}"
    [[ -z "$key" ]] && { printf ''; return 0; }
    printf '%s' "${_OUT_CTX[$key]:-}"
}

# _out_emit LEVEL MSG... — route a single message. Chooses between terminal
# echo, log-file append (when the TUI owns stdout), and the TUI event feed.
# Prefix and style are derived from LEVEL so callers don't have to repeat them.
_out_emit() {
    local level="${1:-info}"; shift || true
    local msg="$*"
    local prefix style notify_level notify_msg
    case "$level" in
        info)
            prefix="[tekhton]"; style="${CYAN:-}"
            notify_level="info";    notify_msg="$msg" ;;
        mode)
            prefix="[~]";       style="${CYAN:-}"
            notify_level="info";    notify_msg="[~] $msg" ;;
        warn)
            prefix="[!]";       style="${YELLOW:-}"
            notify_level="warn";    notify_msg="[!] $msg" ;;
        error)
            prefix="[✗]";       style="${RED:-}"
            notify_level="error";   notify_msg="[✗] $msg" ;;
        success)
            prefix="[✓]";       style="${GREEN:-}"
            notify_level="success"; notify_msg="[✓] $msg" ;;
        header)
            prefix="";          style="${BOLD:-}${CYAN:-}"
            notify_level="info";    notify_msg="$msg" ;;
        *)
            prefix="[tekhton]"; style="${CYAN:-}"
            notify_level="info";    notify_msg="$msg" ;;
    esac

    if [[ "${_TUI_ACTIVE:-false}" != "true" ]]; then
        if [[ "$level" == "header" ]]; then
            echo -e "\n${style}══════════════════════════════════════${NC:-}"
            echo -e "${style}  ${msg}${NC:-}"
            echo -e "${style}══════════════════════════════════════${NC:-}\n"
        else
            echo -e "${style}${prefix}${NC:-} ${msg}"
        fi
    elif [[ -n "${LOG_FILE:-}" ]]; then
        if [[ "$level" == "header" ]]; then
            printf '\n=== %s ===\n' "$(_tui_strip_ansi "$msg")" >> "$LOG_FILE" 2>/dev/null || true
        else
            printf '%s %s\n' "$prefix" "$(_tui_strip_ansi "$msg")" >> "$LOG_FILE" 2>/dev/null || true
        fi
    fi
    _tui_notify "$notify_level" "$notify_msg"
}

# --- Public out_* wrappers (new namespace) -----------------------------------
# Convenience wrappers for new code. Existing callers continue to use
# log/warn/error/success/mode_info/header in common.sh.
out_log()     { _out_emit info    "$*"; }
out_warn()    { _out_emit warn    "$*"; }
out_error()   { _out_emit error   "$*"; }
out_success() { _out_emit success "$*"; }
out_header()  { _out_emit header  "$*"; }

# out_complete VERDICT — signal end-of-run to the display layer.
# In TUI mode, delegates to tui_complete which flips complete=true in the
# JSON status (triggering the sidecar's hold-on-complete screen), then waits
# for Enter + tears the sidecar down. In CLI mode this is a no-op — the
# finalize banner already prints via out_ primitives.
out_complete() {
    local verdict="${1:-}"
    if declare -f tui_complete &>/dev/null; then
        tui_complete "$verdict"
    fi
}

# Initialise the context store at source time. Every entry point into the
# pipeline sources common.sh (which sources this file), so _OUT_CTX is
# guaranteed populated before any out_set_context / out_ctx caller runs.
out_init
