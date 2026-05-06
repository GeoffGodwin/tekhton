#!/usr/bin/env bash
# =============================================================================
# test_rejection_artifact_preservation.sh — Milestone 93
#
# Tests _choose_resume_start_at() in lib/orchestrate_aux.sh:
#   - REVIEWER_REPORT exists in run → resume "test"
#   - REVIEWER_REPORT archived this run, no current → restored, resume "test"
#   - TESTER_REPORT exists in run → resume "tester"
#   - TESTER_REPORT archived, no current reviewer/tester → restored, "tester"
#   - No artifacts available → falls back to $START_AT
#   - Restoration is logged
#   - _RESUME_RESTORED_ARTIFACT set after restoration, empty otherwise
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/orchestrate_aux.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    else
        echo "ok: $name"
    fi
}

assert_file_eq() {
    local name="$1" expected_file="$2" actual_file="$3"
    if [ ! -f "$actual_file" ]; then
        echo "FAIL: $name — file does not exist: $actual_file"
        FAIL=1
        return
    fi
    if ! cmp -s "$expected_file" "$actual_file"; then
        echo "FAIL: $name — file content differs"
        FAIL=1
    else
        echo "ok: $name"
    fi
}

_reset_state() {
    REVIEWER_REPORT_FILE="${TMPDIR}/REVIEWER_REPORT.md"
    TESTER_REPORT_FILE="${TMPDIR}/TESTER_REPORT.md"
    rm -f "$REVIEWER_REPORT_FILE" "$TESTER_REPORT_FILE"
    rm -f "${TMPDIR}/archive_"*.md 2>/dev/null || true
    _ARCHIVED_REVIEWER_REPORT_PATH=""
    _ARCHIVED_TESTER_REPORT_PATH=""
    _RESUME_NEW_START_AT=""
    _RESUME_RESTORED_ARTIFACT=""
    START_AT="coder"
    export REVIEWER_REPORT_FILE TESTER_REPORT_FILE
    export _ARCHIVED_REVIEWER_REPORT_PATH _ARCHIVED_TESTER_REPORT_PATH
    export START_AT
}

# =============================================================================
# 1. REVIEWER_REPORT exists in run → resume "test"
# =============================================================================
_reset_state
echo "in-run reviewer content" > "$REVIEWER_REPORT_FILE"

_choose_resume_start_at >/dev/null 2>&1
assert_eq "1.1 in-run reviewer report → start_at=test" "test" "$_RESUME_NEW_START_AT"
assert_eq "1.2 no restoration when current report exists" "" "$_RESUME_RESTORED_ARTIFACT"

# =============================================================================
# 2. REVIEWER_REPORT archived this run, no current → restored, resume "test"
# =============================================================================
_reset_state
ARCHIVED_REVIEWER="${TMPDIR}/archive_reviewer.md"
echo "archived reviewer content" > "$ARCHIVED_REVIEWER"
_ARCHIVED_REVIEWER_REPORT_PATH="$ARCHIVED_REVIEWER"
export _ARCHIVED_REVIEWER_REPORT_PATH

_choose_resume_start_at >/dev/null 2>&1
assert_eq "2.1 archived reviewer + no current → start_at=test" "test" "$_RESUME_NEW_START_AT"
assert_file_eq "2.2 archived reviewer was restored to REVIEWER_REPORT_FILE" \
    "$ARCHIVED_REVIEWER" "$REVIEWER_REPORT_FILE"
if [[ -n "$_RESUME_RESTORED_ARTIFACT" ]]; then
    echo "ok: 2.3 _RESUME_RESTORED_ARTIFACT records restoration"
else
    echo "FAIL: 2.3 _RESUME_RESTORED_ARTIFACT should be set after restoration"
    FAIL=1
fi
case "$_RESUME_RESTORED_ARTIFACT" in
    *REVIEWER*) echo "ok: 2.4 _RESUME_RESTORED_ARTIFACT mentions REVIEWER_REPORT" ;;
    *)
        echo "FAIL: 2.4 _RESUME_RESTORED_ARTIFACT should mention REVIEWER_REPORT — got: $_RESUME_RESTORED_ARTIFACT"
        FAIL=1
        ;;
esac

# =============================================================================
# 3. No artifacts available → falls back to $START_AT
# =============================================================================
_reset_state
START_AT="coder"
export START_AT

_choose_resume_start_at >/dev/null 2>&1
assert_eq "3.1 no artifacts → start_at=$START_AT" "coder" "$_RESUME_NEW_START_AT"
assert_eq "3.2 no restoration when nothing to restore" "" "$_RESUME_RESTORED_ARTIFACT"

# Different START_AT preserved
_reset_state
START_AT="intake"
export START_AT
_choose_resume_start_at >/dev/null 2>&1
assert_eq "3.3 fallback respects START_AT=intake" "intake" "$_RESUME_NEW_START_AT"

