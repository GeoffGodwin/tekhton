#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# diagnose_rules_migration.sh — Migration & version-mismatch diagnose rules
#
# Sourced by lib/diagnose_rules_extra.sh — do not run directly.
# Expects: _DIAG_* module state populated by _read_diagnostic_context()
# Expects: DIAG_CLASSIFICATION, DIAG_CONFIDENCE, DIAG_SUGGESTIONS (shared globals)
# Expects: PROJECT_DIR, MIGRATION_BACKUP_DIR (set by caller)
#
# Provides:
#   _rule_migration_crash  — Failed migration (LAST_FAILURE_CONTEXT or backups)
#   _rule_version_mismatch — Project config version behind running Tekhton
#
# Extracted from diagnose_rules_extra.sh under M133 to keep that file under
# the 300-line ceiling after _rule_mixed_classification was added.
# =============================================================================

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
