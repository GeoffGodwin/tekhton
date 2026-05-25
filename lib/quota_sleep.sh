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
# responsive within ~chunk seconds and so the pause countdown can refresh
# on a sub-minute cadence. PAUSE_START is the original wall-clock start of
# the pause; passed for completeness but the Go side computes elapsed
# itself from the JSON state.
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
        if declare -f _tui_call &>/dev/null; then
            _tui_call pause-update --next-in "$remaining"
        fi
    done
    # pause_start is accepted for caller compatibility; intentionally unused.
    : "$pause_start"
}
