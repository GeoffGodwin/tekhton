#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# diagnose_rules.sh — Primary diagnostic rule definitions for --diagnose
#
# Sourced by lib/diagnose.sh — do not run directly.
# Expects: _DIAG_* module state populated by _read_diagnostic_context()
#
# Provides (primary rules): _rule_build_failure, _rule_max_turns,
#   _rule_review_loop, _rule_security_halt, _rule_intake_clarity,
#   _rule_quota_exhausted, _rule_unknown, plus DIAGNOSE_RULES priority array.
#
# Secondary rules live in lib/diagnose_rules_extra.sh; M133 resilience-arc
# rules live in lib/diagnose_rules_resilience.sh — both sourced below.
# =============================================================================

# --- Shared state for matched rule -----------------------------------------

# shellcheck disable=SC2034  # Used by lib/diagnose.sh
DIAG_CLASSIFICATION=""   # Rule name (e.g., BUILD_FAILURE)
# shellcheck disable=SC2034  # Used by lib/diagnose.sh
DIAG_CONFIDENCE=""       # high, medium, low
DIAG_SUGGESTIONS=()      # Array of suggestion strings

# --- Primary rule implementations ------------------------------------------

# _rule_build_failure
# Detect ${BUILD_ERRORS_FILE} non-empty.
_rule_build_failure() {
    local errors_file="${PROJECT_DIR:-.}/${BUILD_ERRORS_FILE}"
    [[ -f "$errors_file" ]] || return 1
    [[ -s "$errors_file" ]] || return 1

    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"

    DIAG_CLASSIFICATION="BUILD_FAILURE"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=()

    local build_fix_attempted=false
    if [[ -n "${_DIAG_CAUSAL_EVENTS:-}" ]]; then
        if echo "$_DIAG_CAUSAL_EVENTS" | grep -q '"type":"build_fix"' 2>/dev/null; then
            build_fix_attempted=true
        fi
    fi

    DIAG_SUGGESTIONS+=("Build failed. Errors in ${BUILD_ERRORS_FILE}.")
    if [[ "$build_fix_attempted" = true ]]; then
        DIAG_SUGGESTIONS+=("Automatic build fix was attempted and failed.")
        DIAG_SUGGESTIONS+=("The errors may require manual intervention. See ${BUILD_ERRORS_FILE}.")
    else
        DIAG_SUGGESTIONS+=(
            "Options:"
            "  1. Fix the build errors manually, then:"
            "     tekhton --complete --milestone --start-at coder \"${_task}\""
            "  2. Or let Tekhton retry (auto build-fix):"
            "     tekhton --complete --milestone \"${_task}\""
        )
    fi
    DIAG_SUGGESTIONS+=("See details: cat ${BUILD_ERRORS_FILE}")
    return 0
}

