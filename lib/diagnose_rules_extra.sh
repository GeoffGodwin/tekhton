#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# diagnose_rules_extra.sh — Extended diagnostic rules (secondary patterns)
#
# Sourced by lib/diagnose_rules.sh — do not run directly.
# Expects: _DIAG_* module state variables declared in diagnose.sh
# Expects: DIAG_CLASSIFICATION, DIAG_CONFIDENCE, DIAG_SUGGESTIONS (shared globals)
# Expects: PROJECT_DIR (set by caller)
#
# Provides:
#   _rule_stuck_loop          — MAX_PIPELINE_ATTEMPTS with no progress
#   _rule_mixed_classification — Mixed-uncertain classification (M133, low conf)
#   _rule_turn_exhaustion     — Agent max-turns without completion (fallback)
#   _rule_split_depth         — MILESTONE_MAX_SPLIT_DEPTH exceeded
#   _rule_transient_error     — Transient API errors
#   _rule_test_audit_failure  — Test audit NEEDS_WORK after max rework cycles
#   _rule_quota_exhausted     — Pipeline paused waiting for quota refresh
#   _rule_unknown             — Catch-all fallback
# Migration & version-mismatch rules live in lib/diagnose_rules_migration.sh.
# =============================================================================

# _rule_stuck_loop
# Detect MAX_PIPELINE_ATTEMPTS reached with no progress.
_rule_stuck_loop() {
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    [[ -f "$state_file" ]] || return 1

    local attempts=""
    attempts=$(awk '/^Pipeline attempt:/{print $3; exit}' "$state_file" 2>/dev/null || true)
    attempts="${attempts//[!0-9]/}"
    : "${attempts:=0}"

    local max_attempts="${MAX_PIPELINE_ATTEMPTS:-5}"
    [[ "$attempts" -ge "$max_attempts" ]] || return 1

    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"

    DIAG_CLASSIFICATION="STUCK_LOOP"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "Pipeline completed ${attempts} attempts with no forward progress."
        "This usually means the task is too complex for automatic resolution."
        "Options:"
        "  1. Simplify the milestone and re-run:"
        "     tekhton --complete --milestone \"${_task}\""
        "  2. Break it into smaller milestones:"
        "     tekhton --add-milestone \"<smaller scope>\""
        "  3. Check the scout report for scope issues"
    )
    return 0
}

# _rule_mixed_classification
# M133: cautious explanation for failures the resilience arc tagged
# `mixed_uncertain` — the system itself was uncertain about a single cause,
# so this rule deliberately stays low-confidence and biases toward inspection.
#
# Sources:
#   1. LAST_FAILURE_CONTEXT.json classification = MIXED_UNCERTAIN
#   2. LAST_FAILURE_CONTEXT.json primary_cause.signal = mixed_uncertain_classification
#   3. RUN_SUMMARY.json causal_context.primary_signal = mixed_uncertain_classification
_rule_mixed_classification() {
    local failure_ctx="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
    local summary_file="${PROJECT_DIR:-.}/.claude/logs/RUN_SUMMARY.json"

    local matched=false
    if [[ "${_DIAG_LAST_CLASSIFICATION:-}" = "MIXED_UNCERTAIN" ]]; then
        matched=true
    fi
    if [[ "$matched" != true ]] && [[ "${_DIAG_PRIMARY_SIGNAL:-}" = "mixed_uncertain_classification" ]]; then
        matched=true
    fi
    if [[ "$matched" != true ]] && [[ -f "$failure_ctx" ]]; then
        if grep -q '"signal"\s*:\s*"mixed_uncertain_classification"' "$failure_ctx" 2>/dev/null; then
            matched=true
        fi
    fi
    if [[ "$matched" != true ]] && [[ -f "$summary_file" ]]; then
        if grep -q '"primary_signal"\s*:\s*"mixed_uncertain_classification"' "$summary_file" 2>/dev/null; then
            matched=true
        fi
    fi

    [[ "$matched" = true ]] || return 1

    local raw_path="${BUILD_RAW_ERRORS_FILE:-${TEKHTON_DIR:-.tekhton}/BUILD_RAW_ERRORS.txt}"

    DIAG_CLASSIFICATION="MIXED_UNCERTAIN_CLASSIFICATION"
    DIAG_CONFIDENCE="low"
    DIAG_SUGGESTIONS=(
        "The build classifier could not confidently identify a single cause."
        "Some signals looked like code errors; others looked environmental."
        "Inspect the raw error stream first — root cause likely sits at the top:"
        "  cat ${raw_path}"
        "Look for the FIRST causal error, not the last cascade."
        "If the first failure looks environmental, re-run preflight:"
        "  tekhton --preflight"
    )
    return 0
}

