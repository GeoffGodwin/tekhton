#!/usr/bin/env bash
# =============================================================================
# run_summary_reconstruct.sh — Aggregate per-stage envelopes into the run
# summary globals (TOTAL_TURNS / TOTAL_TIME / STAGE_SUMMARY) when the
# in-process V3 accumulators aren't available.
#
# Sourced by tekhton.sh — do not run directly.
# Expects: log() warn() from common.sh (warnings only; never fatal).
# Provides: _reconstruct_run_summary_from_stage_results — called by
#           print_run_summary in lib/agent_helpers.sh when TOTAL_TURNS=0
#           AND TOTAL_TIME=0 (i.e. running in the finalize subprocess
#           where in-process state didn't propagate).
#
# Why a separate file: agent_helpers.sh is already at 344 lines (over the
# bash 300-line ceiling). This logic is independent enough to live on its
# own; pulling it out keeps agent_helpers.sh from growing further while
# fixing the user-visible "Run Summary blanks at end" bug from the V4 m18
# stagerunner cutover.
# =============================================================================
set -euo pipefail

# _reconstruct_run_summary_from_stage_results
# Iterates .tekhton/stage_results/stage_*.json envelopes and aggregates
# agent_calls / duration_sec into TOTAL_TURNS / TOTAL_TIME, plus assembles
# a STAGE_SUMMARY breakdown one line per stage. The reconstructed values
# exactly mirror the format lib/agent.sh:run_agent would have produced
# in-process (per-stage label, model omitted because the envelope doesn't
# carry it — caller sees stage names instead of "Coder (claude-opus-4-7)").
#
# Defensive — when the directory or files are missing or unreadable, the
# function returns 0 with TOTAL_TURNS/TOTAL_TIME still at zero. The Run
# Summary then renders the legacy 0-values output, which is the same
# behaviour as before this helper existed.
_reconstruct_run_summary_from_stage_results() {
    local dir="${TEKHTON_DIR:-.tekhton}/stage_results"
    if [[ -n "${PROJECT_DIR:-}" ]] && [[ "$dir" != /* ]]; then
        dir="${PROJECT_DIR}/${dir}"
    fi
    [[ -d "$dir" ]] || return 0

    local _total_calls=0 _total_dur=0 _summary=""
    local _f _stage _calls _dur _m _s
    # Stable iteration order (intake → coder → security → review → tester)
    # via shell glob alphabetisation. Stage envelopes from the same stage
    # but different review cycles (stage_coder_r2_b0.json etc.) sum into
    # the same per-stage row by detecting the stage name.
    declare -A _per_stage_calls=() _per_stage_dur=()
    for _f in "$dir"/stage_*.json; do
        [[ -f "$_f" ]] || continue
        # Extract the three scalar fields with a pure-bash awk pass —
        # avoids a jq dependency that the standalone tekhton install does
        # not pin. Format is the m18 stage.result.v1 envelope which the
        # Go runner emits with stable spacing, so the trivial regex match
        # is reliable.
        _stage=$(awk -F'"' '/"stage":/ {print $4; exit}' "$_f" 2>/dev/null)
        _calls=$(awk '/"agent_calls":/ {match($0, /[0-9]+/); print substr($0, RSTART, RLENGTH); exit}' "$_f" 2>/dev/null)
        _dur=$(awk '/"duration_sec":/ {match($0, /[0-9]+/); print substr($0, RSTART, RLENGTH); exit}' "$_f" 2>/dev/null)
        [[ -n "$_stage" ]] || continue
        _calls="${_calls:-0}"
        _dur="${_dur:-0}"
        _per_stage_calls[$_stage]=$(( ${_per_stage_calls[$_stage]:-0} + _calls ))
        _per_stage_dur[$_stage]=$(( ${_per_stage_dur[$_stage]:-0} + _dur ))
    done

    # Emit summary in a stable order matching the standard pipeline.
    local _order=(intake coder security review tester)
    local _seen
    declare -A _seen=()
    for _stage in "${_order[@]}"; do
        if [[ -n "${_per_stage_calls[$_stage]:-}" ]]; then
            _seen[$_stage]=1
            _calls="${_per_stage_calls[$_stage]}"
            _dur="${_per_stage_dur[$_stage]}"
            _m=$(( _dur / 60 ))
            _s=$(( _dur % 60 ))
            _summary="${_summary}\n  ${_stage^}: ${_calls} agent calls, ${_m}m${_s}s"
            _total_calls=$(( _total_calls + _calls ))
            _total_dur=$(( _total_dur + _dur ))
        fi
    done
    # Append any stages outside the canonical order (custom pipelines).
    for _stage in "${!_per_stage_calls[@]}"; do
        [[ -n "${_seen[$_stage]:-}" ]] && continue
        _calls="${_per_stage_calls[$_stage]}"
        _dur="${_per_stage_dur[$_stage]}"
        _m=$(( _dur / 60 ))
        _s=$(( _dur % 60 ))
        _summary="${_summary}\n  ${_stage^}: ${_calls} agent calls, ${_m}m${_s}s"
        _total_calls=$(( _total_calls + _calls ))
        _total_dur=$(( _total_dur + _dur ))
    done

    # shellcheck disable=SC2034  # read by print_run_summary in lib/agent_helpers.sh
    TOTAL_TURNS="$_total_calls"
    # shellcheck disable=SC2034  # read by print_run_summary in lib/agent_helpers.sh
    TOTAL_TIME="$_total_dur"
    # shellcheck disable=SC2034  # read by print_run_summary in lib/agent_helpers.sh
    STAGE_SUMMARY="$_summary"
}
