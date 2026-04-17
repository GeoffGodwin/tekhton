#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# quota.sh — Quota management and rate-limit handling (Milestone 16)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: state.sh, common.sh sourced first.
# Expects: QUOTA_RETRY_INTERVAL, QUOTA_MAX_PAUSE_DURATION,
#          QUOTA_RESERVE_PCT, CLAUDE_QUOTA_CHECK_CMD (from config)
#
# Provides:
#   is_rate_limit_error     — detect rate-limit patterns in stderr
#   enter_quota_pause       — pause pipeline and wait for quota refresh
#   exit_quota_pause        — restore pipeline state after quota refresh
#   check_quota_remaining   — Tier 2: run external quota check command
#   should_pause_proactively — Tier 2: check if reserve threshold breached
# =============================================================================

# --- Quota pause state globals ------------------------------------------------
_QUOTA_PAUSE_COUNT=0
_QUOTA_TOTAL_PAUSE_TIME=0
_QUOTA_SAVED_ACTIVITY_TIMEOUT=""
_QUOTA_SAVED_AUTONOMOUS_REMAINING=""
_QUOTA_PAUSED=false

export _QUOTA_PAUSE_COUNT _QUOTA_TOTAL_PAUSE_TIME _QUOTA_PAUSED

# --- Rate limit detection (Tier 1: reactive) ---------------------------------