# =============================================================================
# 4. TESTER_REPORT exists in run, no reviewer → resume "tester"
# =============================================================================
_reset_state
echo "in-run tester content" > "$TESTER_REPORT_FILE"

_choose_resume_start_at >/dev/null 2>&1
assert_eq "4.1 in-run tester report (no reviewer) → start_at=tester" "tester" "$_RESUME_NEW_START_AT"
assert_eq "4.2 no restoration when current tester exists" "" "$_RESUME_RESTORED_ARTIFACT"

# =============================================================================
# 5. TESTER_REPORT archived, no current reviewer/tester → restored, "tester"
# =============================================================================
_reset_state
ARCHIVED_TESTER="${TMPDIR}/archive_tester.md"
echo "archived tester content" > "$ARCHIVED_TESTER"
_ARCHIVED_TESTER_REPORT_PATH="$ARCHIVED_TESTER"
export _ARCHIVED_TESTER_REPORT_PATH

_choose_resume_start_at >/dev/null 2>&1
assert_eq "5.1 archived tester (no reviewer) → start_at=tester" "tester" "$_RESUME_NEW_START_AT"
assert_file_eq "5.2 archived tester was restored to TESTER_REPORT_FILE" \
    "$ARCHIVED_TESTER" "$TESTER_REPORT_FILE"
case "$_RESUME_RESTORED_ARTIFACT" in
    *TESTER*) echo "ok: 5.3 _RESUME_RESTORED_ARTIFACT mentions TESTER_REPORT" ;;
    *)
        echo "FAIL: 5.3 _RESUME_RESTORED_ARTIFACT should mention TESTER_REPORT — got: $_RESUME_RESTORED_ARTIFACT"
        FAIL=1
        ;;
esac

# =============================================================================
# 6. Reviewer takes priority over tester
# =============================================================================
_reset_state
echo "in-run reviewer" > "$REVIEWER_REPORT_FILE"
echo "in-run tester" > "$TESTER_REPORT_FILE"

_choose_resume_start_at >/dev/null 2>&1
assert_eq "6.1 reviewer beats tester when both present → start_at=test" \
    "test" "$_RESUME_NEW_START_AT"

_reset_state
ARCHIVED_REVIEWER="${TMPDIR}/archive_reviewer2.md"
ARCHIVED_TESTER="${TMPDIR}/archive_tester2.md"
echo "rev" > "$ARCHIVED_REVIEWER"
echo "tst" > "$ARCHIVED_TESTER"
_ARCHIVED_REVIEWER_REPORT_PATH="$ARCHIVED_REVIEWER"
_ARCHIVED_TESTER_REPORT_PATH="$ARCHIVED_TESTER"
export _ARCHIVED_REVIEWER_REPORT_PATH _ARCHIVED_TESTER_REPORT_PATH

_choose_resume_start_at >/dev/null 2>&1
assert_eq "6.2 archived reviewer beats archived tester → start_at=test" \
    "test" "$_RESUME_NEW_START_AT"
# Tester should NOT be restored when reviewer wins
if [[ -f "$TESTER_REPORT_FILE" ]]; then
    echo "FAIL: 6.3 tester should NOT be restored when reviewer wins"
    FAIL=1
else
    echo "ok: 6.3 tester not restored when reviewer wins"
fi

# =============================================================================
# 7. Stale archive path with missing file → falls through gracefully
# =============================================================================
_reset_state
_ARCHIVED_REVIEWER_REPORT_PATH="${TMPDIR}/does-not-exist.md"
export _ARCHIVED_REVIEWER_REPORT_PATH

_choose_resume_start_at >/dev/null 2>&1
assert_eq "7.1 missing archive file → falls back to START_AT" \
    "coder" "$_RESUME_NEW_START_AT"
assert_eq "7.2 no restoration when archive file missing" "" "$_RESUME_RESTORED_ARTIFACT"

# =============================================================================
# 8. Restoration is logged (captures stderr)
# =============================================================================
_reset_state
ARCHIVED_REVIEWER="${TMPDIR}/archive_log_test.md"
echo "content" > "$ARCHIVED_REVIEWER"
_ARCHIVED_REVIEWER_REPORT_PATH="$ARCHIVED_REVIEWER"
export _ARCHIVED_REVIEWER_REPORT_PATH

LOG_OUTPUT=$(_choose_resume_start_at 2>&1)
case "$LOG_OUTPUT" in
    *"Restored archived REVIEWER_REPORT.md"*)
        echo "ok: 8.1 restoration log line present"
        ;;
    *)
        echo "FAIL: 8.1 expected 'Restored archived REVIEWER_REPORT.md' in log output — got: $LOG_OUTPUT"
        FAIL=1
        ;;
esac

# =============================================================================
echo
if [ "$FAIL" -ne 0 ]; then
    echo "test_rejection_artifact_preservation: FAILED"
    exit 1
fi
echo "test_rejection_artifact_preservation: PASSED"