# _rule_max_turns
# Detect agent hit max_turns via state files (no causal log required).
# Fires on:
#   - LAST_FAILURE_CONTEXT.json category/subcategory = AGENT_SCOPE/max_turns, OR
#   - PIPELINE_STATE.md Exit Reason containing complete_loop_max_attempts, OR
#   - PIPELINE_STATE.md Notes containing "max_turns"
# Must fire before _rule_review_loop (more specific).
_rule_max_turns() {
    local failure_ctx="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"

    # M129: prefer secondary cause from v2 schema, fall back to top-level
    # alias category/subcategory (writer compat layer).
    local _cat="${_DIAG_SECONDARY_CATEGORY:-}"
    local _sub="${_DIAG_SECONDARY_SUBCATEGORY:-}"
    if [[ -z "$_cat" ]] && [[ -f "$failure_ctx" ]]; then
        _cat=$(grep -oP '"category"\s*:\s*"\K[^"]+' "$failure_ctx" 2>/dev/null || true)
        _sub=$(grep -oP '"subcategory"\s*:\s*"\K[^"]+' "$failure_ctx" 2>/dev/null || true)
    fi

    # Use _DIAG_EXIT_REASON populated by _read_diagnostic_context (module contract).
    # Fall back to reading from state file directly so this rule also works when
    # called outside the full diagnose flow (e.g., unit tests).
    local _exit_reason="${_DIAG_EXIT_REASON:-}"
    local _state_notes=""
    if [[ -f "$state_file" ]]; then
        if [[ -z "$_exit_reason" ]]; then
            _exit_reason=$(read_pipeline_state_field "$state_file" exit_reason)
        fi
        _state_notes=$(read_pipeline_state_field "$state_file" notes)
    fi

    local matched=false
    if [[ "$_cat" = "AGENT_SCOPE" ]] && [[ "$_sub" = "max_turns" ]]; then
        matched=true
    elif [[ "$_exit_reason" == *complete_loop_max_attempts* ]]; then
        matched=true
    elif grep -q "max_turns" <<< "$_state_notes" 2>/dev/null; then
        matched=true
    fi

    [[ "$matched" = true ]] || return 1

    local _stage="${_DIAG_PIPELINE_STAGE:-coder}"
    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"
    local _limit="${CODER_MAX_TURNS:-80}"
    local _bumped=$(( _limit + 40 ))

    # M133: when v2 primary is non-agent (typically ENVIRONMENT/test_infra),
    # max_turns is the cascading symptom — emit MAX_TURNS_ENV_ROOT instead.
    # v1 fixtures and AGENT_SCOPE primaries fall through to the legacy branch.
    local _pcat="${_DIAG_PRIMARY_CATEGORY:-}"
    local _schema="${_DIAG_SCHEMA_VERSION:-0}"
    [[ "$_schema" =~ ^[0-9]+$ ]] || _schema=0
    if [[ "$_schema" -ge 2 ]] && [[ -n "$_pcat" ]] && [[ "$_pcat" != "AGENT_SCOPE" ]]; then
        DIAG_CLASSIFICATION="MAX_TURNS_ENV_ROOT"
        DIAG_CONFIDENCE="high"
        DIAG_SUGGESTIONS=(
            "The ${_stage} agent hit its turn limit (${_limit} turns) — but max_turns was the secondary symptom."
            "Primary cause: ${_pcat}/${_DIAG_PRIMARY_SUBCATEGORY:-?} (${_DIAG_PRIMARY_SIGNAL:-unknown signal})."
            "Adding more turns or splitting scope is unlikely to help until the root cause is fixed."
            "Read the root-cause artifact:"
            "  cat .claude/LAST_FAILURE_CONTEXT.json"
            "Re-run preflight if the failure looks environmental:"
            "  tekhton --preflight"
            "Then resume from coder once the root cause is resolved:"
            "  tekhton --complete --milestone --start-at coder \"${_task}\""
        )
        return 0
    fi

    DIAG_CLASSIFICATION="MAX_TURNS_EXHAUSTED"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "The ${_stage} agent hit its turn limit (${_limit} turns) on consecutive attempts."
        "The task scope is likely too large for the current turn budget."
        "Options:"
        "  1. Resume from test (if reviewer report is already present):"
        "     tekhton --complete --milestone --start-at test \"${_task}\""
        "  2. Retry with more turns (edit pipeline.conf: CODER_MAX_TURNS=${_bumped}):"
        "     tekhton --complete --milestone \"${_task}\""
        "  3. Split the milestone into smaller chunks (auto-split if MILESTONE_SPLIT_ENABLED=true):"
        "     tekhton --complete --milestone \"${_task}\""
    )
    return 0
}

