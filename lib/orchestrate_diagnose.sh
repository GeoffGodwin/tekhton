#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate_diagnose.sh — Inline recovery block printer (M94, M130)
#
# m12: renamed from orchestrate_recovery_print.sh as part of the bash
# relocation cutover.
# Sourced by orchestrate_classify.sh — do not run directly.
#
# Provides:
#   _print_recovery_block OUTCOME DETAIL RESUME_CMD TASK [CAUSE_SUMMARY]
#
# Prints a "WHAT HAPPENED / WHAT TO DO NEXT" block to stdout so the user sees
# exact runnable commands at the terminal exit path. Called by
# _save_orchestration_state after write_pipeline_state. Colors use ${BOLD:-} /
# ${NC:-} so the block prints cleanly in test contexts without terminal colors.
#
# M130: optional 5th arg cause_summary inserts a "Root cause: ..." line into
# the WHAT HAPPENED block. Callers that don't pass it (existing 4-arg sites)
# are unaffected — the line is suppressed when cause_summary is empty.
# =============================================================================

_print_recovery_block() {
    local outcome="${1:-unknown}"
    local detail="${2:-}"
    local resume_cmd="${3:-}"
    local task="${4:-}"
    local cause_summary="${5:-}"

    local _cur_turns="${EFFECTIVE_CODER_MAX_TURNS:-${CODER_MAX_TURNS:-80}}"
    local _bump_turns=$(( _cur_turns + 40 ))
    local _base_flags="--complete"
    [[ "${MILESTONE_MODE:-false}" = "true" ]] && _base_flags="--complete --milestone"

    local what_happened=""
    case "$outcome" in
        max_attempts)
            what_happened="Pipeline hit ${MAX_PIPELINE_ATTEMPTS:-5} consecutive failing attempts. Current coder turn budget: ${_cur_turns}."
            ;;
        timeout)
            what_happened="Pipeline exceeded the autonomous timeout (${AUTONOMOUS_TIMEOUT:-7200}s)."
            ;;
        agent_cap)
            what_happened="Pipeline exceeded the max agent-call cap (${MAX_AUTONOMOUS_AGENT_CALLS:-20})."
            ;;
        pre_existing_failure)
            what_happened="Tests were failing before the coder ran. Pre-existing test failures detected."
            ;;
        *)
            what_happened="${detail:-Pipeline stopped with no additional detail.}"
            ;;
    esac

    local _sep="══════════════════════════════════════════════════"
    echo
    echo -e "${BOLD:-}${_sep}${NC:-}"
    echo -e "${BOLD:-}  WHAT HAPPENED${NC:-}"
    echo -e "${BOLD:-}${_sep}${NC:-}"
    echo "  ${what_happened}"
    if [[ -n "$cause_summary" ]]; then
        echo "  Root cause: ${cause_summary}"
    fi
    echo
    echo -e "${BOLD:-}${_sep}${NC:-}"
    echo -e "${BOLD:-}  WHAT TO DO NEXT${NC:-}"
    echo -e "${BOLD:-}${_sep}${NC:-}"
    echo "  1. RESUME     -> ${resume_cmd}"

    case "$outcome" in
        max_attempts)
            echo "  2. MORE TURNS -> edit pipeline.conf: CODER_MAX_TURNS=${_bump_turns}"
            echo "                  then: tekhton ${_base_flags} \"${task}\""
            ;;
        pre_existing_failure)
            echo "  2. DISABLE    -> set PRE_RUN_CLEAN_ENABLED=false in pipeline.conf"
            ;;
    esac

    echo "  3. DIAGNOSE   -> tekhton --diagnose"
    echo -e "${BOLD:-}${_sep}${NC:-}"
    echo
}
