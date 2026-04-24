#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# common_timing.sh — Phase timing helpers (M46)
#
# Extracted from common.sh to keep that file under the 300-line ceiling.
# Sourced by common.sh — do not run directly.
# Provides: _get_epoch_secs, _phase_start, _phase_end, _get_phase_duration,
#           _format_duration_human
# Exposes:  _PHASE_STARTS, _PHASE_TIMINGS (associative arrays)
#
# Per-phase wall-clock instrumentation. All functions are safe to call at
# top-level scope (no subshell issues).
#
# Usage:
#   _phase_start "build_gate_analyze"
#   ... do work ...
#   _phase_end "build_gate_analyze"
#   dur=$(_get_phase_duration "build_gate_analyze")
# =============================================================================

declare -gA _PHASE_STARTS=()    # epoch seconds (start timestamp per phase)
declare -gA _PHASE_TIMINGS=()   # elapsed seconds per completed phase

# _get_epoch_secs — returns current epoch seconds.
# Uses date +%s (universally available). Nanosecond precision is not needed
# for phase-level instrumentation where phases are >= 1 second.
_get_epoch_secs() {
    date +%s
}

# _phase_start NAME — records the start time for a named phase.
# Overwrites any previous start for the same name (allows re-use).
_phase_start() {
    local name="$1"
    _PHASE_STARTS[$name]=$(_get_epoch_secs)
}

# _phase_end NAME — records the end time and computes duration.
# If _phase_start was never called for NAME, logs a warning and returns.
# Accumulates into _PHASE_TIMINGS (does NOT overwrite — adds to existing).
_phase_end() {
    local name="$1"
    local start="${_PHASE_STARTS[$name]:-}"
    if [[ -z "$start" ]]; then
        # Graceful handling: missing _phase_start is not fatal
        return 0
    fi
    local end
    end=$(_get_epoch_secs)
    local elapsed=$(( end - start ))
    # Accumulate (supports nested/repeated phases like multiple build gates)
    local prev="${_PHASE_TIMINGS[$name]:-0}"
    _PHASE_TIMINGS[$name]=$(( prev + elapsed ))
    unset '_PHASE_STARTS[$name]'
}

# _get_phase_duration NAME — prints the recorded duration in seconds.
# Returns 0 if phase was never recorded.
_get_phase_duration() {
    echo "${_PHASE_TIMINGS[${1}]:-0}"
}

# _format_duration_human SECONDS — prints human-readable duration (e.g. "4m 22s").
_format_duration_human() {
    local secs="$1"
    if [[ "$secs" -ge 60 ]]; then
        echo "$(( secs / 60 ))m $(( secs % 60 ))s"
    else
        echo "${secs}s"
    fi
}