# _rule_turn_exhaustion
# Detect agent hit max turns without completing (fallback when _rule_max_turns
# doesn't match — kept for backward-compatibility with pre-M93 runs).
#
# PRE-M93 COMPATIBILITY:
# Versions prior to M93 did not consistently write LAST_FAILURE_CONTEXT.json,
# so _rule_max_turns (position 2 in DIAGNOSE_RULES) would not fire, and this
# rule (position 8) was the only turn-exhaustion detector for those runs.
#
# SAFE TO REMOVE WHEN:
# All active projects have been run at least once with M93+, ensuring every
# project's .claude/ directory contains LAST_FAILURE_CONTEXT.json. After that,
# _rule_max_turns will always match first, and this function becomes dead code.
_rule_turn_exhaustion() {
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    [[ -f "$state_file" ]] || return 1

    local error_cat=""
    error_cat=$(awk '/^Category:/{print $2; exit}' "$state_file" 2>/dev/null || true)
    local error_sub=""
    error_sub=$(awk '/^Subcategory:/{print $2; exit}' "$state_file" 2>/dev/null || true)

    if [[ "$error_cat" != "AGENT_SCOPE" ]] || [[ "$error_sub" != "max_turns" ]]; then
        return 1
    fi

    local exit_stage=""
    exit_stage=$(awk '/^## Exit Stage$/{getline; print; exit}' "$state_file" 2>/dev/null || true)
    local stage_upper
    stage_upper=$(echo "$exit_stage" | tr '[:lower:]' '[:upper:]')

    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"

    DIAG_CLASSIFICATION="TURN_EXHAUSTION"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "The ${exit_stage} agent exhausted its turn budget."
        "Options:"
        "  1. Increase ${stage_upper}_MAX_TURNS in pipeline.conf, then:"
        "     tekhton --complete --milestone \"${_task}\""
        "  2. Simplify the task scope"
        "  3. Check if continuation is enabled (CONTINUATION_ENABLED=true)"
    )
    return 0
}

# _rule_split_depth
# Detect MILESTONE_MAX_SPLIT_DEPTH exceeded.
_rule_split_depth() {
    local summary_file="${PROJECT_DIR:-.}/.claude/logs/RUN_SUMMARY.json"
    [[ -f "$summary_file" ]] || return 1

    local split_depth=""
    split_depth=$(grep -oP '"split_depth"\s*:\s*\K[0-9]+' "$summary_file" 2>/dev/null || true)
    split_depth="${split_depth//[!0-9]/}"
    : "${split_depth:=0}"

    local max_depth="${MILESTONE_MAX_SPLIT_DEPTH:-3}"
    [[ "$split_depth" -ge "$max_depth" ]] || return 1

    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"

    DIAG_CLASSIFICATION="MILESTONE_SPLIT_DEPTH"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "Milestone was split ${split_depth} times and still couldn't complete."
        "The task may be fundamentally too complex for automated splitting."
        "Options:"
        "  1. Manually break it into smaller milestones:"
        "     tekhton --add-milestone \"<smaller scope>\""
        "  2. Increase MILESTONE_MAX_SPLIT_DEPTH (currently ${max_depth}) then:"
        "     tekhton --complete --milestone \"${_task}\""
    )
    return 0
}

# _rule_transient_error
# Detect transient API errors from error classification.
_rule_transient_error() {
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    [[ -f "$state_file" ]] || return 1

    local error_cat=""
    error_cat=$(awk '/^Category:/{print $2; exit}' "$state_file" 2>/dev/null || true)
    local is_transient=""
    is_transient=$(awk '/^Transient:/{print $2; exit}' "$state_file" 2>/dev/null || true)

    if [[ "$error_cat" != "UPSTREAM" ]] && [[ "$is_transient" != "true" ]]; then
        return 1
    fi

    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"

    DIAG_CLASSIFICATION="TRANSIENT_ERROR"
    DIAG_CONFIDENCE="medium"
    DIAG_SUGGESTIONS=(
        "Claude API returned transient errors (server error, timeout)."
        "This is usually temporary. Re-run to resume:"
        "  tekhton --complete --milestone \"${_task}\""
        "If persistent, check Claude API status: status.anthropic.com"
    )
    return 0
}

# _rule_test_audit_failure
# Detect test audit NEEDS_WORK verdict after max rework cycles.
_rule_test_audit_failure() {
    local audit_file="${PROJECT_DIR:-.}/${TEST_AUDIT_REPORT_FILE:-}"
    [[ -f "$audit_file" ]] || return 1

    if ! grep -qi 'Verdict:.*NEEDS_WORK' "$audit_file" 2>/dev/null; then
        return 1
    fi

    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"

    DIAG_CLASSIFICATION="TEST_AUDIT_FAILURE"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "Test audit found integrity issues the tester couldn't fix."
        "Review ${TEST_AUDIT_REPORT_FILE} for specific findings."
        "Options:"
        "  1. Fix flagged tests manually (see HIGH severity findings), then:"
        "     tekhton --complete --milestone \"${_task}\""
        "  2. Remove orphaned tests that import deleted modules"
        "  3. Increase TEST_AUDIT_MAX_REWORK_CYCLES if more auto-fix attempts are warranted"
    )
    return 0
}

# Migration / version-mismatch rules live in a sibling file.
# shellcheck source=lib/diagnose_rules_migration.sh
source "${TEKHTON_HOME:?}/lib/diagnose_rules_migration.sh"

# _rule_quota_exhausted
# Detect rate limit pause. Moved from diagnose_rules.sh under M129 to keep
# the primary file under the 300-line ceiling.
_rule_quota_exhausted() {
    local quota_marker="${PROJECT_DIR:-.}/.claude/QUOTA_PAUSED"
    [[ -f "$quota_marker" ]] || return 1

    DIAG_CLASSIFICATION="QUOTA_EXHAUSTED"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "Pipeline paused waiting for quota refresh."
        "It will resume automatically. No action needed."
        "If you need it sooner, wait for your 5-hour window to refresh."
    )
    return 0
}

# _rule_unknown
# Fallback catch-all — always matches. Moved from diagnose_rules.sh under M129.
_rule_unknown() {
    # shellcheck disable=SC2034
    DIAG_CLASSIFICATION="UNKNOWN"
    # shellcheck disable=SC2034
    DIAG_CONFIDENCE="low"
    # shellcheck disable=SC2034
    DIAG_SUGGESTIONS=(
        "No specific failure pattern identified."
        "Check the latest agent output in .claude/logs/"
        "Re-run with DASHBOARD_VERBOSITY=verbose for more detail"
    )
    return 0
}
