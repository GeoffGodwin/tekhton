#!/usr/bin/env bash
# Test: generate_commit_message includes debt resolution section
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TEKHTON_SESSION_DIR="$TMPDIR"
TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"
CODER_SUMMARY_FILE="${CODER_SUMMARY_FILE:-${TEKHTON_DIR}/CODER_SUMMARY.md}"
mkdir -p "${TMPDIR}/${TEKHTON_DIR}"

DRIFT_LOG_FILE="${TEKHTON_DIR}/DRIFT_LOG.md"
ARCHITECTURE_LOG_FILE="${TEKHTON_DIR}/ARCHITECTURE_LOG.md"
HUMAN_ACTION_FILE="${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md"
NON_BLOCKING_LOG_FILE="${TEKHTON_DIR}/NON_BLOCKING_LOG.md"
NON_BLOCKING_INJECTION_THRESHOLD=3
DRIFT_OBSERVATION_THRESHOLD=8
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5
TASK="Test task"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift.sh"
source "${TEKHTON_HOME}/lib/drift_cleanup.sh"
source "${TEKHTON_HOME}/lib/drift_artifacts.sh"

# Stub milestone functions — not needed for these tests
get_milestone_commit_prefix() { echo ""; }
get_milestone_commit_body() { echo ""; }

source "${TEKHTON_HOME}/lib/hooks.sh"

FAIL=0

assert_contains() {
    local name="$1" pattern="$2" actual="$3"
    if ! echo "$actual" | grep -q "$pattern"; then
        echo "FAIL: $name — pattern '$pattern' not found in output"
        echo "  output was: $actual"
        FAIL=1
    fi
}

assert_not_contains() {
    local name="$1" pattern="$2" actual="$3"
    if echo "$actual" | grep -q "$pattern"; then
        echo "FAIL: $name — unexpected pattern '$pattern' found in output"
        echo "  output was: $actual"
        FAIL=1
    fi
}

NB_FILE="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
DRIFT_FILE="${PROJECT_DIR}/${DRIFT_LOG_FILE}"

# ============================================================
# Test 1: no completed items, no resolved drift — no debt section
# ============================================================
cd "$TMPDIR"
mkdir -p "${TEKHTON_DIR:-.tekhton}"
MSG=$(generate_commit_message "Implement feature X")
assert_not_contains "no debt section when empty" "Non-blocking" "$MSG"
assert_not_contains "no drift section when empty" "Drift observations" "$MSG"

# ============================================================
# Test 2: completed nonblocking notes appear in commit body
# ============================================================
cat > "$NB_FILE" << 'EOF'
# Non-Blocking Log

## Open
- [x] [2026-03-18 | "fix nulls"] lib/foo.sh — missing null check
- [x] [2026-03-18 | "fix nulls"] lib/bar.sh — rename variable
- [ ] [2026-03-18 | "task"] lib/baz.sh — still open

## Resolved
EOF

MSG=$(generate_commit_message "Fix null checks")
assert_contains "debt section header present" "Non-blocking notes resolved" "$MSG"
assert_contains "count shown correctly" "Non-blocking notes resolved (2)" "$MSG"
assert_contains "foo.sh item included" "foo.sh" "$MSG"
assert_contains "bar.sh item included" "bar.sh" "$MSG"
assert_not_contains "open item excluded" "baz.sh" "$MSG"

# ============================================================
# Test 3: resolved drift observations appear in commit body
# ============================================================
rm -f "$NB_FILE"

cat > "$DRIFT_FILE" << 'EOF'
# Drift Log

## Unresolved Observations
- [2026-03-18 | "task"] still_open.sh — still unresolved

## Resolved
- [RESOLVED 2026-03-18] [2026-03-17 | "cleanup"] duplicate_pattern.sh — duplicate rank lookup
- [RESOLVED 2026-03-18] [2026-03-17 | "cleanup"] naming.sh — column lock naming mismatch
EOF

MSG=$(generate_commit_message "Cleanup sweep")
assert_contains "drift section header present" "Drift observations resolved" "$MSG"
assert_contains "drift count shown correctly" "Drift observations resolved (2)" "$MSG"
assert_contains "first drift item included" "duplicate rank lookup" "$MSG"
assert_contains "second drift item included" "column lock naming mismatch" "$MSG"
assert_not_contains "unresolved excluded" "still_open.sh" "$MSG"

# ============================================================
# Test 4: both completed notes and drift appear together
# ============================================================
cat > "$NB_FILE" << 'EOF'
# Non-Blocking Log

## Open
- [x] [2026-03-18 | "sweep"] lib/alpha.sh — refactor helper

## Resolved
EOF

# drift file already has 2 resolved items from previous test

MSG=$(generate_commit_message "Combined cleanup")
assert_contains "both sections present - nb" "Non-blocking notes resolved" "$MSG"
assert_contains "both sections present - drift" "Drift observations resolved" "$MSG"
assert_contains "nb item present" "alpha.sh" "$MSG"
assert_contains "drift item present" "duplicate rank lookup" "$MSG"

# ============================================================
# Test 5: commit prefix (feat/fix/refactor) is still set correctly
# ============================================================
rm -f "$NB_FILE" "$DRIFT_FILE"

MSG=$(generate_commit_message "fix: broken thing")
assert_contains "fix prefix" "^fix:" "$MSG"

MSG=$(generate_commit_message "refactor: something")
assert_contains "refactor prefix" "^refactor:" "$MSG"

MSG=$(generate_commit_message "Add new feature")
assert_contains "feat prefix" "^feat:" "$MSG"

# ============================================================
# Test 6: CODER_SUMMARY.md body still included alongside debt section
# ============================================================
cat > "${TMPDIR}/${CODER_SUMMARY_FILE}" << 'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
Added the null check helper function
## Files Created or Modified
- lib/foo.sh
- lib/bar.sh
EOF

cat > "$NB_FILE" << 'EOF'
# Non-Blocking Log

## Open
- [x] [2026-03-18 | "task"] lib/foo.sh — null check was missing

## Resolved
EOF

MSG=$(generate_commit_message "Add null check")
assert_contains "coder summary in body" "null check helper" "$MSG"
assert_contains "file count in body" "files created or modified" "$MSG"
assert_contains "debt section also present" "Non-blocking notes resolved" "$MSG"

# ============================================================
# Test 7: stripped descriptions — [x] prefix and date prefix removed
# ============================================================
cat > "$NB_FILE" << 'EOF'
# Non-Blocking Log

## Open
- [x] [2026-03-18 | "task"] lib/strip_test.sh — the actual description text

## Resolved
EOF

MSG=$(generate_commit_message "Strip test")
# The description should be present
assert_contains "description text included" "the actual description text" "$MSG"
# The raw checkbox should not appear
assert_not_contains "raw checkbox stripped" "^- \[x\]" "$MSG"

# ============================================================
# Summary
# ============================================================
if [ "$FAIL" -eq 0 ]; then
    echo "All commit message debt section tests passed."
else
    exit 1
fi
