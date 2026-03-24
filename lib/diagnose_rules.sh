#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# diagnose_rules.sh — Diagnostic rule definitions for --diagnose
#
# Sourced by lib/diagnose.sh — do not run directly.
# Expects: _DIAG_* associative arrays populated by _read_diagnostic_context()
# Expects: PROJECT_DIR (set by caller)
#
# Provides:
#   DIAGNOSE_RULES            — priority-ordered array of rule functions
#   _rule_build_failure       — BUILD_ERRORS.md non-empty
#   _rule_review_loop         — 3+ review cycles with no approval
#   _rule_security_halt       — Security HALT verdict (M09 guard)
#   _rule_intake_clarity      — Intake pause for clarification (M10 guard)
#   _rule_quota_exhausted     — Rate limit pause (M16 guard)
#   _rule_stuck_loop          — MAX_PIPELINE_ATTEMPTS with no progress
#   _rule_turn_exhaustion     — Agent max-turns without completion
#   _rule_split_depth         — MILESTONE_MAX_SPLIT_DEPTH exceeded
#   _rule_transient_error     — Transient API errors
#   _rule_unknown             — Fallback catch-all
# =============================================================================

# --- Shared state for matched rule -----------------------------------------

# shellcheck disable=SC2034  # Used by lib/diagnose.sh
DIAG_CLASSIFICATION=""   # Rule name (e.g., BUILD_FAILURE)
# shellcheck disable=SC2034  # Used by lib/diagnose.sh
DIAG_CONFIDENCE=""       # high, medium, low
DIAG_SUGGESTIONS=()      # Array of suggestion strings

# --- Rule implementations --------------------------------------------------

# _rule_build_failure
# Detect BUILD_ERRORS.md non-empty.
_rule_build_failure() {
    local errors_file="${PROJECT_DIR:-.}/BUILD_ERRORS.md"
    [[ -f "$errors_file" ]] || return 1
    [[ -s "$errors_file" ]] || return 1

    DIAG_CLASSIFICATION="BUILD_FAILURE"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=()

    # Check if build fix was already attempted
    local build_fix_attempted=false
    if [[ -n "${_DIAG_CAUSAL_EVENTS:-}" ]]; then
        if echo "$_DIAG_CAUSAL_EVENTS" | grep -q '"type":"build_fix"' 2>/dev/null; then
            build_fix_attempted=true
        fi
    fi

    DIAG_SUGGESTIONS+=("Build failed. Errors in BUILD_ERRORS.md.")
    if [[ "$build_fix_attempted" = true ]]; then
        DIAG_SUGGESTIONS+=("Automatic build fix was attempted and failed.")
        DIAG_SUGGESTIONS+=("The errors may require manual intervention. See BUILD_ERRORS.md.")
    else
        DIAG_SUGGESTIONS+=("Fix the build errors manually, then run: tekhton --start-at coder")
        DIAG_SUGGESTIONS+=("Or let Tekhton retry: tekhton --milestone (it will attempt build fix)")
    fi
    DIAG_SUGGESTIONS+=("See details: cat BUILD_ERRORS.md")
    return 0
}

# _rule_review_loop
# Detect review stage completed 3+ cycles with no approval.
_rule_review_loop() {
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    [[ -f "$state_file" ]] || return 1

    # Check for review cycle exhaustion in pipeline state
    local exit_stage=""
    exit_stage=$(awk '/^## Exit Stage$/{getline; print; exit}' "$state_file" 2>/dev/null || true)

    # Check if review stage hit max cycles
    if [[ "$exit_stage" != "review" ]]; then
        # Also check causal log for review CHANGES_REQUIRED verdict events
        if [[ -n "${_DIAG_CAUSAL_EVENTS:-}" ]]; then
            local review_rejections
            review_rejections=$(echo "$_DIAG_CAUSAL_EVENTS" | grep '"type":"verdict".*"stage":"reviewer"' 2>/dev/null | grep -c 'CHANGES_REQUIRED\|REJECTED' 2>/dev/null || echo "0")
            review_rejections="${review_rejections//[!0-9]/}"
            : "${review_rejections:=0}"
            [[ "$review_rejections" -ge 3 ]] || return 1
        else
            return 1
        fi
    fi

    # Check reviewer report for CHANGES_REQUIRED
    local reviewer_file="${PROJECT_DIR:-.}/REVIEWER_REPORT.md"
    if [[ -f "$reviewer_file" ]]; then
        if ! grep -q 'CHANGES_REQUIRED\|REJECTED' "$reviewer_file" 2>/dev/null; then
            return 1
        fi
    fi

    local cycle_count="${_DIAG_REVIEW_CYCLES:-0}"
    [[ "$cycle_count" -eq 0 ]] && cycle_count="${review_rejections:-3}"

    DIAG_CLASSIFICATION="REVIEW_REJECTION_LOOP"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "Reviewer rejected the code ${cycle_count} times. The coder may be unable to address the feedback within the turn budget."
        "Options:"
        "  1. Increase MAX_REVIEW_CYCLES in pipeline.conf"
        "  2. Read REVIEWER_REPORT.md and fix the issues manually"
        "  3. Run: tekhton --start-at review to retry review only"
    )
    return 0
}

