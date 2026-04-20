#!/usr/bin/env bash
# =============================================================================
# agent_retry.sh — Transient error retry envelope (13.2.1)
#
# Sourced by agent.sh — do not run directly.
# Wraps _invoke_and_monitor in a retry loop with error classification and
# exponential backoff. Sets globals for run_agent() to consume:
#   AGENT_ERROR_CATEGORY, AGENT_ERROR_SUBCATEGORY, AGENT_ERROR_TRANSIENT,
#   AGENT_ERROR_MESSAGE, LAST_AGENT_RETRY_COUNT,
#   _RWR_EXIT, _RWR_TURNS, _RWR_WAS_ACTIVITY_TIMEOUT
#
# Expects: classify_error(), report_retry(), _reset_monitoring_state(),
#          _invoke_and_monitor(), and common.sh functions (log, warn)
# =============================================================================
set -euo pipefail

# _run_with_retry LABEL INVOKE_CMD MODEL MAX_TURNS PROMPT LOG_FILE ACTIVITY_TIMEOUT SESSION_DIR EXIT_FILE TURNS_FILE PRERUN_MARKER WALL_TIMEOUT
# Main retry envelope. Invokes agent and retries on transient errors with exponential backoff.
_run_with_retry() {
    local label="$1"
    local invoke_cmd="$2"
    local model="$3"
    local max_turns="$4"
    local prompt="$5"
    local log_file="$6"
    local activity_timeout="$7"
    local session_dir="$8"
    local exit_file="$9"
    local turns_file="${10}"
    local prerun_marker="${11}"
    local wall_timeout="${12}"

    LAST_AGENT_RETRY_COUNT=0
    local _retry_attempt=0
    _RWR_EXIT=0
    _RWR_WAS_ACTIVITY_TIMEOUT=false
    _RWR_TURNS=0

    while true; do
        # Reset error classification for this attempt
        AGENT_ERROR_CATEGORY=""
        AGENT_ERROR_SUBCATEGORY=""
        AGENT_ERROR_TRANSIENT=""
        AGENT_ERROR_MESSAGE=""

        _invoke_and_monitor "$invoke_cmd" "$model" "$max_turns" "$prompt" \
            "$log_file" "$activity_timeout" "$session_dir" "$exit_file" "$turns_file"

        _RWR_EXIT="$_MONITOR_EXIT_CODE"
        _RWR_WAS_ACTIVITY_TIMEOUT="$_MONITOR_WAS_ACTIVITY_TIMEOUT"

        trap - INT TERM

        # Extract turn count (needed for error classification below)
        _RWR_TURNS=$(cat "$turns_file" 2>/dev/null || echo "0")
        [[ "$_RWR_TURNS" =~ ^[0-9]+$ ]] || _RWR_TURNS=0

        if [ "$_RWR_EXIT" -ne 0 ]; then
            if [ "$_RWR_EXIT" -eq 124 ]; then
                if [ "$_RWR_WAS_ACTIVITY_TIMEOUT" = true ]; then
                    warn "[$label] ACTIVITY TIMEOUT — agent produced no output for ${activity_timeout}s."
                    warn "[$label] This usually means claude hung on an API call or entered a retry loop."
                    warn "[$label] Set AGENT_ACTIVITY_TIMEOUT in pipeline.conf to change (0 = disable)."
                else
                    warn "[$label] TIMEOUT — agent did not complete within ${wall_timeout}s. Set AGENT_TIMEOUT in pipeline.conf to change."
                fi
            else
                warn "[$label] claude exited with code ${_RWR_EXIT} (may indicate turn limit or error)"
            fi
        fi

        # --- Rate limit detection (M16) — check before error classification ---
        # Rate limits get the full pause/resume treatment, not transient retry.
        if command -v is_rate_limit_error &>/dev/null; then
            local _stderr_path="${session_dir}/agent_stderr.txt"
            if is_rate_limit_error "$_RWR_EXIT" "$_stderr_path"; then
                if command -v enter_quota_pause &>/dev/null; then
                    warn "[$label] Rate limit detected — entering quota pause."
                    if enter_quota_pause "Rate limited (agent: ${label})"; then
                        # Quota refreshed — retry without incrementing counter
                        _reset_monitoring_state "$session_dir"
                        rm -f "$exit_file" "$turns_file"
                        continue
                    else
                        # Quota pause timed out — treat as fatal
                        # shellcheck disable=SC2034
                        AGENT_ERROR_CATEGORY="UPSTREAM"
                        # shellcheck disable=SC2034
                        AGENT_ERROR_SUBCATEGORY="quota_exhausted"
                        # shellcheck disable=SC2034
                        AGENT_ERROR_TRANSIENT="false"
                        # shellcheck disable=SC2034
                        AGENT_ERROR_MESSAGE="Quota pause exceeded max duration"
                        break
                    fi
                fi
            fi
        fi

        # --- Proactive quota check (Tier 2, M16) -----------------------------
        if command -v should_pause_proactively &>/dev/null; then
            if should_pause_proactively; then
                local _remaining
                _remaining=$(check_quota_remaining)
                warn "[$label] Quota at ${_remaining}% — below reserve threshold. Entering proactive pause."
                if enter_quota_pause "Paused at ${_remaining}% remaining (reserve threshold)"; then
                    # Continue to error classification — the current call may have succeeded
                    true
                fi
            fi
        fi

        # --- Error classification (12.2) --------------------------------------
        _classify_agent_exit "$_RWR_EXIT" "$session_dir" "$prerun_marker" "$_RWR_TURNS"

        # --- Transient retry check (13.2.1) -----------------------------------
        if _should_retry_transient "$label" "$_retry_attempt" "$session_dir" \
            "$exit_file" "$turns_file"; then
            _retry_attempt=$(( _retry_attempt + 1 ))
            # shellcheck disable=SC2034  # used by run_agent() to track retry count
            LAST_AGENT_RETRY_COUNT=$_retry_attempt
            continue
        fi

        break
    done
}

