#!/usr/bin/env bash
# =============================================================================
# agent.sh — m10 supervisor shim. Builds an agent.request.v1 envelope, calls
# `tekhton supervise --request-file`, and shapes the agent.response.v1 reply
# back into the V3 globals (LAST_AGENT_*, AGENT_ERROR_*) the rest of the bash
# tree still reads. m12 (Phase 4) deleted the round-trip orchestrate-globals
# pair (formerly the {EXIT,TURNS,WAS_ACTIVITY_TIMEOUT} tuple) — the orchestrate
# loop now reads the supervisor result through the LAST_AGENT_* names directly.
# The retry envelope, quota pause, fsnotify override, Windows reaper, and
# process-tree cleanup all moved to internal/supervisor in m05–m09; m10 deleted
# the bash supervisor outright (lib/agent_monitor*.sh, lib/agent_retry*.sh).
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TOTAL_TURNS, TOTAL_TIME, STAGE_SUMMARY (set by caller), log/warn
# from common.sh, _json_escape from common.sh.
# =============================================================================
set -euo pipefail

# shellcheck source=lib/agent_shim.sh
source "${TEKHTON_HOME}/lib/agent_shim.sh"
# shellcheck source=lib/agent_helpers.sh
source "${TEKHTON_HOME}/lib/agent_helpers.sh"
# shellcheck source=lib/agent_spinner.sh
source "${TEKHTON_HOME}/lib/agent_spinner.sh"

run_agent() {
    local label="$1" model="$2" max_turns="$3" prompt="$4" log_file="$5"
    local _allowed_tools="${6:-$AGENT_TOOLS_CODER}"  # V3 contract
    : "$_allowed_tools"

    if ! [[ "$max_turns" =~ ^[0-9]+$ ]]; then
        warn "[$label] max_turns not numeric ('${max_turns:0:40}'); using ${CODER_MAX_TURNS:-100}"
        max_turns="${CODER_MAX_TURNS:-100}"
    fi
    TOTAL_AGENT_INVOCATIONS=$(( TOTAL_AGENT_INVOCATIONS + 1 ))

    local _bin
    if ! _bin=$(_shim_resolve_binary); then
        warn "[$label] tekhton binary not found on PATH or in TEKHTON_HOME/bin — agent cannot run."
        # shellcheck disable=SC2034  # consumed by orchestrate.sh + downstream stages
        LAST_AGENT_EXIT_CODE=127
        # shellcheck disable=SC2034
        LAST_AGENT_TURNS=0
        # shellcheck disable=SC2034
        LAST_AGENT_NULL_RUN=true
        # shellcheck disable=SC2034
        AGENT_ERROR_CATEGORY="PIPELINE"
        # shellcheck disable=SC2034
        AGENT_ERROR_MESSAGE="tekhton binary missing"
        return
    fi

    local _sd="${TEKHTON_SESSION_DIR:-/tmp}"
    mkdir -p "$_sd"
    local _pf="${_sd}/agent_prompt_$$.txt"
    local _rf="${_sd}/agent_request_$$.json"
    local _zf="${_sd}/agent_response_$$.json"
    local _tf="${_sd}/agent_last_turns"
    printf '0' > "$_tf"
    printf '%s' "$prompt" > "$_pf"
    _shim_write_request "$_rf" "${RUN_ID:-}" "$label" "$model" "$max_turns" \
        "$_pf" "${PROJECT_DIR:-$PWD}" \
        "${AGENT_TIMEOUT:-7200}" "${AGENT_ACTIVITY_TIMEOUT:-600}"

    local _start; _start=$(date +%s)
    local _spinner_pid="" _tui_updater_pid=""
    IFS=: read -r _spinner_pid _tui_updater_pid \
        < <(_start_agent_spinner "$label" "$_tf" "$max_turns")

    set +o pipefail
    "$_bin" supervise --request-file "$_rf" > "$_zf" 2>>"$log_file"
    local _exec_rc=$?
    set -o pipefail
    _stop_agent_spinner "$_spinner_pid" "$_tui_updater_pid"

    _shim_apply_response "$_zf" "$_exec_rc"
    printf '%s' "$LAST_AGENT_TURNS" > "$_tf"

    local _end; _end=$(date +%s)
    LAST_AGENT_ELAPSED=$(( _end - _start ))
    local _m=$(( LAST_AGENT_ELAPSED / 60 )) _s=$(( LAST_AGENT_ELAPSED % 60 ))
    TOTAL_TURNS=$(( TOTAL_TURNS + LAST_AGENT_TURNS ))
    TOTAL_TIME=$(( TOTAL_TIME + LAST_AGENT_ELAPSED ))
    log "[$label] Turns: ${LAST_AGENT_TURNS}/${max_turns} | Time: ${_m}m${_s}s"
    STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label} (${model}): ${LAST_AGENT_TURNS}/${max_turns} turns, ${_m}m${_s}s"
    _append_agent_summary "$label" "$model" "$LAST_AGENT_TURNS" "$max_turns" \
        "$_m" "$_s" "$LAST_AGENT_EXIT_CODE" "0" "$log_file"
    rm -f "$_pf" "$_rf" "$_zf"
}
