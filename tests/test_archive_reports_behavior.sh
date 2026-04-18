#!/usr/bin/env bash
# =============================================================================
# test_archive_reports_behavior.sh — Note 2: Verify archive_reports behavior
#
# Tests that archive_reports() correctly archives report files.
# Note 2 mentions "archival under-emission" (archive_reports emits 0 lines),
# which is acceptable per prior report. This test documents the actual behavior:
# archive_reports silently copies files without printing status messages.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/hooks.sh"

FAIL=0

assert_file_exists() {
    local name="$1" file="$2"
    if [ ! -f "$file" ]; then
        echo "FAIL: $name — file not found: $file"
        FAIL=1
    else
        echo "ok: $name"
    fi
}

assert_file_not_exists() {
    local name="$1" file="$2"
    if [ -f "$file" ]; then
        echo "FAIL: $name — file should not exist: $file"
        FAIL=1
    else
        echo "ok: $name"
    fi
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $name — expected '${expected}', got '${actual}'"
        FAIL=1
    else
        echo "ok: $name"
    fi
}

# Setup temporary directories
LOG_DIR="${TMPDIR}/logs"
ARCHIVE_DIR="${TMPDIR}/archive"
mkdir -p "$LOG_DIR" "$ARCHIVE_DIR"

# Create test report files
CODER_SUMMARY_FILE="${TMPDIR}/CODER_SUMMARY.md"
REVIEWER_REPORT_FILE="${TMPDIR}/REVIEWER_REPORT.md"
TESTER_REPORT_FILE="${TMPDIR}/TESTER_REPORT.md"
JR_CODER_SUMMARY_FILE="${TMPDIR}/JR_CODER_SUMMARY.md"
SECURITY_REPORT_FILE="${TMPDIR}/SECURITY_REPORT.md"
SECURITY_NOTES_FILE="${TMPDIR}/SECURITY_NOTES.md"
INTAKE_REPORT_FILE="${TMPDIR}/INTAKE_REPORT.md"
PREFLIGHT_ERRORS_FILE="${TMPDIR}/PREFLIGHT_ERRORS.md"
TEST_AUDIT_REPORT_FILE="${TMPDIR}/TEST_AUDIT_REPORT.md"
UI_VALIDATION_REPORT_FILE="${TMPDIR}/UI_VALIDATION_REPORT.md"

export CODER_SUMMARY_FILE REVIEWER_REPORT_FILE TESTER_REPORT_FILE
export JR_CODER_SUMMARY_FILE SECURITY_REPORT_FILE SECURITY_NOTES_FILE
export INTAKE_REPORT_FILE PREFLIGHT_ERRORS_FILE TEST_AUDIT_REPORT_FILE
export UI_VALIDATION_REPORT_FILE

# =============================================================================
# Test 1: archive_reports copies existing files with timestamp prefix
# =============================================================================
echo "Coder content" > "$CODER_SUMMARY_FILE"
echo "Reviewer content" > "$REVIEWER_REPORT_FILE"
echo "Tester content" > "$TESTER_REPORT_FILE"

timestamp="20260417_120000"
output=$(archive_reports "$ARCHIVE_DIR" "$timestamp" 2>&1 || true)

assert_file_exists "Test 1a: CODER_SUMMARY archived" \
    "${ARCHIVE_DIR}/${timestamp}_CODER_SUMMARY.md"
assert_file_exists "Test 1b: REVIEWER_REPORT archived" \
    "${ARCHIVE_DIR}/${timestamp}_REVIEWER_REPORT.md"
assert_file_exists "Test 1c: TESTER_REPORT archived" \
    "${ARCHIVE_DIR}/${timestamp}_TESTER_REPORT.md"

# Verify content was copied correctly
coder_content=$(cat "${ARCHIVE_DIR}/${timestamp}_CODER_SUMMARY.md" 2>/dev/null || true)
assert_eq "Test 1d: Coder file content preserved" \
    "Coder content" "$coder_content"

# =============================================================================
# Test 2: archive_reports does NOT emit output lines (silent operation)
# =============================================================================
# Clear previous files
rm -f "${ARCHIVE_DIR}"/*

echo "More coder content" > "$CODER_SUMMARY_FILE"
timestamp="20260417_130000"

# Capture all output (stdout and stderr)
output=$(archive_reports "$ARCHIVE_DIR" "$timestamp" 2>&1 || true)

# Verify it was silent (no output)
assert_eq "Test 2: archive_reports produces no output" \
    "" "$output"

# But files should still be archived
assert_file_exists "Test 2b: File still archived despite silent operation" \
    "${ARCHIVE_DIR}/${timestamp}_CODER_SUMMARY.md"

# =============================================================================
# Test 3: Non-existent files are skipped (no error)
# =============================================================================
rm -f "${ARCHIVE_DIR}"/*
rm -f "$CODER_SUMMARY_FILE" "$REVIEWER_REPORT_FILE"

# Only create one file
echo "Solo tester content" > "$TESTER_REPORT_FILE"

timestamp="20260417_140000"
output=$(archive_reports "$ARCHIVE_DIR" "$timestamp" 2>&1 || true)

# Should succeed silently
assert_eq "Test 3a: Skipping missing files produces no error output" \
    "" "$output"

# Only the existing file should be archived
assert_file_exists "Test 3b: Existing file was archived" \
    "${ARCHIVE_DIR}/${timestamp}_TESTER_REPORT.md"
assert_file_not_exists "Test 3c: Non-existent file not created" \
    "${ARCHIVE_DIR}/${timestamp}_CODER_SUMMARY.md"

# =============================================================================
# Test 4: archive_reports handles multiple files in one call
# =============================================================================
rm -f "${ARCHIVE_DIR}"/*

# Create several report files
echo "Content 1" > "$CODER_SUMMARY_FILE"
echo "Content 2" > "$REVIEWER_REPORT_FILE"
echo "Content 3" > "$TESTER_REPORT_FILE"
echo "Content 4" > "$JR_CODER_SUMMARY_FILE"
echo "Content 5" > "$SECURITY_REPORT_FILE"

timestamp="20260417_150000"
output=$(archive_reports "$ARCHIVE_DIR" "$timestamp" 2>&1 || true)

# Verify all 5 files were archived
assert_file_exists "Test 4a: CODER_SUMMARY archived" \
    "${ARCHIVE_DIR}/${timestamp}_CODER_SUMMARY.md"
assert_file_exists "Test 4b: REVIEWER_REPORT archived" \
    "${ARCHIVE_DIR}/${timestamp}_REVIEWER_REPORT.md"
assert_file_exists "Test 4c: TESTER_REPORT archived" \
    "${ARCHIVE_DIR}/${timestamp}_TESTER_REPORT.md"
assert_file_exists "Test 4d: JR_CODER_SUMMARY archived" \
    "${ARCHIVE_DIR}/${timestamp}_JR_CODER_SUMMARY.md"
assert_file_exists "Test 4e: SECURITY_REPORT archived" \
    "${ARCHIVE_DIR}/${timestamp}_SECURITY_REPORT.md"

# Still no output
assert_eq "Test 4f: Still silent with multiple files" \
    "" "$output"

# =============================================================================
echo
if [ "$FAIL" -ne 0 ]; then
    echo "test_archive_reports_behavior: FAILED"
    exit 1
fi
echo "test_archive_reports_behavior: PASSED"
