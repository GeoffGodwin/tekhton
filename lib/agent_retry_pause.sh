#!/usr/bin/env bash
# =============================================================================
# agent_retry_pause.sh — Spinner pause/resume bracket for quota pauses (M124)
#
# Sourced by agent_retry.sh — do not run directly. Contains the helpers that
# stop the agent spinner subshell before enter_quota_pause is called and
# restart it once the pause completes, rewriting the caller's spinner-pid
# locals via nameref so the trailing _stop_agent_spinner sees the new
# generation.
# =============================================================================
set -euo pipefail

# _enter_qp_rate LABEL [RETRY_AFTER] — invoke enter_quota_pause for a
# rate-limit. Wrapper kept tiny so _retry_pause_spinner_around_quota is the
# single place where spinner pause/resume bracketing lives. M125 threads
# Retry-After through as the second arg when present.
_enter_qp_rate() {
    local label="$1"; shift
    local retry_after="${1:-}"
    enter_quota_pause "Rate limited (agent: ${label})" "$retry_after"
}

# _enter_qp_proactive LABEL REMAINING — proactive Tier-2 pause variant.
_enter_qp_proactive() {
    local label="$1"; shift
    local remaining="$1"
    enter_quota_pause "Paused at ${remaining}% remaining (reserve threshold)"
}

# _retry_pause_spinner_around_quota CALLBACK LABEL MAX_TURNS TURNS_FILE \
#                                   SPINNER_VAR TUI_VAR [CB_ARGS...]
# Stops the spinner subshell, invokes CALLBACK (which calls
# enter_quota_pause), then restarts the spinner and rewrites the caller's
# nameref vars (SPINNER_VAR / TUI_VAR — variable NAMES, not values) so
# their _stop_agent_spinner call kills the new generation. Sets
# _RETRY_QP_RC to the callback's exit code. Safe when the spinner module
# is not loaded (test harnesses) — pause/resume become no-ops.
_retry_pause_spinner_around_quota() {
    local callback="$1"
    local label="$2"
    local max_turns="$3"
    local turns_file="$4"
    local spinner_var="$5"
    local tui_var="$6"
    shift 6

    local _sp="" _tp=""
    if [[ -n "$spinner_var" ]] && declare -p "$spinner_var" &>/dev/null; then
        local -n _sp_ref="$spinner_var"
        _sp="${_sp_ref:-}"
    fi
    if [[ -n "$tui_var" ]] && declare -p "$tui_var" &>/dev/null; then
        local -n _tp_ref="$tui_var"
        _tp="${_tp_ref:-}"
    fi

    if declare -f _pause_agent_spinner &>/dev/null; then
        _pause_agent_spinner "$_sp" "$_tp"
    fi
    if [[ -n "$spinner_var" ]] && declare -p "$spinner_var" &>/dev/null; then
        local -n _sp_ref2="$spinner_var"
        _sp_ref2=""
    fi
    if [[ -n "$tui_var" ]] && declare -p "$tui_var" &>/dev/null; then
        local -n _tp_ref2="$tui_var"
        _tp_ref2=""
    fi

    _RETRY_QP_RC=0
    "$callback" "$label" "$@" || _RETRY_QP_RC=$?

    if [[ "$_RETRY_QP_RC" -eq 0 ]] \
       && declare -f _resume_agent_spinner &>/dev/null; then
        local _new_pids _new_sp="" _new_tp=""
        _new_pids=$(_resume_agent_spinner "$label" "$turns_file" "$max_turns") || true
        IFS=: read -r _new_sp _new_tp <<<"$_new_pids"
        if [[ -n "$spinner_var" ]] && declare -p "$spinner_var" &>/dev/null; then
            local -n _sp_ref3="$spinner_var"
            _sp_ref3="$_new_sp"
        fi
        if [[ -n "$tui_var" ]] && declare -p "$tui_var" &>/dev/null; then
            local -n _tp_ref3="$tui_var"
            _tp_ref3="$_new_tp"
        fi
    fi
}
