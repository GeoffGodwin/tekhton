#!/usr/bin/env bash
# Test: Non-blocking notes accumulation and resolution
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TEKHTON_SESSION_DIR="$TMPDIR"
TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"
mkdir -p "${TMPDIR}/${TEKHTON_DIR}"

DRIFT_LOG_FILE="${TEKHTON_DIR}/DRIFT_LOG.md"
ARCHITECTURE_LOG_FILE="${TEKHTON_DIR}/ARCHITECTURE_LOG.md"
HUMAN_ACTION_FILE="${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md"
NON_BLOCKING_LOG_FILE="${TEKHTON_DIR}/NON_BLOCKING_LOG.md"
REVIEWER_REPORT_FILE="${TEKHTON_DIR}/REVIEWER_REPORT.md"
CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
NON_BLOCKING_INJECTION_THRESHOLD=3
DRIFT_OBSERVATION_THRESHOLD=8
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5
TASK="Test task"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift.sh"
source "${TEKHTON_HOME}/lib/drift_cleanup.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

assert_file_contains() {
    local name="$1" file="$2" pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — pattern '$pattern' not found in $file"
        FAIL=1
    fi
}

# ============================================================
# Phase 1: _ensure_nonblocking_log creates file
# ============================================================

_ensure_nonblocking_log

NB_FILE="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"

assert_eq "log file created" "true" "$([ -f "$NB_FILE" ] && echo true || echo false)"
assert_file_contains "has Open section" "$NB_FILE" "^## Open"
assert_file_contains "has Resolved section" "$NB_FILE" "^## Resolved"

# ============================================================
# Phase 2: _ensure_nonblocking_log repairs malformed file
# ============================================================

cat > "$NB_FILE" << 'EOF'
# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.

## Resolved
EOF

_ensure_nonblocking_log
assert_file_contains "repair restores Open section" "$NB_FILE" "^## Open"
assert_file_contains "repair keeps Resolved section" "$NB_FILE" "^## Resolved"

# ============================================================
# Phase 3: count_open_nonblocking_notes — empty file returns 0
# ============================================================

COUNT=$(count_open_nonblocking_notes)
assert_eq "empty count" "0" "$COUNT"

# ============================================================
# Phase 4: append_nonblocking_notes from reviewer report
# ============================================================

cat > "${PROJECT_DIR}/${REVIEWER_REPORT_FILE}" << 'EOF'
# Review Report

## Verdict
APPROVED_WITH_NOTES

## Non-Blocking Notes
- [lib/foo.dart:42] Missing null check
- [lib/bar.dart:10] Consider renaming variable

## Coverage Gaps
- foo_test.dart
EOF

append_nonblocking_notes

COUNT=$(count_open_nonblocking_notes)
assert_eq "appended 2 notes" "2" "$COUNT"
assert_file_contains "note 1 present" "$NB_FILE" "Missing null check"
assert_file_contains "note 2 present" "$NB_FILE" "Consider renaming variable"
assert_file_contains "tagged with task" "$NB_FILE" "Test task"

# ============================================================
# Phase 5: append more notes from a second run
# ============================================================

TASK="Second task"
cat > "${PROJECT_DIR}/${REVIEWER_REPORT_FILE}" << 'EOF'
# Review Report

## Verdict
APPROVED_WITH_NOTES

## Non-Blocking Notes
- [lib/baz.dart:5] Add docstring
- [lib/qux.dart:20] Consider extracting helper

## Coverage Gaps
EOF

append_nonblocking_notes

COUNT=$(count_open_nonblocking_notes)
assert_eq "total 4 notes" "4" "$COUNT"
assert_file_contains "new note tagged" "$NB_FILE" "Second task"

# ============================================================
# Phase 6: get_open_nonblocking_notes returns text
# ============================================================

NOTES=$(get_open_nonblocking_notes)
LINE_COUNT=$(echo "$NOTES" | wc -l | tr -d '[:space:]')
assert_eq "4 lines of notes" "4" "$LINE_COUNT"

# ============================================================
# Phase 7: _resolve_addressed_nonblocking_notes marks files
# ============================================================

cat > "${PROJECT_DIR}/${CODER_SUMMARY_FILE}" << 'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
Fixed null check in foo.dart
## Files Modified
- lib/foo.dart — added null check
- lib/baz.dart — added docstring
EOF

_resolve_addressed_nonblocking_notes

COUNT=$(count_open_nonblocking_notes)
assert_eq "2 resolved, 2 remaining" "2" "$COUNT"
assert_file_contains "foo resolved" "$NB_FILE" '\[x\].*foo.dart'
assert_file_contains "baz resolved" "$NB_FILE" '\[x\].*baz.dart'

# ============================================================
# Phase 8: "None" non-blocking notes are skipped
# ============================================================

cat > "${PROJECT_DIR}/${REVIEWER_REPORT_FILE}" << 'EOF'
# Review Report

## Verdict
APPROVED

## Non-Blocking Notes
None

## Coverage Gaps
EOF

COUNT_BEFORE=$(count_open_nonblocking_notes)
append_nonblocking_notes
COUNT_AFTER=$(count_open_nonblocking_notes)
assert_eq "None skipped" "$COUNT_BEFORE" "$COUNT_AFTER"

# ============================================================
# Phase 9: Missing reviewer report is safe
# ============================================================

rm -f "${PROJECT_DIR}/${REVIEWER_REPORT_FILE}"
COUNT_BEFORE=$(count_open_nonblocking_notes)
append_nonblocking_notes
COUNT_AFTER=$(count_open_nonblocking_notes)
assert_eq "no report safe" "$COUNT_BEFORE" "$COUNT_AFTER"

# ============================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