# _rule_security_halt
# Detect security stage HALT verdict (forward-compat: no-op until M09 exists).
_rule_security_halt() {
    local security_file="${PROJECT_DIR:-.}/SECURITY_REPORT.md"
    [[ -f "$security_file" ]] || return 1

    # Check for HALT verdict in security report
    if ! grep -q 'HALT\|halt' "$security_file" 2>/dev/null; then
        return 1
    fi

    DIAG_CLASSIFICATION="SECURITY_HALT"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "Security scan found CRITICAL unfixable vulnerabilities."
        "Options:"
        "  1. Add waivers to SECURITY_WAIVER_FILE for known-accepted risks"
        "  2. Fix the vulnerabilities manually and re-run"
        "  3. Change SECURITY_UNFIXABLE_POLICY to 'escalate' to continue with warnings"
    )
    return 0
}

# _rule_intake_clarity
# Detect intake pause for clarification (forward-compat: no-op until M10 exists).
_rule_intake_clarity() {
    local clarify_file="${PROJECT_DIR:-.}/CLARIFICATIONS.md"
    [[ -f "$clarify_file" ]] || return 1
    [[ -s "$clarify_file" ]] || return 1

    # Check if there are unanswered questions
    if ! grep -q '^\- \[ \]' "$clarify_file" 2>/dev/null; then
        return 1
    fi

    # Also check pipeline state for intake stage exit
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    if [[ -f "$state_file" ]]; then
        local exit_stage=""
        exit_stage=$(awk '/^## Exit Stage$/{getline; print; exit}' "$state_file" 2>/dev/null || true)
        if [[ "$exit_stage" != "intake" ]]; then
            return 1
        fi
    fi

    DIAG_CLASSIFICATION="INTAKE_NEEDS_CLARITY"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "The PM agent needs clarification on this milestone."
        "Questions are in CLARIFICATIONS.md. Answer them and re-run."
        "Or lower INTAKE_CLARITY_THRESHOLD if the gate is too aggressive."
    )
    return 0
}

# _rule_quota_exhausted
# Detect rate limit pause (forward-compat: no-op until M16 exists).
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

# _rule_stuck_loop
# Detect MAX_PIPELINE_ATTEMPTS reached with no progress.
_rule_stuck_loop() {
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    [[ -f "$state_file" ]] || return 1

    # Check orchestration context for attempt count
    local attempts=""
    attempts=$(awk '/^Pipeline attempt:/{print $3; exit}' "$state_file" 2>/dev/null || true)
    attempts="${attempts//[!0-9]/}"
    : "${attempts:=0}"

    local max_attempts="${MAX_PIPELINE_ATTEMPTS:-5}"
    [[ "$attempts" -ge "$max_attempts" ]] || return 1

    DIAG_CLASSIFICATION="STUCK_LOOP"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "Pipeline completed ${attempts} attempts with no forward progress."
        "This usually means the task is too complex for automatic resolution."
        "Options:"
        "  1. Simplify the milestone and re-run"
        "  2. Break it into smaller milestones: tekhton --add-milestone \"desc\""
        "  3. Check the scout report for scope issues"
    )
    return 0
}

# _rule_turn_exhaustion
# Detect agent hit max turns without completing.
_rule_turn_exhaustion() {
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    [[ -f "$state_file" ]] || return 1

    # Check error classification for max_turns
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

    DIAG_CLASSIFICATION="TURN_EXHAUSTION"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "The ${exit_stage} agent exhausted its turn budget."
        "Options:"
        "  1. Increase ${stage_upper}_MAX_TURNS in pipeline.conf"
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

    # Check split_depth in run summary
    local split_depth=""
    split_depth=$(grep -oP '"split_depth"\s*:\s*\K[0-9]+' "$summary_file" 2>/dev/null || true)
    split_depth="${split_depth//[!0-9]/}"
    : "${split_depth:=0}"

    local max_depth="${MILESTONE_MAX_SPLIT_DEPTH:-3}"
    [[ "$split_depth" -ge "$max_depth" ]] || return 1

    DIAG_CLASSIFICATION="MILESTONE_SPLIT_DEPTH"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "Milestone was split ${split_depth} times and still couldn't complete."
        "The task may be fundamentally too complex for automated splitting."
        "Options:"
        "  1. Manually break it into smaller milestones"
        "  2. Increase MILESTONE_MAX_SPLIT_DEPTH (currently ${max_depth})"
    )
    return 0
}

