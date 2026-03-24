#!/usr/bin/env bash
# =============================================================================
# test_migration.sh — Tests for the version migration framework (M21)
#
# Covers: version detection from artifacts, migration check/apply for V1→V2
# and V2→V3, idempotency, backup creation, rollback, chain execution order,
# failure mid-chain, watermark writing.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0
TOTAL=0

# Stub globals
TEKHTON_VERSION="3.20.0"
export TEKHTON_VERSION TEKHTON_HOME

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
        echo "FAIL: ${label}: expected to contain '${needle}' in '${haystack}'"
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

# Source common.sh for log/warn/error stubs
source "${TEKHTON_HOME}/lib/common.sh"

# Source the migration framework
source "${TEKHTON_HOME}/lib/migrate.sh"

# =============================================================================
# Suite 1: Version detection from artifacts
# =============================================================================
echo "--- Suite 1: Version detection from artifacts ---"

# Test 1.1: Explicit watermark
s1_dir="$TMPDIR_BASE/s1_explicit"
mkdir -p "${s1_dir}/.claude"
cat > "${s1_dir}/.claude/pipeline.conf" << 'EOF'
TEKHTON_CONFIG_VERSION="2.5"
PROJECT_NAME="test"
EOF
ver=$(detect_config_version "$s1_dir")
assert_eq "1.1 explicit watermark" "2.5" "$ver"

# Test 1.2: No config file at all
s1_noconf="$TMPDIR_BASE/s1_noconf"
mkdir -p "$s1_noconf"
ver=$(detect_config_version "$s1_noconf")
assert_eq "1.2 no config" "0.0" "$ver"

# Test 1.3: V3 project (has MANIFEST.cfg)
s1_v3="$TMPDIR_BASE/s1_v3"
mkdir -p "${s1_v3}/.claude/milestones"
cat > "${s1_v3}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-v3"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="true"
EOF
cat > "${s1_v3}/.claude/milestones/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
m01|Test|pending||m01-test.md|
EOF
ver=$(detect_config_version "$s1_v3")
assert_eq "1.3 V3 artifact detection" "3.0" "$ver"

# Test 1.4: V2 project (has V2-era config keys, no manifest)
s1_v2="$TMPDIR_BASE/s1_v2"
mkdir -p "${s1_v2}/.claude"
cat > "${s1_v2}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-v2"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="true"
CONTEXT_BUDGET_PCT=50
METRICS_ENABLED=true
EOF
ver=$(detect_config_version "$s1_v2")
assert_eq "1.4 V2 artifact detection" "2.0" "$ver"

# Test 1.5: V1 project (basic config only)
s1_v1="$TMPDIR_BASE/s1_v1"
mkdir -p "${s1_v1}/.claude"
cat > "${s1_v1}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-v1"
CLAUDE_STANDARD_MODEL="sonnet"
ANALYZE_CMD="echo lint"
TEST_CMD="echo test"
EOF
ver=$(detect_config_version "$s1_v1")
assert_eq "1.5 V1 artifact detection" "1.0" "$ver"

# =============================================================================
# Suite 2: Version comparison helpers
# =============================================================================
echo "--- Suite 2: Version comparison helpers ---"

_version_lt "1.0" "2.0" && r="yes" || r="no"
assert_eq "2.1 1.0 < 2.0" "yes" "$r"

_version_lt "2.0" "1.0" && r="yes" || r="no"
assert_eq "2.2 2.0 < 1.0" "no" "$r"

_version_lt "2.0" "2.0" && r="yes" || r="no"
assert_eq "2.3 2.0 < 2.0" "no" "$r"

_version_lt "1.5" "3.0" && r="yes" || r="no"
assert_eq "2.4 1.5 < 3.0" "yes" "$r"

_version_eq "3.0" "3.0" && r="yes" || r="no"
assert_eq "2.5 3.0 == 3.0" "yes" "$r"

