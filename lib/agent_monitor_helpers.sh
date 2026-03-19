#!/usr/bin/env bash
# =============================================================================
# agent_monitor_helpers.sh — Post-invocation monitoring helpers
#
# Extracted from agent_monitor.sh. Provides file-change detection and monitoring
# state reset. Sourced by agent.sh after agent_monitor.sh (depends on
# _kill_agent_windows from agent_monitor_platform.sh and _TEKHTON_AGENT_PID
# from agent_monitor.sh).
# =============================================================================
set -euo pipefail

# --- Monitoring state reset (13.1) -------------------------------------------
# Cleans up FIFO, temp files, and resets API error flags between retry attempts.
# Safe to call even when no prior monitoring state exists.
#
# Usage: _reset_monitoring_state SESSION_DIR

_reset_monitoring_state() {
    local session_dir="${1:?_reset_monitoring_state requires session_dir}"

    # Kill any lingering FIFO reader subshell
    if [[ -n "${_TEKHTON_AGENT_PID:-}" ]]; then
        kill "$_TEKHTON_AGENT_PID" 2>/dev/null || true
        kill -9 "$_TEKHTON_AGENT_PID" 2>/dev/null || true
        _kill_agent_windows
        _TEKHTON_AGENT_PID=""
    fi

    # Remove stale FIFO and temp files (guard with existence checks)
    rm -f "${session_dir}/agent_fifo_"* 2>/dev/null || true
    rm -f "${session_dir}/agent_stderr.txt" 2>/dev/null || true
    rm -f "${session_dir}/agent_last_output.txt" 2>/dev/null || true
    rm -f "${session_dir}/agent_api_error.txt" 2>/dev/null || true
    rm -f "${session_dir}/agent_exit" 2>/dev/null || true
    rm -f "${session_dir}/agent_last_turns" 2>/dev/null || true

    # Reset API error detection flags
    _API_ERROR_DETECTED=false
    _API_ERROR_TYPE=""

    # Reset activity timestamps (touch a fresh marker if activity_marker exists)
    if [[ -f "${session_dir}/activity_marker" ]]; then
        touch "${session_dir}/activity_marker"
    fi
}

# --- File-change detection helpers (FIFO loop + null-run detection) -----------

# _detect_file_changes — 0 if files changed since marker, 1 otherwise.
_detect_file_changes() {
    local marker="$1"
    local project_dir="${PROJECT_DIR:-.}"
    local log_dir="${LOG_DIR:-${project_dir}/.claude/logs}"

    # Exclude .git, session temp, and log dir. Limit to 1 match.
    local changed
    changed=$(find "$project_dir" -maxdepth "$AGENT_FILE_SCAN_DEPTH" -newer "$marker" \
        -not -path '*/.git/*' \
        -not -path '*/.git' \
        -not -path "${TEKHTON_SESSION_DIR:-/nonexistent}/*" \
        -not -path "${log_dir}/*" \
        -type f 2>/dev/null | head -1)

    if [ -n "$changed" ]; then
        return 0
    fi
    return 1
}

# _count_changed_files_since — count of files modified since marker timestamp.
_count_changed_files_since() {
    local marker="$1"
    local project_dir="${PROJECT_DIR:-.}"
    local log_dir="${LOG_DIR:-${project_dir}/.claude/logs}"
    local count
    count=$(find "$project_dir" -maxdepth "$AGENT_FILE_SCAN_DEPTH" -newer "$marker" \
        -not -path '*/.git/*' \
        -not -path '*/.git' \
        -not -path "${TEKHTON_SESSION_DIR:-/nonexistent}/*" \
        -not -path "${log_dir}/*" \
        -type f 2>/dev/null | count_lines)
    echo "${count:-0}"
}