# is_rate_limit_error EXIT_CODE STDERR_FILE
# Returns 0 if stderr output contains rate-limit patterns, 1 otherwise.
# Uses broad case-insensitive regex for CLI version resilience.
is_rate_limit_error() {
    local exit_code="$1"
    local stderr_file="${2:-}"

    # Non-zero exit is a prerequisite
    if [[ "$exit_code" -eq 0 ]]; then
        return 1
    fi

    # Check stderr file for rate-limit patterns
    if [[ -n "$stderr_file" ]] && [[ -f "$stderr_file" ]] && [[ -s "$stderr_file" ]]; then
        if grep -qiE \
            'rate.?limit|quota.?exceed|usage.?limit|too.?many.?requests|429|capacity|overloaded|rate_limit_error' \
            "$stderr_file" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# --- Pause/resume state machine ----------------------------------------------

# enter_quota_pause
# Pauses pipeline execution and enters a retry loop waiting for quota refresh.
# Returns 0 when quota refreshes, 1 if max pause duration exceeded.
enter_quota_pause() {
    local pause_start
    pause_start=$(date +%s)
    _QUOTA_PAUSED=true
    _QUOTA_PAUSE_COUNT=$(( _QUOTA_PAUSE_COUNT + 1 ))
    local pause_reason="${1:-Rate limited}"

    # Save timeout state
    _QUOTA_SAVED_ACTIVITY_TIMEOUT="${AGENT_ACTIVITY_TIMEOUT:-600}"
    if [[ -n "${_ORCH_START_TIME:-}" ]]; then
        local elapsed=$(( $(date +%s) - _ORCH_START_TIME ))
        _QUOTA_SAVED_AUTONOMOUS_REMAINING=$(( ${AUTONOMOUS_TIMEOUT:-7200} - elapsed ))
    fi

    # Disable activity timeout during pause
    AGENT_ACTIVITY_TIMEOUT=0
    export AGENT_ACTIVITY_TIMEOUT

    # Write marker file for external visibility
    local marker_file="${PROJECT_DIR:-.}/.claude/QUOTA_PAUSED"
    mkdir -p "$(dirname "$marker_file")" 2>/dev/null || true
    {
        echo "paused_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "reason=${pause_reason}"
        echo "retry_interval=${QUOTA_RETRY_INTERVAL:-300}"
        echo "max_duration=${QUOTA_MAX_PAUSE_DURATION:-14400}"
    } > "$marker_file"

    # Log to Watchtower
    if command -v emit_event &>/dev/null; then
        emit_event "quota_pause" "pipeline" "${pause_reason}" \
            "" "" \
            "{\"pause_count\":${_QUOTA_PAUSE_COUNT},\"retry_interval\":${QUOTA_RETRY_INTERVAL:-300}}" \
            >/dev/null 2>&1 || true
    fi
    if command -v emit_dashboard_run_state &>/dev/null; then
        # shellcheck disable=SC2034
        WAITING_FOR="quota_refresh"
        emit_dashboard_run_state 2>/dev/null || true
    fi

    warn "Pipeline paused — ${pause_reason}. Waiting for quota refresh (checking every ${QUOTA_RETRY_INTERVAL:-300}s, max ${QUOTA_MAX_PAUSE_DURATION:-14400}s)."
    printf '\a' 2>/dev/null || true  # terminal bell

    # Retry loop
    local retry_count=0
    while true; do
        local elapsed=$(( $(date +%s) - pause_start ))
        if [[ "$elapsed" -ge "${QUOTA_MAX_PAUSE_DURATION:-14400}" ]]; then
            warn "Quota pause exceeded QUOTA_MAX_PAUSE_DURATION (${QUOTA_MAX_PAUSE_DURATION:-14400}s). Giving up."
            _finalize_quota_pause "$pause_start"
            _QUOTA_PAUSED=false
            rm -f "$marker_file" 2>/dev/null || true
            return 1
        fi

        log "Quota probe attempt $((retry_count + 1)) — sleeping ${QUOTA_RETRY_INTERVAL:-300}s..."
        sleep "${QUOTA_RETRY_INTERVAL:-300}"
        retry_count=$(( retry_count + 1 ))

        # Lightweight probe: minimal claude call to test quota
        if _quota_probe; then
            log "Quota refreshed after ${elapsed}s (${retry_count} probes)."
            _finalize_quota_pause "$pause_start"
            exit_quota_pause "$marker_file"
            return 0
        fi

        log "Quota still exhausted (probe ${retry_count}, ${elapsed}s elapsed)."
    done
}

# _quota_probe
# Lightweight single-turn claude call to test if quota has refreshed.
# Returns 0 if successful (quota available), 1 if still rate-limited.
_quota_probe() {
    local probe_stderr
    probe_stderr=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/quota_probe_XXXXXX.txt")

    local probe_exit=0
    # Minimal call — single turn, trivial prompt
    timeout 30 claude --max-turns 1 --output-format json \
        -p "respond with OK" \
        < /dev/null > /dev/null 2>"$probe_stderr" || probe_exit=$?

    local result=0
    if [[ "$probe_exit" -ne 0 ]]; then
        if is_rate_limit_error "$probe_exit" "$probe_stderr"; then
            result=1
        fi
        # Non-rate-limit errors mean quota may be available
    fi

    rm -f "$probe_stderr" 2>/dev/null || true
    return "$result"
}

# _finalize_quota_pause PAUSE_START
# Accumulates pause time into total.
_finalize_quota_pause() {
    local pause_start="$1"
    local pause_duration=$(( $(date +%s) - pause_start ))
    _QUOTA_TOTAL_PAUSE_TIME=$(( _QUOTA_TOTAL_PAUSE_TIME + pause_duration ))
}

# exit_quota_pause MARKER_FILE
# Restores pipeline state after quota refresh.
exit_quota_pause() {
    local marker_file="${1:-${PROJECT_DIR:-.}/.claude/QUOTA_PAUSED}"
    _QUOTA_PAUSED=false

    # Restore activity timeout
    if [[ -n "$_QUOTA_SAVED_ACTIVITY_TIMEOUT" ]]; then
        AGENT_ACTIVITY_TIMEOUT="$_QUOTA_SAVED_ACTIVITY_TIMEOUT"
        export AGENT_ACTIVITY_TIMEOUT
    fi

    # Restore autonomous timeout (remaining time, not full reset)
    if [[ -n "${_QUOTA_SAVED_AUTONOMOUS_REMAINING:-}" ]] && [[ -n "${_ORCH_START_TIME:-}" ]]; then
        # Adjust start time so remaining time is preserved
        local now
        now=$(date +%s)
        _ORCH_START_TIME=$(( now - (${AUTONOMOUS_TIMEOUT:-7200} - _QUOTA_SAVED_AUTONOMOUS_REMAINING) ))
    fi

    # Remove marker
    rm -f "$marker_file" 2>/dev/null || true

    # Log to Watchtower
    if command -v emit_event &>/dev/null; then
        emit_event "quota_resume" "pipeline" "Quota refreshed — resuming" \
            "" "" \
            "{\"pause_count\":${_QUOTA_PAUSE_COUNT},\"total_pause_time\":${_QUOTA_TOTAL_PAUSE_TIME}}" \
            >/dev/null 2>&1 || true
    fi
    if command -v emit_dashboard_run_state &>/dev/null; then
        # shellcheck disable=SC2034
        WAITING_FOR=""
        emit_dashboard_run_state 2>/dev/null || true
    fi

    success "Quota refreshed — resuming pipeline."
    printf '\a' 2>/dev/null || true  # terminal bell
}

# --- Proactive quota check (Tier 2: optional) --------------------------------

# check_quota_remaining
# Runs CLAUDE_QUOTA_CHECK_CMD if configured. Returns percentage remaining (0-100)
# on stdout, or empty string if not configured / failed.
check_quota_remaining() {
    local cmd="${CLAUDE_QUOTA_CHECK_CMD:-}"
    if [[ -z "$cmd" ]]; then
        echo ""
        return 0
    fi

    local result
    result=$(timeout 5 bash -c "$cmd" 2>/dev/null || echo "")

    # Validate: must be a number 0-100
    if [[ "$result" =~ ^[0-9]+$ ]] && [[ "$result" -ge 0 ]] && [[ "$result" -le 100 ]]; then
        echo "$result"
    else
        echo ""
    fi
}

# should_pause_proactively
# Returns 0 if proactive pause should trigger, 1 otherwise.
should_pause_proactively() {
    local remaining
    remaining=$(check_quota_remaining)

    if [[ -z "$remaining" ]]; then
        return 1  # Tier 2 not available
    fi

    if [[ "$remaining" -lt "${QUOTA_RESERVE_PCT:-10}" ]]; then
        return 0  # Below reserve threshold
    fi

    return 1
}

# --- Quota statistics for RUN_SUMMARY.json -----------------------------------

# get_quota_stats_json
# Returns JSON fragment with quota pause statistics.
get_quota_stats_json() {
    local was_limited="false"
    if [[ "$_QUOTA_PAUSE_COUNT" -gt 0 ]]; then
        was_limited="true"
    fi
    printf '{"total_pause_time_s":%d,"pause_count":%d,"was_quota_limited":%s}' \
        "$_QUOTA_TOTAL_PAUSE_TIME" "$_QUOTA_PAUSE_COUNT" "$was_limited"
}

# format_quota_pause_summary
# Returns human-readable quota pause summary for completion banner.
# Returns empty string if no pauses occurred.
format_quota_pause_summary() {
    if [[ "$_QUOTA_PAUSE_COUNT" -eq 0 ]]; then
        echo ""
        return 0
    fi

    local total_s="$_QUOTA_TOTAL_PAUSE_TIME"
    local mins=$(( total_s / 60 ))
    local secs=$(( total_s % 60 ))
    local time_str
    if [[ "$mins" -gt 0 ]]; then
        time_str="${mins}m ${secs}s"
    else
        time_str="${secs}s"
    fi

    echo "Quota pauses: ${_QUOTA_PAUSE_COUNT} (total wait: ${time_str})"
}