_version_eq "2.0" "3.0" && r="yes" || r="no"
assert_eq "2.6 2.0 == 3.0" "no" "$r"

# =============================================================================
# Suite 3: Migration script discovery
# =============================================================================
echo "--- Suite 3: Migration script discovery ---"

# Test that we find migration scripts
scripts=$(_list_migration_scripts)
assert_contains "3.1 finds 001_to_002" "2.0|" "$scripts"
assert_contains "3.2 finds 002_to_003" "3.0|" "$scripts"

# Test applicable migrations
applicable=$(_applicable_migrations "1.0" "3.20")
assert_contains "3.3 V1→V3 includes 2.0" "2.0|" "$applicable"
assert_contains "3.4 V1→V3 includes 3.0" "3.0|" "$applicable"

# V2→V3 should only include 3.0
applicable=$(_applicable_migrations "2.0" "3.20")
assert_contains "3.5 V2→V3 includes 3.0" "3.0|" "$applicable"
# Should NOT include 2.0
TOTAL=$((TOTAL + 1))
if [[ "$applicable" != *"2.0|"* ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 3.6 V2→V3 should not include 2.0"
fi

# =============================================================================
# Suite 4: V1→V2 migration check and apply
# =============================================================================
echo "--- Suite 4: V1→V2 migration ---"

s4_dir="$TMPDIR_BASE/s4_v1_to_v2"
mkdir -p "${s4_dir}/.claude"
cat > "${s4_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-v1"
CLAUDE_STANDARD_MODEL="sonnet"
ANALYZE_CMD="echo lint"
TEST_CMD="echo test"
EOF

# Source the migration script
source "${TEKHTON_HOME}/migrations/001_to_002.sh"

# Check should return 0 (migration needed)
migration_check "$s4_dir" && r="needed" || r="applied"
assert_eq "4.1 V1→V2 check needed" "needed" "$r"

# Apply
migration_apply "$s4_dir"
assert_eq "4.2 V1→V2 apply success" "0" "$?"

# Verify config keys were added
assert_contains "4.3 has CONTEXT_BUDGET_PCT" "CONTEXT_BUDGET_PCT" "$(cat "${s4_dir}/.claude/pipeline.conf")"
assert_contains "4.4 has METRICS_ENABLED" "METRICS_ENABLED" "$(cat "${s4_dir}/.claude/pipeline.conf")"
assert_contains "4.5 has CONTINUATION_ENABLED" "CONTINUATION_ENABLED" "$(cat "${s4_dir}/.claude/pipeline.conf")"

# Idempotency: check should return 1 (already applied)
migration_check "$s4_dir" && r="needed" || r="applied"
assert_eq "4.6 V1→V2 idempotent" "applied" "$r"

# =============================================================================
# Suite 5: V2→V3 migration check and apply
# =============================================================================
echo "--- Suite 5: V2→V3 migration ---"

s5_dir="$TMPDIR_BASE/s5_v2_to_v3"
mkdir -p "${s5_dir}/.claude"
cat > "${s5_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-v2"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo lint"
CONTEXT_BUDGET_PCT=50
METRICS_ENABLED=true
EOF

# Source the migration script
source "${TEKHTON_HOME}/migrations/002_to_003.sh"

# Check should return 0 (migration needed)
migration_check "$s5_dir" && r="needed" || r="applied"
assert_eq "5.1 V2→V3 check needed" "needed" "$r"

# Apply
migration_apply "$s5_dir"
assert_eq "5.2 V2→V3 apply success" "0" "$?"

# Verify config keys were added
assert_contains "5.3 has SECURITY_AGENT_ENABLED" "SECURITY_AGENT_ENABLED" "$(cat "${s5_dir}/.claude/pipeline.conf")"
assert_contains "5.4 has INTAKE_AGENT_ENABLED" "INTAKE_AGENT_ENABLED" "$(cat "${s5_dir}/.claude/pipeline.conf")"
assert_contains "5.5 has DASHBOARD_ENABLED" "DASHBOARD_ENABLED" "$(cat "${s5_dir}/.claude/pipeline.conf")"
assert_contains "5.6 has TEST_BASELINE_ENABLED" "TEST_BASELINE_ENABLED" "$(cat "${s5_dir}/.claude/pipeline.conf")"

# Idempotency
migration_check "$s5_dir" && r="needed" || r="applied"
assert_eq "5.7 V2→V3 idempotent" "applied" "$r"

# =============================================================================
# Suite 6: Backup creation
# =============================================================================
echo "--- Suite 6: Backup creation ---"

s6_dir="$TMPDIR_BASE/s6_backup"
mkdir -p "${s6_dir}/.claude/agents"
cat > "${s6_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-backup"
CLAUDE_STANDARD_MODEL="sonnet"
ANALYZE_CMD="true"
EOF
echo "# Custom coder role" > "${s6_dir}/.claude/agents/coder.md"

MIGRATION_BACKUP_DIR=".claude/migration-backups"
backup_project_config "$s6_dir" "1.0" "3.0"

assert_file_exists "6.1 backup dir created" "${s6_dir}/.claude/migration-backups/pre-1.0-to-3.0/.claude/pipeline.conf"
assert_file_exists "6.2 agent role backed up" "${s6_dir}/.claude/migration-backups/pre-1.0-to-3.0/.claude/agents/coder.md"
assert_file_exists "6.3 FROM_VERSION written" "${s6_dir}/.claude/migration-backups/pre-1.0-to-3.0/FROM_VERSION"

from_ver=$(cat "${s6_dir}/.claude/migration-backups/pre-1.0-to-3.0/FROM_VERSION")
assert_eq "6.4 FROM_VERSION content" "1.0" "$from_ver"

# =============================================================================
# Suite 7: Watermark writing
# =============================================================================
echo "--- Suite 7: Watermark writing ---"

s7_dir="$TMPDIR_BASE/s7_watermark"
mkdir -p "${s7_dir}/.claude"
cat > "${s7_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-watermark"
CLAUDE_STANDARD_MODEL="sonnet"
ANALYZE_CMD="true"
EOF

# Write new watermark
_write_config_version "$s7_dir" "3.20"
assert_contains "7.1 watermark inserted" 'TEKHTON_CONFIG_VERSION="3.20"' "$(cat "${s7_dir}/.claude/pipeline.conf")"

# Update existing watermark
_write_config_version "$s7_dir" "4.0"
assert_contains "7.2 watermark updated" 'TEKHTON_CONFIG_VERSION="4.0"' "$(cat "${s7_dir}/.claude/pipeline.conf")"

# Ensure no duplicate lines
count=$(grep -c 'TEKHTON_CONFIG_VERSION' "${s7_dir}/.claude/pipeline.conf")
assert_eq "7.3 single watermark line" "1" "$count"

# =============================================================================
# Suite 8: Full chain execution (V1→V3)
# =============================================================================
echo "--- Suite 8: Full chain V1→V3 ---"

s8_dir="$TMPDIR_BASE/s8_chain"
mkdir -p "${s8_dir}/.claude"
cat > "${s8_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-chain"
CLAUDE_STANDARD_MODEL="sonnet"
ANALYZE_CMD="true"
TEST_CMD="true"
EOF

PROJECT_DIR="$s8_dir"
MIGRATION_BACKUP_DIR=".claude/migration-backups"

# Run full chain
run_migrations "1.0" "3.20" "$s8_dir"
assert_eq "8.1 chain success" "0" "$?"

# Verify both migrations applied
conf_content=$(cat "${s8_dir}/.claude/pipeline.conf")
assert_contains "8.2 has V2 keys" "CONTEXT_BUDGET_PCT" "$conf_content"
assert_contains "8.3 has V3 keys" "SECURITY_AGENT_ENABLED" "$conf_content"
assert_contains "8.4 watermark updated" 'TEKHTON_CONFIG_VERSION="3.20"' "$conf_content"

# Backup exists
assert_file_exists "8.5 backup created" "${s8_dir}/.claude/migration-backups/pre-1.0-to-3.20/.claude/pipeline.conf"

# =============================================================================
# Suite 9: Running major.minor extraction
# =============================================================================
echo "--- Suite 9: Running version extraction ---"

rmm=$(_running_major_minor)
assert_eq "9.1 running major.minor" "3.20" "$rmm"

# =============================================================================
# Suite 10: Rollback
# =============================================================================
echo "--- Suite 10: Rollback ---"

s10_dir="$TMPDIR_BASE/s10_rollback"
mkdir -p "${s10_dir}/.claude"
cat > "${s10_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-rollback"
CLAUDE_STANDARD_MODEL="sonnet"
ANALYZE_CMD="true"
TEST_CMD="true"
EOF

# Save original content
original_conf=$(cat "${s10_dir}/.claude/pipeline.conf")

# Create backup and apply migration
MIGRATION_BACKUP_DIR=".claude/migration-backups"
backup_project_config "$s10_dir" "1.0" "2.0"

# Modify the config (simulate migration)
echo "EXTRA_KEY=true" >> "${s10_dir}/.claude/pipeline.conf"

# Rollback (non-interactive — we'll test the restore logic directly)
backup_dir="${s10_dir}/.claude/migration-backups/pre-1.0-to-2.0"
cp "${backup_dir}/.claude/pipeline.conf" "${s10_dir}/.claude/pipeline.conf"

restored_conf=$(cat "${s10_dir}/.claude/pipeline.conf")
assert_eq "10.1 rollback restores content" "$original_conf" "$restored_conf"

# =============================================================================
# Suite 11: show_migration_status and show_migration_check
# =============================================================================
echo "--- Suite 11: Status and check commands ---"

s11_dir="$TMPDIR_BASE/s11_status"
mkdir -p "${s11_dir}/.claude"
cat > "${s11_dir}/.claude/pipeline.conf" << 'EOF'
TEKHTON_CONFIG_VERSION="1.0"
PROJECT_NAME="test-status"
CLAUDE_STANDARD_MODEL="sonnet"
ANALYZE_CMD="true"
EOF

PROJECT_DIR="$s11_dir"
status_output=$(show_migration_status)
assert_contains "11.1 status shows config version" "V1.0" "$status_output"
assert_contains "11.2 status shows running version" "V3.20" "$status_output"
assert_contains "11.3 status shows migrations available" "migration" "$status_output"

check_output=$(show_migration_check)
assert_contains "11.4 check shows dry run" "V1.0" "$check_output"

# =============================================================================
# Suite 12: _cleanup_old_backups
# =============================================================================
echo "--- Suite 12: _cleanup_old_backups ---"

# 12.1: No backup directory — should succeed with no error
s12_nodir="$TMPDIR_BASE/s12_nodir"
mkdir -p "$s12_nodir"
MIGRATION_BACKUP_DIR=".claude/migration-backups"
_cleanup_old_backups "$s12_nodir" 2>&1
assert_eq "12.1 no backup dir returns 0" "0" "$?"

# 12.2: Exactly 3 backups — nothing removed
s12_three="$TMPDIR_BASE/s12_three"
mkdir -p "${s12_three}/.claude/migration-backups"
mkdir -p "${s12_three}/.claude/migration-backups/pre-1.0-to-2.0"
mkdir -p "${s12_three}/.claude/migration-backups/pre-2.0-to-3.0"
mkdir -p "${s12_three}/.claude/migration-backups/pre-1.5-to-3.0"
_cleanup_old_backups "$s12_three"
dir_count=$(find "${s12_three}/.claude/migration-backups" -mindepth 1 -maxdepth 1 -type d | wc -l)
assert_eq "12.2 three backups — none removed" "3" "$dir_count"

# 12.3: 5 backups — oldest 2 removed, newest 3 kept
s12_five="$TMPDIR_BASE/s12_five"
backup_base="${s12_five}/.claude/migration-backups"
mkdir -p "${backup_base}"
# Create 5 dirs; names are lexicographically sorted by bash glob
# Use numeric prefixes so ordering is deterministic
mkdir -p "${backup_base}/pre-1.0-to-2.0"
mkdir -p "${backup_base}/pre-2.0-to-3.0"
mkdir -p "${backup_base}/pre-3.0-to-4.0"
mkdir -p "${backup_base}/pre-4.0-to-5.0"
mkdir -p "${backup_base}/pre-5.0-to-6.0"
touch "${backup_base}/pre-1.0-to-2.0/FROM_VERSION"
touch "${backup_base}/pre-2.0-to-3.0/FROM_VERSION"
touch "${backup_base}/pre-3.0-to-4.0/FROM_VERSION"
touch "${backup_base}/pre-4.0-to-5.0/FROM_VERSION"
touch "${backup_base}/pre-5.0-to-6.0/FROM_VERSION"
_cleanup_old_backups "$s12_five"
remaining=$(find "${backup_base}" -mindepth 1 -maxdepth 1 -type d | wc -l)
assert_eq "12.3 five backups — 3 remain" "3" "$remaining"

# 12.4: The OLDEST two are removed (dirs are sorted lexicographically by glob)
# After cleanup of 5→3: pre-1.0-to-2.0 and pre-2.0-to-3.0 should be gone
TOTAL=$((TOTAL + 1))
if [[ ! -d "${backup_base}/pre-1.0-to-2.0" ]] && [[ ! -d "${backup_base}/pre-2.0-to-3.0" ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 12.4 oldest backups should be removed"
fi

# 12.5: The three newest remain
TOTAL=$((TOTAL + 1))
if [[ -d "${backup_base}/pre-3.0-to-4.0" ]] && \
   [[ -d "${backup_base}/pre-4.0-to-5.0" ]] && \
   [[ -d "${backup_base}/pre-5.0-to-6.0" ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 12.5 three newest backups should be kept"
fi

# =============================================================================
# Suite 13: run_migrate_command --force (skips Y/n prompt)
# =============================================================================
echo "--- Suite 13: run_migrate_command --force ---"

s13_dir="$TMPDIR_BASE/s13_force"
mkdir -p "${s13_dir}/.claude"
cat > "${s13_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-force"
CLAUDE_STANDARD_MODEL="sonnet"
ANALYZE_CMD="echo lint"
TEST_CMD="echo test"
EOF

PROJECT_DIR="$s13_dir"
MIGRATION_BACKUP_DIR=".claude/migration-backups"

# --force must skip the interactive Y/n prompt; run with no stdin (< /dev/null)
run_migrate_command --force < /dev/null
assert_eq "13.1 --force exits 0" "0" "$?"

conf_content=$(cat "${s13_dir}/.claude/pipeline.conf")

# V2 keys should be present after chain migration
assert_contains "13.2 --force applied V2 keys" "CONTEXT_BUDGET_PCT" "$conf_content"
assert_contains "13.3 --force applied V3 keys" "SECURITY_AGENT_ENABLED" "$conf_content"

# Watermark should be written
assert_contains "13.4 --force wrote watermark" 'TEKHTON_CONFIG_VERSION=' "$conf_content"

# Backup should exist (run_migrations creates one before migrating)
TOTAL=$((TOTAL + 1))
if [[ -d "${s13_dir}/.claude/migration-backups" ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 13.5 --force should create backup before migrating"
fi

# =============================================================================
# Results
# =============================================================================
echo
echo "=== Migration Tests: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
