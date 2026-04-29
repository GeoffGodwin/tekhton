#!/usr/bin/env bash
# =============================================================================
# 032_to_033.sh — V3.2 → V3.3 migration
#
# Cleans up stale path overrides in pipeline.conf for artifact files that were
# relocated from the project root into .tekhton/ by the V3.1 migration
# (003_to_031.sh). The earlier migration moved the *files* but left explicit
# `KEY="X.md"` overrides in pipeline.conf intact, so the runtime kept writing
# those artifacts back to the project root via ${PROJECT_DIR}/${KEY}.
#
# This migration comments out any such override whose value is the bare
# original root filename (e.g. NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md").
# User-customized paths (any value containing a slash, or pointing inside
# .tekhton/) are preserved untouched.
#
# Part of Tekhton migration framework — sourced by lib/migrate.sh
# =============================================================================
set -euo pipefail

migration_version() { echo "3.3"; }

migration_description() {
    echo "Remove stale root-path overrides in pipeline.conf for files moved to .tekhton/"
}

# _033_stale_keys — Echoes one "KEY|original_basename" pair per line.
# These are the artifact files relocated by the V3.1 migration whose
# config keys, when set to the bare root filename, are now stale.
_033_stale_keys() {
    cat << 'EOF'
NON_BLOCKING_LOG_FILE|NON_BLOCKING_LOG.md
HUMAN_ACTION_FILE|HUMAN_ACTION_REQUIRED.md
DRIFT_LOG_FILE|DRIFT_LOG.md
ARCHITECTURE_LOG_FILE|ARCHITECTURE_LOG.md
DESIGN_FILE|DESIGN.md
MILESTONE_ARCHIVE_FILE|MILESTONE_ARCHIVE.md
SECURITY_NOTES_FILE|SECURITY_NOTES.md
SECURITY_REPORT_FILE|SECURITY_REPORT.md
INTAKE_REPORT_FILE|INTAKE_REPORT.md
HEALTH_REPORT_FILE|HEALTH_REPORT.md
HUMAN_NOTES_FILE|HUMAN_NOTES.md
DOCS_AGENT_REPORT_FILE|DOCS_AGENT_REPORT.md
TEST_AUDIT_REPORT_FILE|TEST_AUDIT_REPORT.md
TDD_PREFLIGHT_FILE|TESTER_PREFLIGHT.md
CODER_SUMMARY_FILE|CODER_SUMMARY.md
REVIEWER_REPORT_FILE|REVIEWER_REPORT.md
TESTER_REPORT_FILE|TESTER_REPORT.md
JR_CODER_SUMMARY_FILE|JR_CODER_SUMMARY.md
BUILD_ERRORS_FILE|BUILD_ERRORS.md
BUILD_RAW_ERRORS_FILE|BUILD_RAW_ERRORS.txt
UI_TEST_ERRORS_FILE|UI_TEST_ERRORS.md
PREFLIGHT_ERRORS_FILE|PREFLIGHT_ERRORS.md
PREFLIGHT_REPORT_FILE|PREFLIGHT_REPORT.md
DIAGNOSIS_FILE|DIAGNOSIS.md
CLARIFICATIONS_FILE|CLARIFICATIONS.md
SPECIALIST_REPORT_FILE|SPECIALIST_REPORT.md
UI_VALIDATION_REPORT_FILE|UI_VALIDATION_REPORT.md
SCOUT_REPORT_FILE|SCOUT_REPORT.md
ARCHITECT_PLAN_FILE|ARCHITECT_PLAN.md
CLEANUP_REPORT_FILE|CLEANUP_REPORT.md
DRIFT_ARCHIVE_FILE|DRIFT_ARCHIVE.md
PROJECT_INDEX_FILE|PROJECT_INDEX.md
REPLAN_DELTA_FILE|REPLAN_DELTA.md
MERGE_CONTEXT_FILE|MERGE_CONTEXT.md
EOF
}

# _033_load_pairs ARRAY_NAME
# Populates the named associative array with KEY → original_basename pairs.
_033_load_pairs() {
    local -n target="$1"
    local k v
    while IFS='|' read -r k v; do
        # shellcheck disable=SC2034  # target is a nameref to caller's array
        [[ -n "$k" ]] && target["$k"]="$v"
    done < <(_033_stale_keys)
}