# _rule_review_loop
# Detect review stage completed 3+ cycles with no approval.
_rule_review_loop() {
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    [[ -f "$state_file" ]] || return 1

    local exit_stage=""
    exit_stage=$(read_pipeline_state_field "$state_file" exit_stage)

    local review_rejections=0
    if [[ "$exit_stage" != "review" ]]; then
        if [[ -n "${_DIAG_CAUSAL_EVENTS:-}" ]]; then
            review_rejections=$(echo "$_DIAG_CAUSAL_EVENTS" | grep '"type":"verdict".*"stage":"reviewer"' 2>/dev/null | grep -c 'CHANGES_REQUIRED\|REJECTED' 2>/dev/null || echo "0")
            review_rejections="${review_rejections//[!0-9]/}"
            : "${review_rejections:=0}"
            [[ "$review_rejections" -ge 3 ]] || return 1
        else
            return 1
        fi
    fi

    local reviewer_file="${PROJECT_DIR:-.}/${REVIEWER_REPORT_FILE}"
    if [[ -f "$reviewer_file" ]]; then
        if ! grep -q 'CHANGES_REQUIRED\|REJECTED' "$reviewer_file" 2>/dev/null; then
            return 1
        fi
    fi

    local cycle_count="${_DIAG_REVIEW_CYCLES:-0}"
    [[ "$cycle_count" -eq 0 ]] && cycle_count="${review_rejections:-3}"

    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"

    DIAG_CLASSIFICATION="REVIEW_REJECTION_LOOP"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "Reviewer rejected the code ${cycle_count} times. The coder may be unable to address the feedback within the turn budget."
        "Options:"
        "  1. Increase MAX_REVIEW_CYCLES in pipeline.conf, then:"
        "     tekhton --complete --milestone \"${_task}\""
        "  2. Read ${REVIEWER_REPORT_FILE} and fix the issues manually, then:"
        "     tekhton --complete --milestone --start-at review \"${_task}\""
        "  3. Retry review only:"
        "     tekhton --complete --milestone --start-at review \"${_task}\""
    )
    return 0
}

# _rule_security_halt
# Detect security stage HALT verdict.
_rule_security_halt() {
    local security_file="${PROJECT_DIR:-.}/${SECURITY_REPORT_FILE}"
    [[ -f "$security_file" ]] || return 1

    if ! grep -q 'HALT\|halt' "$security_file" 2>/dev/null; then
        return 1
    fi

    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"

    DIAG_CLASSIFICATION="SECURITY_HALT"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "Security scan found CRITICAL unfixable vulnerabilities."
        "Options:"
        "  1. Add waivers to SECURITY_WAIVER_FILE for known-accepted risks, then:"
        "     tekhton --complete --milestone \"${_task}\""
        "  2. Fix the vulnerabilities manually and re-run:"
        "     tekhton --complete --milestone \"${_task}\""
        "  3. Change SECURITY_UNFIXABLE_POLICY to 'escalate' in pipeline.conf"
    )
    return 0
}

# _rule_intake_clarity
# Detect intake pause for clarification.
_rule_intake_clarity() {
    local clarify_file="${PROJECT_DIR:-.}/${CLARIFICATIONS_FILE}"
    [[ -f "$clarify_file" ]] || return 1
    [[ -s "$clarify_file" ]] || return 1

    if ! grep -q '^\- \[ \]' "$clarify_file" 2>/dev/null; then
        return 1
    fi

    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    if [[ -f "$state_file" ]]; then
        local exit_stage=""
        exit_stage=$(read_pipeline_state_field "$state_file" exit_stage)
        if [[ "$exit_stage" != "intake" ]]; then
            return 1
        fi
    fi

    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"

    DIAG_CLASSIFICATION="INTAKE_NEEDS_CLARITY"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "The PM agent needs clarification on this milestone."
        "Questions are in ${CLARIFICATIONS_FILE}."
        "Options:"
        "  1. Answer the questions in ${CLARIFICATIONS_FILE}, then:"
        "     tekhton --complete --milestone \"${_task}\""
        "  2. Lower INTAKE_CLARITY_THRESHOLD in pipeline.conf if the gate is too aggressive"
    )
    return 0
}

# _rule_quota_exhausted and _rule_unknown moved to diagnose_rules_extra.sh
# under M129 to keep this file under the 300-line ceiling.

# --- Source secondary rules --------------------------------------------------
# Extra rules live in a sibling file to keep this file under the 300-line ceiling.
# shellcheck source=lib/diagnose_rules_extra.sh
source "${TEKHTON_HOME:?}/lib/diagnose_rules_extra.sh"

# M133 resilience-arc primary rules
# (UI gate interactive reporter, build-fix exhausted, preflight interactive cfg).
# shellcheck source=lib/diagnose_rules_resilience.sh
source "${TEKHTON_HOME:?}/lib/diagnose_rules_resilience.sh"

# --- Rule registry -----------------------------------------------------------
# DIAGNOSE_RULES priority-ordered array lives in a sibling file so adding new
# rules here does not push the file over the 300-line ceiling.
# shellcheck source=lib/diagnose_rules_registry.sh
source "${TEKHTON_HOME:?}/lib/diagnose_rules_registry.sh"
