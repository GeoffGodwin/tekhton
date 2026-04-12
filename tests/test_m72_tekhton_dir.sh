#!/usr/bin/env bash
# =============================================================================
# test_m72_tekhton_dir.sh — Tests for M72: .tekhton/ directory migration
#
# Covers:
#   - TEKHTON_DIR default in config_defaults.sh
#   - TEKHTON_DIR declared before _FILE variables
#   - All _FILE variables default under ${TEKHTON_DIR}
#   - PROJECT_RULES_FILE stays at CLAUDE.md (no .tekhton/ prefix)
#   - migrations/003_to_031.sh: version, check, apply, idempotency
#   - git mv vs plain mv for tracked vs untracked files
#   - HUMAN_NOTES.md* glob handling
#   - CLAUDE.md exclusion from migration
#   - Destination-exists guard (no double-move)
#   - Migration discovery includes 3.1 in _list_migration_scripts
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$expected" = "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: ${label}: expected '${expected}', got '${actual}'"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: ${label}: expected to contain '${needle}'"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: ${label}: expected NOT to contain '${needle}'"
    fi
}

assert_file_exists() {
    local label="$1" filepath="$2"
    TOTAL=$((TOTAL + 1))
    if [[ -f "$filepath" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: ${label}: file does not exist: ${filepath}"
    fi
}

assert_file_not_exists() {
    local label="$1" filepath="$2"
    TOTAL=$((TOTAL + 1))
    if [[ ! -f "$filepath" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: ${label}: file unexpectedly exists: ${filepath}"
    fi
}

assert_dir_exists() {
    local label="$1" dirpath="$2"
    TOTAL=$((TOTAL + 1))
    if [[ -d "$dirpath" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: ${label}: dir does not exist: ${dirpath}"
    fi
}

# Source common.sh for log/warn/error stubs used by migration framework
source "${TEKHTON_HOME}/lib/common.sh"

# =============================================================================
# Suite 1: config_defaults.sh — TEKHTON_DIR and _FILE defaults
# =============================================================================
echo "--- Suite 1: config_defaults.sh TEKHTON_DIR and _FILE defaults ---"

# Source config_defaults.sh in a clean subshell to test defaults from scratch.
# Stub _clamp_config_value (defined in config.sh, called at end of config_defaults.sh).
# Unset everything first so we read the actual fallback defaults.
defaults_output=$(env -i bash --norc --noprofile -c "
    set -euo pipefail
    _clamp_config_value() { return 0; }
    _clamp_config_float() { return 0; }
    source '${TEKHTON_HOME}/lib/config_defaults.sh'
    echo \"TEKHTON_DIR=\${TEKHTON_DIR}\"
    echo \"CODER_SUMMARY_FILE=\${CODER_SUMMARY_FILE}\"
    echo \"REVIEWER_REPORT_FILE=\${REVIEWER_REPORT_FILE}\"
    echo \"TESTER_REPORT_FILE=\${TESTER_REPORT_FILE}\"
    echo \"JR_CODER_SUMMARY_FILE=\${JR_CODER_SUMMARY_FILE}\"
    echo \"BUILD_ERRORS_FILE=\${BUILD_ERRORS_FILE}\"
    echo \"BUILD_RAW_ERRORS_FILE=\${BUILD_RAW_ERRORS_FILE}\"
    echo \"UI_TEST_ERRORS_FILE=\${UI_TEST_ERRORS_FILE}\"
    echo \"PREFLIGHT_ERRORS_FILE=\${PREFLIGHT_ERRORS_FILE}\"
    echo \"DIAGNOSIS_FILE=\${DIAGNOSIS_FILE}\"
    echo \"CLARIFICATIONS_FILE=\${CLARIFICATIONS_FILE}\"
    echo \"HUMAN_NOTES_FILE=\${HUMAN_NOTES_FILE}\"
    echo \"SPECIALIST_REPORT_FILE=\${SPECIALIST_REPORT_FILE}\"
    echo \"UI_VALIDATION_REPORT_FILE=\${UI_VALIDATION_REPORT_FILE}\"
    echo \"DESIGN_FILE=\${DESIGN_FILE}\"
    echo \"ARCHITECTURE_LOG_FILE=\${ARCHITECTURE_LOG_FILE}\"
    echo \"DRIFT_LOG_FILE=\${DRIFT_LOG_FILE}\"
    echo \"HUMAN_ACTION_FILE=\${HUMAN_ACTION_FILE}\"
    echo \"NON_BLOCKING_LOG_FILE=\${NON_BLOCKING_LOG_FILE}\"
    echo \"MILESTONE_ARCHIVE_FILE=\${MILESTONE_ARCHIVE_FILE}\"
    echo \"SECURITY_NOTES_FILE=\${SECURITY_NOTES_FILE}\"
    echo \"SECURITY_REPORT_FILE=\${SECURITY_REPORT_FILE}\"
    echo \"INTAKE_REPORT_FILE=\${INTAKE_REPORT_FILE}\"
    echo \"TDD_PREFLIGHT_FILE=\${TDD_PREFLIGHT_FILE}\"
    echo \"TEST_AUDIT_REPORT_FILE=\${TEST_AUDIT_REPORT_FILE}\"
    echo \"HEALTH_REPORT_FILE=\${HEALTH_REPORT_FILE}\"
    echo \"PROJECT_RULES_FILE=\${PROJECT_RULES_FILE}\"
")

# 1.1: TEKHTON_DIR defaults to .tekhton
assert_contains "1.1 TEKHTON_DIR defaults to .tekhton" \
    "TEKHTON_DIR=.tekhton" "$defaults_output"

# 1.2–1.16: _FILE variables default under .tekhton/
assert_contains "1.2 CODER_SUMMARY_FILE under .tekhton/" \
    "CODER_SUMMARY_FILE=.tekhton/CODER_SUMMARY.md" "$defaults_output"
assert_contains "1.3 REVIEWER_REPORT_FILE under .tekhton/" \
    "REVIEWER_REPORT_FILE=.tekhton/REVIEWER_REPORT.md" "$defaults_output"
assert_contains "1.4 TESTER_REPORT_FILE under .tekhton/" \
    "TESTER_REPORT_FILE=.tekhton/TESTER_REPORT.md" "$defaults_output"
assert_contains "1.5 JR_CODER_SUMMARY_FILE under .tekhton/" \
    "JR_CODER_SUMMARY_FILE=.tekhton/JR_CODER_SUMMARY.md" "$defaults_output"
assert_contains "1.6 BUILD_ERRORS_FILE under .tekhton/" \
    "BUILD_ERRORS_FILE=.tekhton/BUILD_ERRORS.md" "$defaults_output"
assert_contains "1.7 BUILD_RAW_ERRORS_FILE under .tekhton/" \
    "BUILD_RAW_ERRORS_FILE=.tekhton/BUILD_RAW_ERRORS.txt" "$defaults_output"
assert_contains "1.8 UI_TEST_ERRORS_FILE under .tekhton/" \
    "UI_TEST_ERRORS_FILE=.tekhton/UI_TEST_ERRORS.md" "$defaults_output"
assert_contains "1.9 PREFLIGHT_ERRORS_FILE under .tekhton/" \
    "PREFLIGHT_ERRORS_FILE=.tekhton/PREFLIGHT_ERRORS.md" "$defaults_output"
assert_contains "1.10 DIAGNOSIS_FILE under .tekhton/" \
    "DIAGNOSIS_FILE=.tekhton/DIAGNOSIS.md" "$defaults_output"
assert_contains "1.11 CLARIFICATIONS_FILE under .tekhton/" \
    "CLARIFICATIONS_FILE=.tekhton/CLARIFICATIONS.md" "$defaults_output"
assert_contains "1.12 HUMAN_NOTES_FILE under .tekhton/" \
    "HUMAN_NOTES_FILE=.tekhton/HUMAN_NOTES.md" "$defaults_output"
assert_contains "1.13 SPECIALIST_REPORT_FILE under .tekhton/" \
    "SPECIALIST_REPORT_FILE=.tekhton/SPECIALIST_REPORT.md" "$defaults_output"
assert_contains "1.14 UI_VALIDATION_REPORT_FILE under .tekhton/" \
    "UI_VALIDATION_REPORT_FILE=.tekhton/UI_VALIDATION_REPORT.md" "$defaults_output"
assert_contains "1.15 DESIGN_FILE under .tekhton/" \
    "DESIGN_FILE=.tekhton/DESIGN.md" "$defaults_output"
assert_contains "1.16 ARCHITECTURE_LOG_FILE under .tekhton/" \
    "ARCHITECTURE_LOG_FILE=.tekhton/ARCHITECTURE_LOG.md" "$defaults_output"
assert_contains "1.17 DRIFT_LOG_FILE under .tekhton/" \
    "DRIFT_LOG_FILE=.tekhton/DRIFT_LOG.md" "$defaults_output"
assert_contains "1.18 HUMAN_ACTION_FILE under .tekhton/" \
    "HUMAN_ACTION_FILE=.tekhton/HUMAN_ACTION_REQUIRED.md" "$defaults_output"
assert_contains "1.19 NON_BLOCKING_LOG_FILE under .tekhton/" \
    "NON_BLOCKING_LOG_FILE=.tekhton/NON_BLOCKING_LOG.md" "$defaults_output"
assert_contains "1.20 MILESTONE_ARCHIVE_FILE under .tekhton/" \
    "MILESTONE_ARCHIVE_FILE=.tekhton/MILESTONE_ARCHIVE.md" "$defaults_output"
assert_contains "1.21 SECURITY_NOTES_FILE under .tekhton/" \
    "SECURITY_NOTES_FILE=.tekhton/SECURITY_NOTES.md" "$defaults_output"
assert_contains "1.22 SECURITY_REPORT_FILE under .tekhton/" \
    "SECURITY_REPORT_FILE=.tekhton/SECURITY_REPORT.md" "$defaults_output"
assert_contains "1.23 INTAKE_REPORT_FILE under .tekhton/" \
    "INTAKE_REPORT_FILE=.tekhton/INTAKE_REPORT.md" "$defaults_output"
assert_contains "1.24 TDD_PREFLIGHT_FILE under .tekhton/" \
    "TDD_PREFLIGHT_FILE=.tekhton/TESTER_PREFLIGHT.md" "$defaults_output"
assert_contains "1.25 TEST_AUDIT_REPORT_FILE under .tekhton/" \
    "TEST_AUDIT_REPORT_FILE=.tekhton/TEST_AUDIT_REPORT.md" "$defaults_output"
assert_contains "1.26 HEALTH_REPORT_FILE under .tekhton/" \
    "HEALTH_REPORT_FILE=.tekhton/HEALTH_REPORT.md" "$defaults_output"

# 1.27: PROJECT_RULES_FILE stays at CLAUDE.md (not under .tekhton/)
assert_contains "1.27 PROJECT_RULES_FILE stays CLAUDE.md" \
    "PROJECT_RULES_FILE=CLAUDE.md" "$defaults_output"
assert_not_contains "1.28 PROJECT_RULES_FILE not under .tekhton/" \
    "PROJECT_RULES_FILE=.tekhton/" "$defaults_output"

# =============================================================================
# Suite 2: config_defaults.sh — TEKHTON_DIR declared before _FILE variables
# =============================================================================
echo "--- Suite 2: TEKHTON_DIR declared before _FILE variables ---"

# TEKHTON_DIR must appear before the first _FILE that references it.
# Parse line numbers from the file and assert ordering.
tekhton_dir_line=$(grep -n '^: "${TEKHTON_DIR' \
    "${TEKHTON_HOME}/lib/config_defaults.sh" | head -1 | cut -d: -f1)

# Find the first _FILE variable that uses TEKHTON_DIR
first_file_line=$(grep -n 'TEKHTON_DIR}/' \
    "${TEKHTON_HOME}/lib/config_defaults.sh" | head -1 | cut -d: -f1)

TOTAL=$((TOTAL + 1))
if [[ -n "$tekhton_dir_line" ]] && [[ -n "$first_file_line" ]] && \
   [[ "$tekhton_dir_line" -lt "$first_file_line" ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 2.1 TEKHTON_DIR (line ${tekhton_dir_line}) must precede first _FILE var (line ${first_file_line})"
fi

# =============================================================================
# Suite 3: config_defaults.sh — custom TEKHTON_DIR is respected
# =============================================================================
echo "--- Suite 3: custom TEKHTON_DIR is respected ---"

custom_output=$(env -i TEKHTON_DIR="my-artifacts" bash --norc --noprofile -c "
    set -euo pipefail
    _clamp_config_value() { return 0; }
    _clamp_config_float() { return 0; }
    source '${TEKHTON_HOME}/lib/config_defaults.sh'
    echo \"CODER_SUMMARY_FILE=\${CODER_SUMMARY_FILE}\"
    echo \"DRIFT_LOG_FILE=\${DRIFT_LOG_FILE}\"
    echo \"HUMAN_NOTES_FILE=\${HUMAN_NOTES_FILE}\"
")

assert_contains "3.1 custom TEKHTON_DIR respected for CODER_SUMMARY_FILE" \
    "CODER_SUMMARY_FILE=my-artifacts/CODER_SUMMARY.md" "$custom_output"
assert_contains "3.2 custom TEKHTON_DIR respected for DRIFT_LOG_FILE" \
    "DRIFT_LOG_FILE=my-artifacts/DRIFT_LOG.md" "$custom_output"
assert_contains "3.3 custom TEKHTON_DIR respected for HUMAN_NOTES_FILE" \
    "HUMAN_NOTES_FILE=my-artifacts/HUMAN_NOTES.md" "$custom_output"

# =============================================================================
# Suite 4: 003_to_031.sh — metadata functions
# =============================================================================
echo "--- Suite 4: 003_to_031.sh metadata ---"

source "${TEKHTON_HOME}/migrations/003_to_031.sh"

# Rename to avoid colliding with 002_to_003.sh if already sourced
migration_ver=$(migration_version)
assert_eq "4.1 migration_version returns 3.1" "3.1" "$migration_ver"

migration_desc=$(migration_description)
TOTAL=$((TOTAL + 1))
if [[ -n "$migration_desc" ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 4.2 migration_description should be non-empty"
fi

# =============================================================================
# Suite 5: 003_to_031.sh — migration_check
# =============================================================================
echo "--- Suite 5: 003_to_031.sh migration_check ---"

# 5.1: Check needed when pipeline.conf exists without TEKHTON_DIR or .tekhton/ marker
s5_plain="$TMPDIR_BASE/s5_plain"
mkdir -p "${s5_plain}/.claude"
cat > "${s5_plain}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-v3"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="true"
TEKHTON_CONFIG_VERSION="3.0"
EOF
migration_check "$s5_plain" && r="needed" || r="applied"
assert_eq "5.1 check needed for V3.0 project" "needed" "$r"

# 5.2: Check skipped when TEKHTON_DIR= line present in pipeline.conf
s5_withdir="$TMPDIR_BASE/s5_withdir"
mkdir -p "${s5_withdir}/.claude"
cat > "${s5_withdir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-withdir"
TEKHTON_DIR=".tekhton"
EOF
migration_check "$s5_withdir" && r="needed" || r="applied"
assert_eq "5.2 check skipped when TEKHTON_DIR= in conf" "applied" "$r"

# 5.3: Check skipped when .tekhton/DRIFT_LOG.md exists (already migrated by content)
s5_migrated="$TMPDIR_BASE/s5_migrated"
mkdir -p "${s5_migrated}/.claude" "${s5_migrated}/.tekhton"
cat > "${s5_migrated}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-migrated"
ANALYZE_CMD="true"
EOF
touch "${s5_migrated}/.tekhton/DRIFT_LOG.md"
migration_check "$s5_migrated" && r="needed" || r="applied"
assert_eq "5.3 check skipped when .tekhton/DRIFT_LOG.md exists" "applied" "$r"

# 5.4: Check skipped when .tekhton/CODER_SUMMARY.md exists
s5_coder="$TMPDIR_BASE/s5_coder"
mkdir -p "${s5_coder}/.claude" "${s5_coder}/.tekhton"
cat > "${s5_coder}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-coder"
ANALYZE_CMD="true"
EOF
touch "${s5_coder}/.tekhton/CODER_SUMMARY.md"
migration_check "$s5_coder" && r="needed" || r="applied"
assert_eq "5.4 check skipped when .tekhton/CODER_SUMMARY.md exists" "applied" "$r"

# 5.5: Check returns 1 (not needed) when no pipeline.conf
s5_noconf="$TMPDIR_BASE/s5_noconf"
mkdir -p "$s5_noconf"
migration_check "$s5_noconf" && r="needed" || r="applied"
assert_eq "5.5 check returns not-needed when no pipeline.conf" "applied" "$r"

# =============================================================================
# Suite 6: 003_to_031.sh — migration_apply moves files (plain mv, untracked)
# =============================================================================
echo "--- Suite 6: 003_to_031.sh migration_apply (untracked files) ---"

s6_dir="$TMPDIR_BASE/s6_plain_mv"
mkdir -p "${s6_dir}/.claude"
cat > "${s6_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-apply"
ANALYZE_CMD="true"
EOF

# Create a representative set of root-level files to be migrated
touch "${s6_dir}/CODER_SUMMARY.md"
touch "${s6_dir}/REVIEWER_REPORT.md"
touch "${s6_dir}/TESTER_REPORT.md"
touch "${s6_dir}/BUILD_ERRORS.md"
touch "${s6_dir}/DRIFT_LOG.md"
touch "${s6_dir}/HUMAN_NOTES.md"
touch "${s6_dir}/HUMAN_NOTES.md.bak"
touch "${s6_dir}/CLARIFICATIONS.md"
touch "${s6_dir}/DESIGN.md"
touch "${s6_dir}/DIAGNOSIS.md"

# Files that must NOT be migrated
echo "# Project rules" > "${s6_dir}/CLAUDE.md"
echo "# README" > "${s6_dir}/README.md"

migration_apply "$s6_dir"
rc=$?
assert_eq "6.1 migration_apply returns 0" "0" "$rc"

# Verify .tekhton/ directory created
assert_dir_exists "6.2 .tekhton/ dir created" "${s6_dir}/.tekhton"

# Verify files moved into .tekhton/
assert_file_exists "6.3 CODER_SUMMARY.md moved" "${s6_dir}/.tekhton/CODER_SUMMARY.md"
assert_file_exists "6.4 REVIEWER_REPORT.md moved" "${s6_dir}/.tekhton/REVIEWER_REPORT.md"
assert_file_exists "6.5 TESTER_REPORT.md moved" "${s6_dir}/.tekhton/TESTER_REPORT.md"
assert_file_exists "6.6 BUILD_ERRORS.md moved" "${s6_dir}/.tekhton/BUILD_ERRORS.md"
assert_file_exists "6.7 DRIFT_LOG.md moved" "${s6_dir}/.tekhton/DRIFT_LOG.md"
assert_file_exists "6.8 HUMAN_NOTES.md moved" "${s6_dir}/.tekhton/HUMAN_NOTES.md"
assert_file_exists "6.9 HUMAN_NOTES.md.bak moved" "${s6_dir}/.tekhton/HUMAN_NOTES.md.bak"
assert_file_exists "6.10 CLARIFICATIONS.md moved" "${s6_dir}/.tekhton/CLARIFICATIONS.md"
assert_file_exists "6.11 DESIGN.md moved" "${s6_dir}/.tekhton/DESIGN.md"
assert_file_exists "6.12 DIAGNOSIS.md moved" "${s6_dir}/.tekhton/DIAGNOSIS.md"

# Verify source files are gone from root
assert_file_not_exists "6.13 CODER_SUMMARY.md removed from root" "${s6_dir}/CODER_SUMMARY.md"
assert_file_not_exists "6.14 HUMAN_NOTES.md removed from root" "${s6_dir}/HUMAN_NOTES.md"
assert_file_not_exists "6.15 HUMAN_NOTES.md.bak removed from root" "${s6_dir}/HUMAN_NOTES.md.bak"

# Verify CLAUDE.md and README.md are NOT moved
assert_file_exists "6.16 CLAUDE.md stays at root" "${s6_dir}/CLAUDE.md"
assert_file_not_exists "6.17 CLAUDE.md not in .tekhton/" "${s6_dir}/.tekhton/CLAUDE.md"
assert_file_exists "6.18 README.md stays at root" "${s6_dir}/README.md"
assert_file_not_exists "6.19 README.md not in .tekhton/" "${s6_dir}/.tekhton/README.md"

# =============================================================================
# Suite 7: 003_to_031.sh — idempotency (run apply twice)
# =============================================================================
echo "--- Suite 7: 003_to_031.sh idempotency ---"

s7_dir="$TMPDIR_BASE/s7_idempotent"
mkdir -p "${s7_dir}/.claude"
cat > "${s7_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-idempotent"
ANALYZE_CMD="true"
EOF

touch "${s7_dir}/CODER_SUMMARY.md"
touch "${s7_dir}/DRIFT_LOG.md"

# First apply
migration_apply "$s7_dir"

# Second apply — must not fail
set +e
migration_apply "$s7_dir" 2>/dev/null
rc2=$?
set -e
assert_eq "7.1 second migration_apply returns 0" "0" "$rc2"

# Files still in .tekhton/ (not doubled)
assert_file_exists "7.2 CODER_SUMMARY.md still in .tekhton/ after re-apply" \
    "${s7_dir}/.tekhton/CODER_SUMMARY.md"
assert_file_not_exists "7.3 CODER_SUMMARY.md not back in root after re-apply" \
    "${s7_dir}/CODER_SUMMARY.md"

# =============================================================================
# Suite 8: 003_to_031.sh — skips non-existent source files gracefully
# =============================================================================
echo "--- Suite 8: 003_to_031.sh skips missing files ---"

s8_dir="$TMPDIR_BASE/s8_missing"
mkdir -p "${s8_dir}/.claude"
cat > "${s8_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-missing"
ANALYZE_CMD="true"
EOF

# Only create a subset of files — others don't exist
touch "${s8_dir}/REVIEWER_REPORT.md"
# CODER_SUMMARY.md intentionally absent

set +e
migration_apply "$s8_dir"
rc=$?
set -e
assert_eq "8.1 apply succeeds when only some files exist" "0" "$rc"
assert_file_exists "8.2 present file moved" "${s8_dir}/.tekhton/REVIEWER_REPORT.md"
assert_file_not_exists "8.3 absent file not created in .tekhton/" \
    "${s8_dir}/.tekhton/CODER_SUMMARY.md"

# =============================================================================
# Suite 9: 003_to_031.sh — git mv for tracked files
# =============================================================================
echo "--- Suite 9: 003_to_031.sh uses git mv for tracked files ---"

s9_dir="$TMPDIR_BASE/s9_git_mv"
mkdir -p "${s9_dir}/.claude"
cat > "${s9_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-git-mv"
ANALYZE_CMD="true"
EOF

# Init a git repo and commit the target files
( cd "$s9_dir"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "drift content" > DRIFT_LOG.md
  echo "reviewer content" > REVIEWER_REPORT.md
  git add DRIFT_LOG.md REVIEWER_REPORT.md
  git commit -q -m "add tekhton artifacts"
)

# Apply migration — should use git mv for tracked files
migration_apply "$s9_dir"

# Files should be under .tekhton/
assert_file_exists "9.1 DRIFT_LOG.md moved to .tekhton/" "${s9_dir}/.tekhton/DRIFT_LOG.md"
assert_file_exists "9.2 REVIEWER_REPORT.md moved to .tekhton/" "${s9_dir}/.tekhton/REVIEWER_REPORT.md"
assert_file_not_exists "9.3 DRIFT_LOG.md gone from root" "${s9_dir}/DRIFT_LOG.md"

# Verify git history preserved (file should be tracked at new path)
tracked=$(cd "$s9_dir" && git ls-files .tekhton/DRIFT_LOG.md)
TOTAL=$((TOTAL + 1))
if [[ -n "$tracked" ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 9.4 DRIFT_LOG.md should be tracked by git at new path"
fi

# =============================================================================
# Suite 10: 003_to_031.sh — plain mv for untracked files in git repo
# =============================================================================
echo "--- Suite 10: 003_to_031.sh plain mv for untracked files in git repo ---"

s10_dir="$TMPDIR_BASE/s10_plain_in_git"
mkdir -p "${s10_dir}/.claude"
cat > "${s10_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-plain-in-git"
ANALYZE_CMD="true"
EOF

( cd "$s10_dir"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "initial" > README.md
  git add README.md
  git commit -q -m "init"
)

# Add an untracked file (not committed to git)
echo "build errors" > "${s10_dir}/BUILD_ERRORS.md"

migration_apply "$s10_dir"

assert_file_exists "10.1 untracked BUILD_ERRORS.md moved to .tekhton/" \
    "${s10_dir}/.tekhton/BUILD_ERRORS.md"
assert_file_not_exists "10.2 untracked BUILD_ERRORS.md gone from root" \
    "${s10_dir}/BUILD_ERRORS.md"

# Verify it is NOT added to git index (plain mv doesn't stage)
tracked_build=$(cd "$s10_dir" && git ls-files .tekhton/BUILD_ERRORS.md)
TOTAL=$((TOTAL + 1))
if [[ -z "$tracked_build" ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 10.3 untracked file should not be staged in git after plain mv"
fi

# =============================================================================
# Suite 11: 003_to_031.sh — HUMAN_NOTES.md backup variants migrated
# =============================================================================
echo "--- Suite 11: HUMAN_NOTES.md backup variants ---"

s11_dir="$TMPDIR_BASE/s11_human_notes_bak"
mkdir -p "${s11_dir}/.claude"
cat > "${s11_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-notes-bak"
ANALYZE_CMD="true"
EOF

touch "${s11_dir}/HUMAN_NOTES.md"
touch "${s11_dir}/HUMAN_NOTES.md.bak"
touch "${s11_dir}/HUMAN_NOTES.md.back"
touch "${s11_dir}/HUMAN_NOTES.md.v1-backup"

migration_apply "$s11_dir"

assert_file_exists "11.1 HUMAN_NOTES.md moved" "${s11_dir}/.tekhton/HUMAN_NOTES.md"
assert_file_exists "11.2 HUMAN_NOTES.md.bak moved" "${s11_dir}/.tekhton/HUMAN_NOTES.md.bak"
assert_file_exists "11.3 HUMAN_NOTES.md.back moved" "${s11_dir}/.tekhton/HUMAN_NOTES.md.back"
assert_file_exists "11.4 HUMAN_NOTES.md.v1-backup moved" \
    "${s11_dir}/.tekhton/HUMAN_NOTES.md.v1-backup"
assert_file_not_exists "11.5 HUMAN_NOTES.md.bak gone from root" \
    "${s11_dir}/HUMAN_NOTES.md.bak"
assert_file_not_exists "11.6 HUMAN_NOTES.md.v1-backup gone from root" \
    "${s11_dir}/HUMAN_NOTES.md.v1-backup"

# =============================================================================
# Suite 12: 003_to_031.sh — destination-exists guard
# =============================================================================
echo "--- Suite 12: destination-exists guard ---"

s12_dir="$TMPDIR_BASE/s12_dest_exists"
mkdir -p "${s12_dir}/.claude" "${s12_dir}/.tekhton"
cat > "${s12_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-dest-exists"
ANALYZE_CMD="true"
EOF

# Pre-existing file in .tekhton/ (partially migrated project)
echo "existing content" > "${s12_dir}/.tekhton/CODER_SUMMARY.md"
# Root-level file also present (shouldn't overwrite the .tekhton/ version)
echo "root content" > "${s12_dir}/CODER_SUMMARY.md"

set +e
migration_apply "$s12_dir"
rc=$?
set -e
assert_eq "12.1 apply returns 0 when destination exists" "0" "$rc"

# The .tekhton/ version must retain its original content (not overwritten)
existing_content=$(cat "${s12_dir}/.tekhton/CODER_SUMMARY.md")
assert_eq "12.2 existing .tekhton/ file not overwritten" \
    "existing content" "$existing_content"

# Root file should remain untouched (destination guard prevented mv)
assert_file_exists "12.3 root file stays when destination exists" \
    "${s12_dir}/CODER_SUMMARY.md"

# =============================================================================
# Suite 13: Migration discovery includes 3.1
# =============================================================================
echo "--- Suite 13: migration discovery includes 3.1 ---"

TEKHTON_VERSION="3.72.0"
export TEKHTON_VERSION TEKHTON_HOME

source "${TEKHTON_HOME}/lib/migrate.sh"

scripts=$(_list_migration_scripts)
assert_contains "13.1 _list_migration_scripts includes 3.1" "3.1|" "$scripts"

# 13.2: V3.0 → V3.72 applicable migrations include 3.1
applicable=$(_applicable_migrations "3.0" "3.72")
assert_contains "13.2 applicable V3.0→V3.72 includes 3.1" "3.1|" "$applicable"

# 13.3: Already at V3.1 — 3.1 not re-applied
applicable_from_31=$(_applicable_migrations "3.1" "3.72")
TOTAL=$((TOTAL + 1))
if [[ "$applicable_from_31" != *"3.1|"* ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 13.3 3.1 migration should not apply when already at 3.1"
fi

# =============================================================================
# Results
# =============================================================================
echo
echo "=== M72 TEKHTON_DIR Tests: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
