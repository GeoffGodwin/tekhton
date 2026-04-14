#!/usr/bin/env bash
# =============================================================================
# 003_to_031.sh — V3.0 → V3.1 migration
#
# Moves Tekhton-managed files from the project root into .tekhton/ directory.
# Uses git mv for tracked files, plain mv otherwise. Idempotent.
#
# Part of Tekhton migration framework — sourced by lib/migrate.sh
# =============================================================================
set -euo pipefail

migration_version() { echo "3.1"; }

migration_description() {
    echo "Move Tekhton-managed files from project root into .tekhton/"
}

migration_check() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"

    [[ -f "$conf_file" ]] || return 1

    if grep -q '^TEKHTON_DIR=' "$conf_file" 2>/dev/null; then
        return 1
    fi
    if [[ -d "${project_dir}/.tekhton" ]] && [[ -f "${project_dir}/.tekhton/DRIFT_LOG.md" || -f "${project_dir}/.tekhton/CODER_SUMMARY.md" ]]; then
        return 1
    fi
    return 0
}

migration_apply() {
    local project_dir="$1"
    local tekhton_dir="${project_dir}/.tekhton"
    mkdir -p "$tekhton_dir"

    local files=(
        ARCHITECTURE_LOG.md DRIFT_LOG.md HUMAN_ACTION_REQUIRED.md
        NON_BLOCKING_LOG.md MILESTONE_ARCHIVE.md SECURITY_NOTES.md
        SECURITY_REPORT.md INTAKE_REPORT.md TESTER_PREFLIGHT.md
        TEST_AUDIT_REPORT.md HEALTH_REPORT.md DESIGN.md
        CODER_SUMMARY.md REVIEWER_REPORT.md TESTER_REPORT.md
        JR_CODER_SUMMARY.md BUILD_ERRORS.md BUILD_RAW_ERRORS.txt
        UI_TEST_ERRORS.md PREFLIGHT_ERRORS.md DIAGNOSIS.md
        CLARIFICATIONS.md SPECIALIST_REPORT.md UI_VALIDATION_REPORT.md
        PREFLIGHT_REPORT.md
        SCOUT_REPORT.md ARCHITECT_PLAN.md CLEANUP_REPORT.md
        DRIFT_ARCHIVE.md PROJECT_INDEX.md REPLAN_DELTA.md MERGE_CONTEXT.md
    )

    local f src dst
    for f in "${files[@]}"; do
        src="${project_dir}/${f}"
        dst="${tekhton_dir}/${f}"
        [[ -e "$src" ]] || continue
        [[ -e "$dst" ]] && continue
        _move_preserving_history "$src" "$dst" "$project_dir"
    done

    # HUMAN_NOTES.md + all its backup variants
    local hn
    for hn in "${project_dir}/HUMAN_NOTES.md"*; do
        [[ -e "$hn" ]] || continue
        local bn
        bn=$(basename "$hn")
        [[ -e "${tekhton_dir}/${bn}" ]] && continue
        _move_preserving_history "$hn" "${tekhton_dir}/${bn}" "$project_dir"
    done

    return 0
}

_move_preserving_history() {
    local src="$1" dst="$2" project_dir="$3"
    local rel
    rel="${src#"${project_dir}/"}"
    if ( cd "$project_dir" && git ls-files --error-unmatch -- "$rel" ) &>/dev/null; then
        ( cd "$project_dir" && git mv -- "$rel" "${dst#"${project_dir}/"}" )
    else
        mv -- "$src" "$dst"
    fi
}
