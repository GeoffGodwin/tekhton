#!/usr/bin/env bash
# =============================================================================
# stages/tester_timing.sh — Tester timing globals and parsing (M62)
#
# Extracted from stages/tester.sh to stay under the 300-line ceiling.
# Sourced by tester.sh — do not run directly.
# =============================================================================

set -euo pipefail

# --- Tester timing globals (M62) ---
# These are accumulated across continuations and consumed by finalize_summary.sh.
_TESTER_TIMING_EXEC_COUNT=-1
_TESTER_TIMING_EXEC_APPROX_S=-1
_TESTER_TIMING_FILES_WRITTEN=-1
_TESTER_TIMING_WRITING_S=-1

# _parse_tester_timing — Extract timing data from TESTER_REPORT.md.
# Reads the ## Timing section and populates _TESTER_TIMING_* globals.
# If section is missing or unparseable, values remain -1.
# Args: $1 = path to TESTER_REPORT.md (default: TESTER_REPORT.md)
#       $2 = "accumulate" to add to existing values (for continuations)
_parse_tester_timing() {
    local report="${1:-TESTER_REPORT.md}"
    local mode="${2:-replace}"

    [[ -f "$report" ]] || return 0

    # Extract the ## Timing section (must be at end of file per milestone spec)
    local timing_block
    timing_block=$(sed -n '/^## Timing$/,$ p' "$report" 2>/dev/null || true)
    [[ -n "$timing_block" ]] || return 0

    # Parse each field with defensive regex
    local _exec_count _exec_time _files_written
    _exec_count=$(echo "$timing_block" | grep -oiE 'Test executions:\s*([0-9]+)' | grep -oE '[0-9]+' | tail -1 || true)
    _exec_time=$(echo "$timing_block" | grep -oiE 'Approximate total test execution time:\s*~?([0-9]+)' | grep -oE '[0-9]+' | tail -1 || true)
    _files_written=$(echo "$timing_block" | grep -oiE 'Test files written:\s*([0-9]+)' | grep -oE '[0-9]+' | tail -1 || true)

    # Validate: must be numeric
    [[ "$_exec_count" =~ ^[0-9]+$ ]] || _exec_count=""
    [[ "$_exec_time" =~ ^[0-9]+$ ]] || _exec_time=""
    [[ "$_files_written" =~ ^[0-9]+$ ]] || _files_written=""

    if [[ "$mode" == "accumulate" ]]; then
        # Accumulate: add to running totals (only if current value is valid)
        if [[ -n "$_exec_count" ]]; then
            if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq -1 ]]; then
                _TESTER_TIMING_EXEC_COUNT="$_exec_count"
            else
                _TESTER_TIMING_EXEC_COUNT=$(( _TESTER_TIMING_EXEC_COUNT + _exec_count ))
            fi
        fi
        if [[ -n "$_exec_time" ]]; then
            if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq -1 ]]; then
                _TESTER_TIMING_EXEC_APPROX_S="$_exec_time"
            else
                _TESTER_TIMING_EXEC_APPROX_S=$(( _TESTER_TIMING_EXEC_APPROX_S + _exec_time ))
            fi
        fi
        if [[ -n "$_files_written" ]]; then
            if [[ "$_TESTER_TIMING_FILES_WRITTEN" -eq -1 ]]; then
                _TESTER_TIMING_FILES_WRITTEN="$_files_written"
            else
                _TESTER_TIMING_FILES_WRITTEN=$(( _TESTER_TIMING_FILES_WRITTEN + _files_written ))
            fi
        fi
    else
        # Replace mode: set values (or leave as -1 if unparseable)
        if [[ -n "$_exec_count" ]]; then _TESTER_TIMING_EXEC_COUNT="$_exec_count"; fi
        if [[ -n "$_exec_time" ]]; then _TESTER_TIMING_EXEC_APPROX_S="$_exec_time"; fi
        if [[ -n "$_files_written" ]]; then _TESTER_TIMING_FILES_WRITTEN="$_files_written"; fi
    fi
}

# _compute_tester_writing_time — Compute approximate writing time.
# Returns: writing time in seconds, or -1 if unavailable.
# Uses total tester agent duration minus reported execution time.
_compute_tester_writing_time() {
    local agent_duration="${1:-0}"
    if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -gt 0 ]] && [[ "$agent_duration" -gt 0 ]]; then
        local writing_s=$(( agent_duration - _TESTER_TIMING_EXEC_APPROX_S ))
        # Clamp to zero — agent estimates can exceed actual wall time
        [[ "$writing_s" -lt 0 ]] && writing_s=0
        echo "$writing_s"
    else
        echo "-1"
    fi
}
