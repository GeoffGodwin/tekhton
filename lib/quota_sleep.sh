#!/usr/bin/env bash
# =============================================================================
# quota_sleep.sh — Chunked sleep helper for enter_quota_pause (M124)
#
# Sourced by lib/quota.sh — do not run directly. Replaces the single
# `sleep "${QUOTA_RETRY_INTERVAL}"` that previously made Ctrl-C unresponsive
# for up to QUOTA_RETRY_INTERVAL seconds and made the TUI countdown lag.
# =============================================================================
set -euo pipefail

# _quota_sleep_chunked TOTAL_SECS PAUSE_START
# Sleep TOTAL_SECS in QUOTA_SLEEP_CHUNK-second steps so SIGINT/SIGTERM is
# responsive within ~chunk seconds and so tui_update_pause can refresh
# the countdown on a sub-minute cadence. PAUSE_START is forwarded as the
# total-elapsed value passed into each tui_update_pause tick.
_quota_sleep_chunked() {
    local total="${1:-0}"
    local pause_start="${2:-0}"
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    local chunk="${QUOTA_SLEEP_CHUNK:-5}"
    [[ "$chunk" =~ ^[0-9]+$ ]] && [[ "$chunk" -gt 0 ]] || chunk=5
    local remaining="$total"
    while [[ "$remaining" -gt 0 ]]; do
        local step
        if [[ "$remaining" -lt "$chunk" ]]; then
            step="$remaining"
        else
            step="$chunk"
        fi
        sleep "$step"
        remaining=$(( remaining - step ))
        if command -v tui_update_pause &>/dev/null; then
            local _now _el=0
            _now=$(date +%s)
            [[ "$pause_start" -gt 0 ]] && _el=$(( _now - pause_start ))
            tui_update_pause "$remaining" "$_el" 2>/dev/null || true
        fi
    done
}