# _classify_agent_exit EXIT SESSION_DIR PRERUN_MARKER TURNS
# Runs classify_error and sets AGENT_ERROR_* globals.
_classify_agent_exit() {
    local agent_exit="$1"
    local session_dir="$2"
    local prerun_marker="$3"
    local turns_used="$4"

    if [[ "$agent_exit" -ne 0 ]] || [[ "$_API_ERROR_DETECTED" = true ]]; then
        # classify_error is from lib/errors.sh — guard for tests that source agent.sh directly
        if command -v classify_error &>/dev/null; then
            local _stderr_file="${session_dir}/agent_stderr.txt"
            local _last_output_file="${session_dir}/agent_last_output.txt"
            local _fc=0
            if [[ -f "$prerun_marker" ]] && _detect_file_changes "$prerun_marker"; then
                _fc=$(_count_changed_files_since "$prerun_marker")
            fi

            # If API error was detected in stream but stderr file is still empty
            if [[ "$_API_ERROR_DETECTED" = true ]] && [[ ! -s "$_stderr_file" ]]; then
                echo "API error detected in stream: ${_API_ERROR_TYPE}" > "$_stderr_file"
            fi

            # Check for ${CODER_SUMMARY_FILE} presence
            local _has_summary_flag=0
            local _summary_check_path="${PROJECT_DIR:-.}/${CODER_SUMMARY_FILE}"
            if [[ -f "$_summary_check_path" ]] && [[ -f "$prerun_marker" ]] \
                && [[ "$_summary_check_path" -nt "$prerun_marker" ]]; then
                _has_summary_flag=1
            fi

            local _error_record
            _error_record=$(classify_error "$agent_exit" "$_stderr_file" "$_last_output_file" "$_fc" "$turns_used" "$_has_summary_flag")

            # shellcheck disable=SC2034
            AGENT_ERROR_CATEGORY=$(echo "$_error_record" | cut -d'|' -f1)
            # shellcheck disable=SC2034
            AGENT_ERROR_SUBCATEGORY=$(echo "$_error_record" | cut -d'|' -f2)
            # shellcheck disable=SC2034
            AGENT_ERROR_TRANSIENT=$(echo "$_error_record" | cut -d'|' -f3)
            # shellcheck disable=SC2034
            AGENT_ERROR_MESSAGE=$(echo "$_error_record" | cut -d'|' -f4-)
        fi
    fi
}

# _should_retry_transient LABEL ATTEMPT SESSION_DIR EXIT_FILE TURNS_FILE
# Returns 0 (true) if a retry should occur (after sleeping), 1 otherwise.
_should_retry_transient() {
    local label="$1"
    local retry_attempt="$2"
    local session_dir="$3"
    local exit_file="$4"
    local turns_file="$5"

    if [[ "${TRANSIENT_RETRY_ENABLED:-true}" != true ]]; then
        return 1
    fi
    if [[ "$AGENT_ERROR_TRANSIENT" != "true" ]]; then
        return 1
    fi
    if [[ "$retry_attempt" -ge "${MAX_TRANSIENT_RETRIES:-3}" ]]; then
        return 1
    fi

    local _next_attempt=$(( retry_attempt + 1 ))

    # Exponential backoff: base * 2^(attempt-1), capped at max
    local _delay="${TRANSIENT_RETRY_BASE_DELAY:-30}"
    local _exp=$(( _next_attempt - 1 ))
    local _i=0
    while [[ "$_i" -lt "$_exp" ]]; do
        _delay=$(( _delay * 2 ))
        _i=$(( _i + 1 ))
    done
    if [[ "$_delay" -gt "${TRANSIENT_RETRY_MAX_DELAY:-120}" ]]; then
        _delay="${TRANSIENT_RETRY_MAX_DELAY:-120}"
    fi

    # Subcategory-specific minimum delays
    case "${AGENT_ERROR_SUBCATEGORY}" in
        api_rate_limit)
            local _retry_after=""
            if [[ -f "${session_dir}/agent_last_output.txt" ]]; then
                _retry_after=$(grep -oiE '"retry.after"[[:space:]]*:[[:space:]]*"?[0-9]+"?' \
                    "${session_dir}/agent_last_output.txt" 2>/dev/null \
                    | grep -oE '[0-9]+' | head -1)
            fi
            if [[ -n "${_retry_after:-}" ]] && [[ "$_retry_after" -gt "$_delay" ]] 2>/dev/null; then
                _delay="$_retry_after"
            elif [[ "$_delay" -lt 60 ]]; then
                _delay=60
            fi
            ;;
        api_overloaded)
            [[ "$_delay" -lt 60 ]] && _delay=60
            ;;
        oom)
            # Use exponential backoff with 15s floor (instead of flat 15s)
            [[ "$_delay" -lt 15 ]] && _delay=15
            ;;
    esac

    report_retry "$_next_attempt" "${MAX_TRANSIENT_RETRIES:-3}" \
        "${AGENT_ERROR_SUBCATEGORY}" "$_delay"
    log "[$label] Sleeping ${_delay}s before retry attempt ${_next_attempt}/${MAX_TRANSIENT_RETRIES:-3}..."
    sleep "$_delay"

    # Clean up monitoring state for the next attempt
    _reset_monitoring_state "$session_dir"
    rm -f "$exit_file" "$turns_file"

    return 0
}
