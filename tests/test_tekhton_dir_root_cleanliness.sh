#!/usr/bin/env bash
# =============================================================================
# test_tekhton_dir_root_cleanliness.sh — Verify _FILE defaults resolve under TEKHTON_DIR
#
# Sources config_defaults.sh and checks that every *_FILE variable whose default
# is a Tekhton-managed artifact resolves under ${TEKHTON_DIR}/, not project root.
# Catches regressions where a new _FILE variable defaults to a bare filename.
#
# Exclusions: role files (.claude/agents/*), project-root files (CLAUDE.md,
# README.md, CHANGELOG.md), infrastructure files (.claude/*), and optional
# user-configured files that default to empty.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Source config_defaults.sh in a subshell with minimal stubs
_output=$(
    _clamp_config_value() { :; }
    _clamp_config_float() { :; }
    export -f _clamp_config_value _clamp_config_float
    # shellcheck disable=SC2034  # used by config_defaults.sh when sourced
    CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
    # shellcheck disable=SC2034
    CODER_MAX_TURNS=80
    # shellcheck disable=SC2034
    ARCHITECT_MAX_TURNS=25
    # shellcheck disable=SC1091
    source "${TEKHTON_HOME}/lib/config_defaults.sh"
    # Emit TEKHTON_DIR (to verify the default) then all *_FILE variables.
    # Exclude underscore-prefixed names (_FOO_FILE) — those are internal
    # pipeline state variables set at runtime (e.g. _REPO_MAP_CACHE_FILE
    # from indexer.sh), not config defaults.
    echo "TEKHTON_DIR_DEFAULT=${TEKHTON_DIR}"
    compgen -v | grep '_FILE$' | grep -v '^_' | while read -r varname; do
        echo "${varname}=${!varname}"
    done
)

# Extract the TEKHTON_DIR default from config_defaults.sh
TEKHTON_DIR_DEFAULT=$(echo "$_output" | grep '^TEKHTON_DIR_DEFAULT=' | cut -d'=' -f2)
_file_vars=$(echo "$_output" | grep -v '^TEKHTON_DIR_DEFAULT=')

# Files intentionally at project root or under .claude/ (not .tekhton/)
declare -A EXCLUDED=(
    [PIPELINE_STATE_FILE]=1
    [CODER_ROLE_FILE]=1
    [REVIEWER_ROLE_FILE]=1
    [TESTER_ROLE_FILE]=1
    [JR_CODER_ROLE_FILE]=1
    [ARCHITECT_ROLE_FILE]=1
    [SECURITY_ROLE_FILE]=1
    [INTAKE_ROLE_FILE]=1
    [PROJECT_RULES_FILE]=1
    [ARCHITECTURE_FILE]=1
    [GLOSSARY_FILE]=1
    [DEPENDENCY_CONSTRAINTS_FILE]=1
    [SECURITY_WAIVER_FILE]=1
    [CHECKPOINT_FILE]=1
    [CAUSAL_LOG_FILE]=1
    [HEALTH_BASELINE_FILE]=1
    [DOCS_README_FILE]=1
    [CHANGELOG_FILE]=1
    [LOG_FILE]=1
    # Runtime variable set by indexer_history.sh — lives in .claude/index/ by design,
    # not a config default from config_defaults.sh.
    [TEST_SYMBOL_MAP_FILE]=1
)

# Patterns that are not file paths
declare -A NOT_PATHS=(
)

while IFS='=' read -r varname value; do
    [[ -z "$varname" ]] && continue
    # Skip excluded variables
    [[ -n "${EXCLUDED[$varname]:-}" ]] && continue
    # Skip non-path patterns
    [[ -n "${NOT_PATHS[$varname]:-}" ]] && continue
    # Skip empty defaults (optional user-configured files)
    [[ -z "$value" ]] && continue

    if [[ "$value" == "${TEKHTON_DIR_DEFAULT}"/* ]]; then
        pass "${varname}=${value} resolves under TEKHTON_DIR"
    else
        fail "${varname}=${value} does NOT resolve under ${TEKHTON_DIR_DEFAULT}/"
    fi
done <<< "$_file_vars"

# Verify we actually checked some variables (guard against empty output)
if [[ "$PASS" -eq 0 ]] && [[ "$FAIL" -eq 0 ]]; then
    fail "No _FILE variables found — config_defaults.sh may not have loaded"
fi

# Verify at least the core artifact files were checked
core_checked=0
for core_var in CODER_SUMMARY_FILE REVIEWER_REPORT_FILE TESTER_REPORT_FILE \
                DRIFT_LOG_FILE HUMAN_NOTES_FILE NON_BLOCKING_LOG_FILE; do
    if echo "$_file_vars" | grep -q "^${core_var}="; then
        core_checked=$((core_checked + 1))
    else
        fail "Core variable ${core_var} not found in config_defaults.sh output"
    fi
done

if [[ "$core_checked" -ge 6 ]]; then
    pass "All 6 core artifact _FILE variables were checked"
fi

echo
echo "────────────────────────────────────────"
echo "  Root cleanliness: Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
