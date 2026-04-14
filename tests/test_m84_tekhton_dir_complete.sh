#!/usr/bin/env bash
# =============================================================================
# test_m84_tekhton_dir_complete.sh — Tests for M84: Complete TEKHTON_DIR Migration
#
# Covers:
#   - 7 new transient artifact _FILE vars default under ${TEKHTON_DIR}/
#   - Custom TEKHTON_DIR is respected for all new M84 variables
#   - migrations/003_to_031.sh includes all 7 new files in its relocation list
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0
TOTAL=0

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: ${label}: expected to contain '${needle}'"
        echo "      actual output: $(echo "$haystack" | grep "${needle%%=*}" || echo '(not found)')"
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

# =============================================================================
# Suite 1: config_defaults.sh — 7 new M84 transient artifact _FILE defaults
# =============================================================================
echo "--- Suite 1: M84 new _FILE variables default under .tekhton/ ---"

defaults_output=$(env -i bash --norc --noprofile -c "
    set -euo pipefail
    _clamp_config_value() { return 0; }
    _clamp_config_float() { return 0; }
    source '${TEKHTON_HOME}/lib/config_defaults.sh'
    echo \"SCOUT_REPORT_FILE=\${SCOUT_REPORT_FILE}\"
    echo \"ARCHITECT_PLAN_FILE=\${ARCHITECT_PLAN_FILE}\"
    echo \"CLEANUP_REPORT_FILE=\${CLEANUP_REPORT_FILE}\"
    echo \"DRIFT_ARCHIVE_FILE=\${DRIFT_ARCHIVE_FILE}\"
    echo \"PROJECT_INDEX_FILE=\${PROJECT_INDEX_FILE}\"
    echo \"REPLAN_DELTA_FILE=\${REPLAN_DELTA_FILE}\"
    echo \"MERGE_CONTEXT_FILE=\${MERGE_CONTEXT_FILE}\"
")

assert_contains "1.1 SCOUT_REPORT_FILE defaults under .tekhton/" \
    "SCOUT_REPORT_FILE=.tekhton/SCOUT_REPORT.md" "$defaults_output"
assert_contains "1.2 ARCHITECT_PLAN_FILE defaults under .tekhton/" \
    "ARCHITECT_PLAN_FILE=.tekhton/ARCHITECT_PLAN.md" "$defaults_output"
assert_contains "1.3 CLEANUP_REPORT_FILE defaults under .tekhton/" \
    "CLEANUP_REPORT_FILE=.tekhton/CLEANUP_REPORT.md" "$defaults_output"
assert_contains "1.4 DRIFT_ARCHIVE_FILE defaults under .tekhton/" \
    "DRIFT_ARCHIVE_FILE=.tekhton/DRIFT_ARCHIVE.md" "$defaults_output"
assert_contains "1.5 PROJECT_INDEX_FILE defaults under .tekhton/" \
    "PROJECT_INDEX_FILE=.tekhton/PROJECT_INDEX.md" "$defaults_output"
assert_contains "1.6 REPLAN_DELTA_FILE defaults under .tekhton/" \
    "REPLAN_DELTA_FILE=.tekhton/REPLAN_DELTA.md" "$defaults_output"
assert_contains "1.7 MERGE_CONTEXT_FILE defaults under .tekhton/" \
    "MERGE_CONTEXT_FILE=.tekhton/MERGE_CONTEXT.md" "$defaults_output"

# =============================================================================
# Suite 2: config_defaults.sh — custom TEKHTON_DIR respected for M84 variables
# =============================================================================
echo "--- Suite 2: custom TEKHTON_DIR respected for M84 variables ---"

custom_output=$(env -i TEKHTON_DIR="run-artifacts" bash --norc --noprofile -c "
    set -euo pipefail
    _clamp_config_value() { return 0; }
    _clamp_config_float() { return 0; }
    source '${TEKHTON_HOME}/lib/config_defaults.sh'
    echo \"SCOUT_REPORT_FILE=\${SCOUT_REPORT_FILE}\"
    echo \"ARCHITECT_PLAN_FILE=\${ARCHITECT_PLAN_FILE}\"
    echo \"CLEANUP_REPORT_FILE=\${CLEANUP_REPORT_FILE}\"
    echo \"DRIFT_ARCHIVE_FILE=\${DRIFT_ARCHIVE_FILE}\"
    echo \"PROJECT_INDEX_FILE=\${PROJECT_INDEX_FILE}\"
    echo \"REPLAN_DELTA_FILE=\${REPLAN_DELTA_FILE}\"
    echo \"MERGE_CONTEXT_FILE=\${MERGE_CONTEXT_FILE}\"
")

assert_contains "2.1 custom TEKHTON_DIR for SCOUT_REPORT_FILE" \
    "SCOUT_REPORT_FILE=run-artifacts/SCOUT_REPORT.md" "$custom_output"
assert_contains "2.2 custom TEKHTON_DIR for ARCHITECT_PLAN_FILE" \
    "ARCHITECT_PLAN_FILE=run-artifacts/ARCHITECT_PLAN.md" "$custom_output"
assert_contains "2.3 custom TEKHTON_DIR for CLEANUP_REPORT_FILE" \
    "CLEANUP_REPORT_FILE=run-artifacts/CLEANUP_REPORT.md" "$custom_output"
assert_contains "2.4 custom TEKHTON_DIR for DRIFT_ARCHIVE_FILE" \
    "DRIFT_ARCHIVE_FILE=run-artifacts/DRIFT_ARCHIVE.md" "$custom_output"
assert_contains "2.5 custom TEKHTON_DIR for PROJECT_INDEX_FILE" \
    "PROJECT_INDEX_FILE=run-artifacts/PROJECT_INDEX.md" "$custom_output"
assert_contains "2.6 custom TEKHTON_DIR for REPLAN_DELTA_FILE" \
    "REPLAN_DELTA_FILE=run-artifacts/REPLAN_DELTA.md" "$custom_output"
assert_contains "2.7 custom TEKHTON_DIR for MERGE_CONTEXT_FILE" \
    "MERGE_CONTEXT_FILE=run-artifacts/MERGE_CONTEXT.md" "$custom_output"

# None of the new vars should default to project root (no slash-free name)
assert_not_contains "2.8 SCOUT_REPORT_FILE not at project root" \
    "SCOUT_REPORT_FILE=SCOUT_REPORT.md" "$custom_output"
assert_not_contains "2.9 PROJECT_INDEX_FILE not at project root" \
    "PROJECT_INDEX_FILE=PROJECT_INDEX.md" "$custom_output"

# =============================================================================
# Suite 3: migrations/003_to_031.sh — M84 files included in relocation list
# =============================================================================
echo "--- Suite 3: migration script includes M84 files ---"

# Source common.sh for log stubs, then source the migration script
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/migrations/003_to_031.sh"

# Read the raw migration script to check the files array
migration_src=$(cat "${TEKHTON_HOME}/migrations/003_to_031.sh")

assert_contains "3.1 migration includes SCOUT_REPORT.md" \
    "SCOUT_REPORT.md" "$migration_src"
assert_contains "3.2 migration includes ARCHITECT_PLAN.md" \
    "ARCHITECT_PLAN.md" "$migration_src"
assert_contains "3.3 migration includes CLEANUP_REPORT.md" \
    "CLEANUP_REPORT.md" "$migration_src"
assert_contains "3.4 migration includes DRIFT_ARCHIVE.md" \
    "DRIFT_ARCHIVE.md" "$migration_src"
assert_contains "3.5 migration includes PROJECT_INDEX.md" \
    "PROJECT_INDEX.md" "$migration_src"
assert_contains "3.6 migration includes REPLAN_DELTA.md" \
    "REPLAN_DELTA.md" "$migration_src"
assert_contains "3.7 migration includes MERGE_CONTEXT.md" \
    "MERGE_CONTEXT.md" "$migration_src"

# =============================================================================
# Suite 4: 003_to_031.sh — migration_apply moves M84 files
# =============================================================================
echo "--- Suite 4: migration_apply moves M84 files to .tekhton/ ---"

s4_dir="$TMPDIR_BASE/s4_m84_files"
mkdir -p "${s4_dir}/.claude"
cat > "${s4_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-m84"
ANALYZE_CMD="true"
EOF

# Create a representative set of M84 files at root
touch "${s4_dir}/SCOUT_REPORT.md"
touch "${s4_dir}/ARCHITECT_PLAN.md"
touch "${s4_dir}/CLEANUP_REPORT.md"
touch "${s4_dir}/DRIFT_ARCHIVE.md"
touch "${s4_dir}/PROJECT_INDEX.md"
touch "${s4_dir}/REPLAN_DELTA.md"
touch "${s4_dir}/MERGE_CONTEXT.md"

# Files that must NOT be migrated
echo "# Project rules" > "${s4_dir}/CLAUDE.md"

migration_apply "$s4_dir"
rc=$?

TOTAL=$((TOTAL + 1))
if [[ "$rc" -eq 0 ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 4.1 migration_apply returned non-zero: ${rc}"
fi

assert_file_exists "4.2 SCOUT_REPORT.md moved to .tekhton/" \
    "${s4_dir}/.tekhton/SCOUT_REPORT.md"
assert_file_exists "4.3 ARCHITECT_PLAN.md moved to .tekhton/" \
    "${s4_dir}/.tekhton/ARCHITECT_PLAN.md"
assert_file_exists "4.4 CLEANUP_REPORT.md moved to .tekhton/" \
    "${s4_dir}/.tekhton/CLEANUP_REPORT.md"
assert_file_exists "4.5 DRIFT_ARCHIVE.md moved to .tekhton/" \
    "${s4_dir}/.tekhton/DRIFT_ARCHIVE.md"
assert_file_exists "4.6 PROJECT_INDEX.md moved to .tekhton/" \
    "${s4_dir}/.tekhton/PROJECT_INDEX.md"
assert_file_exists "4.7 REPLAN_DELTA.md moved to .tekhton/" \
    "${s4_dir}/.tekhton/REPLAN_DELTA.md"
assert_file_exists "4.8 MERGE_CONTEXT.md moved to .tekhton/" \
    "${s4_dir}/.tekhton/MERGE_CONTEXT.md"

assert_file_not_exists "4.9 SCOUT_REPORT.md removed from root" \
    "${s4_dir}/SCOUT_REPORT.md"
assert_file_not_exists "4.10 PROJECT_INDEX.md removed from root" \
    "${s4_dir}/PROJECT_INDEX.md"
assert_file_not_exists "4.11 MERGE_CONTEXT.md removed from root" \
    "${s4_dir}/MERGE_CONTEXT.md"

# CLAUDE.md must not be migrated
assert_file_exists "4.12 CLAUDE.md stays at root" "${s4_dir}/CLAUDE.md"
assert_file_not_exists "4.13 CLAUDE.md not in .tekhton/" "${s4_dir}/.tekhton/CLAUDE.md"

# =============================================================================
# Results
# =============================================================================
echo
echo "=== M84 Complete TEKHTON_DIR Tests: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
