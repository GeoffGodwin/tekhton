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
#   _rule_turn_exhaustion     — Agent max-turns without completion (fallback)
#   _rule_split_depth         — MILESTONE_MAX_SPLIT_DEPTH exceeded
#   _rule_transient_error     — Transient API errors
#   _rule_test_audit_failure  — Test audit NEEDS_WORK after max rework cycles
#   _rule_migration_crash     — Failed migration (LAST_FAILURE_CONTEXT or backups)
#   _rule_version_mismatch    — Project config version behind running Tekhton
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

# _rule_migration_crash
# Detect failed migration via LAST_FAILURE_CONTEXT or backup dirs.
_rule_migration_crash() {
    local failure_ctx="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
    if [[ -f "$failure_ctx" ]]; then
        local class
        class=$(grep -oP '"classification"\s*:\s*"\K[^"]+' "$failure_ctx" 2>/dev/null || true)
        if [[ "$class" = "MIGRATION_FAILURE" ]]; then
            local from_ver to_ver
            from_ver=$(grep -oP '"migration_from"\s*:\s*"\K[^"]+' "$failure_ctx" 2>/dev/null || true)
            to_ver=$(grep -oP '"migration_to"\s*:\s*"\K[^"]+' "$failure_ctx" 2>/dev/null || true)
            DIAG_CLASSIFICATION="MIGRATION_FAILURE"
            DIAG_CONFIDENCE="high"
            DIAG_SUGGESTIONS=(
                "Migration from V${from_ver:-?} to V${to_ver:-?} failed."
                "This usually happens when running express mode (no pipeline.conf) against an older Tekhton version."
                "Options:"
                "  1. Rollback the failed migration: tekhton --migrate --rollback"
                "  2. Initialize the project properly: tekhton --init"
                "  3. If already rolled back, re-run your task — the fix should prevent recurrence"
            )
            return 0
        fi
    fi

    local backup_base="${PROJECT_DIR:-.}/${MIGRATION_BACKUP_DIR:-.claude/migration-backups}"
    if compgen -G "${backup_base}/pre-*" >/dev/null 2>&1; then
        local conf_file="${PROJECT_DIR:-.}/.claude/pipeline.conf"
        if [[ ! -f "$conf_file" ]] || ! grep -q '^TEKHTON_CONFIG_VERSION=' "$conf_file" 2>/dev/null; then
            DIAG_CLASSIFICATION="MIGRATION_FAILURE"
            DIAG_CONFIDENCE="medium"
            DIAG_SUGGESTIONS=(
                "A migration backup exists but the migration did not complete."
                "Options:"
                "  1. Rollback: tekhton --migrate --rollback"
                "  2. Retry migration: tekhton --migrate"
                "  3. Initialize fresh: tekhton --init"
            )
            return 0
        fi
    fi

    return 1
}

# _rule_version_mismatch
# Detect project config version behind running Tekhton version.
_rule_version_mismatch() {
    local conf_file="${PROJECT_DIR:-.}/.claude/pipeline.conf"
    [[ -f "$conf_file" ]] || return 1

    command -v detect_config_version &>/dev/null || return 1

    local config_ver
    config_ver=$(detect_config_version "${PROJECT_DIR:-.}" 2>/dev/null || echo "")
    [[ -n "$config_ver" ]] || return 1

    local running_ver="${TEKHTON_VERSION%.*}"
    running_ver="${running_ver:-0.0}"

    command -v _version_lt &>/dev/null || return 1
    _version_lt "$config_ver" "$running_ver" || return 1

    # shellcheck disable=SC2034  # DIAG_* globals read by lib/diagnose.sh
    DIAG_CLASSIFICATION="VERSION_MISMATCH"
    # shellcheck disable=SC2034
    DIAG_CONFIDENCE="medium"
    # shellcheck disable=SC2034
    DIAG_SUGGESTIONS=(
        "Project config is V${config_ver} but Tekhton is V${running_ver}."
        "This may cause features to not work as expected."
        "Run: tekhton --migrate"
    )
    return 0
}