# _rule_transient_error
# Detect transient API errors from error classification.
_rule_transient_error() {
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    [[ -f "$state_file" ]] || return 1

    # Check error classification for upstream/transient errors
    local error_cat=""
    error_cat=$(awk '/^Category:/{print $2; exit}' "$state_file" 2>/dev/null || true)
    local is_transient=""
    is_transient=$(awk '/^Transient:/{print $2; exit}' "$state_file" 2>/dev/null || true)

    if [[ "$error_cat" != "UPSTREAM" ]] && [[ "$is_transient" != "true" ]]; then
        return 1
    fi

    DIAG_CLASSIFICATION="TRANSIENT_ERROR"
    DIAG_CONFIDENCE="medium"
    DIAG_SUGGESTIONS=(
        "Claude API returned transient errors (server error, timeout)."
        "This is usually temporary. Re-run: tekhton (it will resume)"
        "If persistent, check Claude API status: status.anthropic.com"
    )
    return 0
}

# _rule_unknown
# Fallback catch-all — always matches.
# _rule_test_audit_failure
# Detect test audit NEEDS_WORK verdict after max rework cycles.
_rule_test_audit_failure() {
    local audit_file="${PROJECT_DIR:-.}/${TEST_AUDIT_REPORT_FILE:-TEST_AUDIT_REPORT.md}"
    [[ -f "$audit_file" ]] || return 1

    # Check for NEEDS_WORK verdict
    if ! grep -qi 'Verdict:.*NEEDS_WORK' "$audit_file" 2>/dev/null; then
        return 1
    fi

    DIAG_CLASSIFICATION="TEST_AUDIT_FAILURE"
    DIAG_CONFIDENCE="high"
    DIAG_SUGGESTIONS=(
        "Test audit found integrity issues the tester couldn't fix."
        "Review TEST_AUDIT_REPORT.md for specific findings."
        "Options:"
        "  1. Fix flagged tests manually (see HIGH severity findings)"
        "  2. Remove orphaned tests that import deleted modules"
        "  3. Increase TEST_AUDIT_MAX_REWORK_CYCLES if more auto-fix attempts are warranted"
    )
    return 0
}

# _rule_version_mismatch
# Detect project config version behind running Tekhton version.
_rule_version_mismatch() {
    local conf_file="${PROJECT_DIR:-.}/.claude/pipeline.conf"
    [[ -f "$conf_file" ]] || return 1

    # Check if detect_config_version is available
    command -v detect_config_version &>/dev/null || return 1

    local config_ver
    config_ver=$(detect_config_version "${PROJECT_DIR:-.}" 2>/dev/null || echo "")
    [[ -n "$config_ver" ]] || return 1

    local running_ver="${TEKHTON_VERSION%.*}"
    running_ver="${running_ver:-0.0}"

    # Only flag if config is behind running version
    command -v _version_lt &>/dev/null || return 1
    _version_lt "$config_ver" "$running_ver" || return 1

    DIAG_CLASSIFICATION="VERSION_MISMATCH"
    DIAG_CONFIDENCE="medium"
    DIAG_SUGGESTIONS=(
        "Project config is V${config_ver} but Tekhton is V${running_ver}."
        "This may cause features to not work as expected."
        "Run: tekhton --migrate"
    )
    return 0
}

_rule_unknown() {
    # shellcheck disable=SC2034
    DIAG_CLASSIFICATION="UNKNOWN"  # DIAG_* are globals read by the caller
    # shellcheck disable=SC2034
    DIAG_CONFIDENCE="low"
    DIAG_SUGGESTIONS=(
        "No specific failure pattern identified."
        "Check the latest agent output in .claude/logs/"
        "Re-run with DASHBOARD_VERBOSITY=verbose for more detail"
    )
    return 0
}

# --- Rule registry -----------------------------------------------------------
# Priority-ordered array. classify_failure_diag() applies rules top-down,
# stops at the first match. Rules for future stages are no-ops when state
# files are absent.

# shellcheck disable=SC2034  # Used by lib/diagnose.sh
DIAGNOSE_RULES=(
    "_rule_build_failure"
    "_rule_review_loop"
    "_rule_security_halt"
    "_rule_intake_clarity"
    "_rule_quota_exhausted"
    "_rule_stuck_loop"
    "_rule_turn_exhaustion"
    "_rule_split_depth"
    "_rule_transient_error"
    "_rule_test_audit_failure"
    "_rule_version_mismatch"
    "_rule_unknown"
)