# _033_extract_value LINE
# Given a `KEY=VALUE` line (with optional surrounding quotes on VALUE),
# echoes the unquoted VALUE. Returns 1 if the line is not a KEY=VALUE form.
_033_extract_value() {
    local line="$1"
    [[ "$line" =~ ^[[:space:]]*[A-Z_][A-Z0-9_]*=(.*)$ ]] || return 1
    local val="${BASH_REMATCH[1]}"
    val="${val#\"}"; val="${val%\"}"
    val="${val#\'}"; val="${val%\'}"
    printf '%s' "$val"
}

# _033_match_stale_key LINE PAIRS_NAME
# If LINE is an active override of a known stale key with the bare original
# filename as its value, echoes the matched key on stdout and returns 0.
_033_match_stale_key() {
    local line="$1"
    local -n pairs_ref="$2"

    [[ "$line" =~ ^[[:space:]]*# ]] && return 1
    [[ -z "${line//[[:space:]]/}" ]] && return 1

    local key expected val
    for key in "${!pairs_ref[@]}"; do
        if [[ "$line" =~ ^[[:space:]]*${key}= ]]; then
            val=$(_033_extract_value "$line") || return 1
            expected="${pairs_ref[$key]}"
            if [[ "$val" == "$expected" ]]; then
                printf '%s' "$key"
                return 0
            fi
            return 1
        fi
    done

    return 1
}

# migration_check PROJECT_DIR
# Returns 0 if pipeline.conf contains at least one stale root-path override.
migration_check() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"

    [[ -f "$conf_file" ]] || return 1

    local -A pairs=()
    _033_load_pairs pairs

    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if _033_match_stale_key "$line" pairs >/dev/null; then
            return 0
        fi
    done < "$conf_file"

    return 1
}

# migration_apply PROJECT_DIR
# Rewrites pipeline.conf, commenting out stale root-path overrides and
# inserting a marker comment above each one.
migration_apply() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"

    [[ -f "$conf_file" ]] || return 1

    local -A pairs=()
    _033_load_pairs pairs

    local tmpfile
    tmpfile=$(mktemp "${conf_file}.XXXXXX")
    local commented=0
    local line key basename
    local -a commented_keys=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        if key=$(_033_match_stale_key "$line" pairs); then
            basename="${pairs[$key]}"
            # shellcheck disable=SC2016  # ${TEKHTON_DIR} is a literal in the marker text
            printf '# V3.3 migration: stale root-path override removed (defaults to ${TEKHTON_DIR}/%s)\n' \
                "$basename" >> "$tmpfile"
            printf '# %s\n' "$line" >> "$tmpfile"
            commented_keys+=("$key")
            commented=$((commented + 1))
        else
            printf '%s\n' "$line" >> "$tmpfile"
        fi
    done < "$conf_file"

    mv "$tmpfile" "$conf_file"

    if (( commented > 0 )); then
        log "Commented out ${commented} stale root-path override(s) in pipeline.conf:"
        local k
        for k in "${commented_keys[@]}"; do
            log "  - ${k}"
        done
        _033_warn_orphan_root_files "$project_dir" pairs "${commented_keys[@]}"
    fi

    return 0
}

# _033_warn_orphan_root_files PROJECT_DIR PAIRS_NAME KEY [KEY...]
# For each commented-out key, warn the user if a stale root file exists.
_033_warn_orphan_root_files() {
    local project_dir="$1"; shift
    local -n pairs_ref="$1"; shift
    local tekhton_dir="${project_dir}/.tekhton"
    local key root_name root_path tekhton_path

    for key in "$@"; do
        root_name="${pairs_ref[$key]:-}"
        [[ -z "$root_name" ]] && continue
        root_path="${project_dir}/${root_name}"
        tekhton_path="${tekhton_dir}/${root_name}"
        if [[ -f "$root_path" ]] && [[ -f "$tekhton_path" ]]; then
            warn "  Both ${root_name} and .tekhton/${root_name} exist — review and consolidate manually."
        elif [[ -f "$root_path" ]] && [[ ! -f "$tekhton_path" ]]; then
            warn "  ${root_name} still at project root — move to .tekhton/${root_name} when ready."
        fi
    done
}
