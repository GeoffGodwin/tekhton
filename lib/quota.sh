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

# enter_quota_pause REASON [RETRY_AFTER_SECONDS]
# Pauses pipeline execution and enters a retry loop waiting for quota refresh.
# When RETRY_AFTER_SECONDS is supplied (M125), the first probe is scheduled at
# that delay (clamped to [QUOTA_PROBE_MIN_INTERVAL, QUOTA_MAX_PAUSE_DURATION])
# instead of QUOTA_RETRY_INTERVAL. Subsequent probes use mild exponential
# back-off with jitter (see _quota_next_probe_delay).
# Returns 0 when quota refreshes, 1 if max pause duration exceeded.
enter_quota_pause() {
    local pause_start
    pause_start=$(date +%s)
    _QUOTA_PAUSED=true
    _QUOTA_PAUSE_COUNT=$(( _QUOTA_PAUSE_COUNT + 1 ))
    local pause_reason="${1:-Rate limited}"
    local retry_after="${2:-}"
    local max_dur="${QUOTA_MAX_PAUSE_DURATION:-18900}"
    local floor="${QUOTA_PROBE_MIN_INTERVAL:-600}"
    local base_interval="${QUOTA_RETRY_INTERVAL:-300}"

    # Clamp retry_after into [floor, max_dur]. Empty/non-numeric → use base.
    local first_delay="$base_interval"
    if [[ -n "$retry_after" ]] && [[ "$retry_after" =~ ^[0-9]+$ ]]; then
        first_delay="$retry_after"
        [[ "$first_delay" -lt "$floor" ]] && first_delay="$floor"
        [[ "$first_delay" -gt "$max_dur" ]] && first_delay="$max_dur"
        log "Anthropic said retry in $(_quota_fmt_duration "$retry_after") — waiting that long before first probe."
    fi

    # Save timeout state
    _QUOTA_SAVED_ACTIVITY_TIMEOUT="${AGENT_ACTIVITY_TIMEOUT:-600}"
    if [[ -n "${_ORCH_START_TIME:-}" ]]; then
        local elapsed=$(( $(date +%s) - _ORCH_START_TIME ))
        _QUOTA_SAVED_AUTONOMOUS_REMAINING=$(( ${AUTONOMOUS_TIMEOUT:-7200} - elapsed ))
    fi

    AGENT_ACTIVITY_TIMEOUT=0
    export AGENT_ACTIVITY_TIMEOUT

    local marker_file="${PROJECT_DIR:-.}/.claude/QUOTA_PAUSED"
    mkdir -p "$(dirname "$marker_file")" 2>/dev/null || true
    {
        echo "paused_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "reason=${pause_reason}"
        echo "retry_interval=${base_interval}"
        echo "max_duration=${max_dur}"
        echo "first_probe_delay=${first_delay}"
    } > "$marker_file"

    if command -v emit_event &>/dev/null; then
        emit_event "quota_pause" "pipeline" "${pause_reason}" \
            "" "" \
            "{\"pause_count\":${_QUOTA_PAUSE_COUNT},\"retry_interval\":${base_interval},\"first_probe_delay\":${first_delay}}" \
            >/dev/null 2>&1 || true
    fi
    if command -v emit_dashboard_run_state &>/dev/null; then
        # shellcheck disable=SC2034
        WAITING_FOR="quota_refresh"
        emit_dashboard_run_state 2>/dev/null || true
    fi

    # M124/M125: surface the pause to the TUI sidecar. first_probe_delay is
    # passed as the 4th argument so the countdown starts at the Retry-After-
    # informed value rather than the default interval.
    if command -v tui_enter_pause &>/dev/null; then
        tui_enter_pause "${pause_reason}" "$base_interval" "$max_dur" "$first_delay" \
            2>/dev/null || true
    fi

    warn "Pipeline paused — ${pause_reason}. Waiting up to $(_quota_fmt_duration "$max_dur") for quota refresh (probing every $(_quota_fmt_duration "$base_interval"))."
    printf '\a' 2>/dev/null || true  # terminal bell

    local retry_count=0
    local probe_delay="$first_delay"
    while true; do
        local elapsed=$(( $(date +%s) - pause_start ))
        if [[ "$elapsed" -ge "$max_dur" ]]; then
            warn "Quota pause exceeded QUOTA_MAX_PAUSE_DURATION ($(_quota_fmt_duration "$max_dur")). Giving up."
            _finalize_quota_pause "$pause_start"
            _QUOTA_PAUSED=false
            rm -f "$marker_file" 2>/dev/null || true
            if command -v tui_exit_pause &>/dev/null; then
                tui_exit_pause "timeout" 2>/dev/null || true
            fi
            return 1
        fi

        log "Quota probe attempt $((retry_count + 1)) — sleeping $(_quota_fmt_duration "$probe_delay")..."
        if command -v tui_update_pause &>/dev/null; then
            tui_update_pause "$probe_delay" "$elapsed" 2>/dev/null || true
        fi
        _quota_sleep_chunked "$probe_delay" "$pause_start"
        retry_count=$(( retry_count + 1 ))

        if _quota_probe; then
            elapsed=$(( $(date +%s) - pause_start ))
            log "Quota refreshed after $(_quota_fmt_duration "$elapsed") (${retry_count} probes)."
            _finalize_quota_pause "$pause_start"
            exit_quota_pause "$marker_file"
            if command -v tui_exit_pause &>/dev/null; then
                tui_exit_pause "refreshed" 2>/dev/null || true
            fi
            return 0
        fi

        log "Quota still exhausted (probe ${retry_count}, $(_quota_fmt_duration "$elapsed") elapsed)."
        probe_delay=$(_quota_next_probe_delay $(( retry_count + 1 )) "$probe_delay")
    done
}

# Chunked-sleep helper lives in quota_sleep.sh (M124).
# shellcheck source=lib/quota_sleep.sh
source "${TEKHTON_HOME}/lib/quota_sleep.sh"

# Layered probe + back-off helpers (M125).
# shellcheck source=lib/quota_probe.sh
source "${TEKHTON_HOME}/lib/quota_probe.sh"

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
