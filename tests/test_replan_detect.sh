#!/usr/bin/env bash
# Test: detect_replan_required() and trigger_replan() menu routing
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME
export TEKHTON_SESSION_DIR="$TMPDIR"
export TEKHTON_TEST_MODE="true"

# Pipeline vars needed by replan.sh
export TASK="Implement Milestone 4"
export MILESTONE_MODE=""
export PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
export LOG_DIR="${TMPDIR}/.claude/logs"
export DRIFT_LOG_FILE="${TEKHTON_DIR}/DRIFT_LOG.md"
export ARCHITECTURE_LOG_FILE="${TEKHTON_DIR}/ARCHITECTURE_LOG.md"
export REPLAN_MODEL="opus"
export REPLAN_MAX_TURNS="5"

mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}" "${TMPDIR}/${TEKHTON_DIR}"

# Stub logging functions
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
_safe_read_file() { cat "$1" 2>/dev/null || true; }
BOLD="" ; NC=""

# Stub write_pipeline_state so replan tests don't need full state.sh
write_pipeline_state() { :; }

# shellcheck source=../lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null || true

log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }

# Source state.sh for write_pipeline_state (for trigger_replan [s]/[a] paths)
source "${TEKHTON_HOME}/lib/state.sh"

# shellcheck source=../lib/replan.sh
source "${TEKHTON_HOME}/lib/replan.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ============================================================
# detect_replan_required — missing file
# ============================================================
echo "=== detect_replan_required — missing file ==="

if ! detect_replan_required "${TMPDIR}/nonexistent.md" 2>/dev/null; then
    pass "Returns 1 for missing report file"
else
    fail "Should return 1 for missing file"
fi

# ============================================================
# detect_replan_required — REPLAN_ENABLED=false
# ============================================================
echo "=== detect_replan_required — disabled ==="

REPORT="${TMPDIR}/report_disabled.md"
cat > "$REPORT" << 'EOF'
## Verdict
REPLAN_REQUIRED
EOF

REPLAN_ENABLED=false
if ! detect_replan_required "$REPORT" 2>/dev/null; then
    pass "Returns 1 when REPLAN_ENABLED=false"
else
    fail "Should return 1 when disabled"
fi
REPLAN_ENABLED=true

# ============================================================
# detect_replan_required — no REPLAN_REQUIRED in file
# ============================================================
echo "=== detect_replan_required — not present ==="

REPORT_APPROVED="${TMPDIR}/report_approved.md"
cat > "$REPORT_APPROVED" << 'EOF'
## Verdict
APPROVED

## Notes
- Everything looks good
EOF

if ! detect_replan_required "$REPORT_APPROVED" 2>/dev/null; then
    pass "Returns 1 when verdict is APPROVED (no REPLAN_REQUIRED)"
else
    fail "Should return 1 when REPLAN_REQUIRED not in file"
fi

# ============================================================
# detect_replan_required — REPLAN_REQUIRED present
# ============================================================
echo "=== detect_replan_required — present ==="

REPORT_REPLAN="${TMPDIR}/report_replan.md"
cat > "$REPORT_REPLAN" << 'EOF'
## Verdict
REPLAN_REQUIRED

## Rationale
- The task contradicts the architecture
- Scope is too broad for a single milestone
EOF

if detect_replan_required "$REPORT_REPLAN" 2>/dev/null; then
    pass "Returns 0 when REPLAN_REQUIRED found in report"
else
    fail "Should return 0 when REPLAN_REQUIRED present"
fi

# ============================================================
# detect_replan_required — case insensitive
# ============================================================
echo "=== detect_replan_required — case insensitive ==="

REPORT_LOWER="${TMPDIR}/report_lower.md"
cat > "$REPORT_LOWER" << 'EOF'
## Verdict
replan_required
EOF

if detect_replan_required "$REPORT_LOWER" 2>/dev/null; then
    pass "Case-insensitive match: 'replan_required' (lowercase) detected"
else
    fail "Should match REPLAN_REQUIRED case-insensitively"
fi

# ============================================================
# detect_replan_required — REPLAN_REQUIRED in body, not just verdict line
# ============================================================
echo "=== detect_replan_required — in body text ==="

REPORT_BODY="${TMPDIR}/report_body.md"
cat > "$REPORT_BODY" << 'EOF'
## Verdict
APPROVED_WITH_NOTES

## Notes
- Consider using REPLAN_REQUIRED if scope grows further
EOF

# This still returns 0 because REPLAN_REQUIRED appears anywhere in file
# (grep -qi "REPLAN_REQUIRED"). This is the designed behavior.
if detect_replan_required "$REPORT_BODY" 2>/dev/null; then
    pass "Detects REPLAN_REQUIRED anywhere in file (expected greedy match)"
else
    fail "Should detect REPLAN_REQUIRED in body text per grep implementation"
fi

# ============================================================
# trigger_replan — 'c' (continue) returns 0 without replan
# ============================================================
echo "=== trigger_replan — continue choice ==="

INPUT_FILE="${TMPDIR}/input_continue.txt"
echo "c" > "$INPUT_FILE"

if trigger_replan "$REPORT_REPLAN" < "$INPUT_FILE" 2>/dev/null; then
    pass "Returns 0 when user chooses 'c' (continue)"
else
    fail "Should return 0 for continue"
fi

# ============================================================
# trigger_replan — 'C' (continue uppercase) returns 0
# ============================================================
echo "=== trigger_replan — continue uppercase ==="

echo "C" > "$INPUT_FILE"
if trigger_replan "$REPORT_REPLAN" < "$INPUT_FILE" 2>/dev/null; then
    pass "Returns 0 when user chooses 'C' (uppercase continue)"
else
    fail "Should return 0 for uppercase continue"
fi

# ============================================================
# trigger_replan — 'a' (abort) returns 1 and saves state
# ============================================================
echo "=== trigger_replan — abort choice ==="

echo "a" > "$INPUT_FILE"
if ! trigger_replan "$REPORT_REPLAN" < "$INPUT_FILE" 2>/dev/null; then
    pass "Returns 1 when user chooses 'a' (abort)"
else
    fail "Should return 1 for abort"
fi

# ============================================================
# trigger_replan — 's' (split) returns 1 and saves state
# ============================================================
echo "=== trigger_replan — split choice ==="

echo "s" > "$INPUT_FILE"
if ! trigger_replan "$REPORT_REPLAN" < "$INPUT_FILE" 2>/dev/null; then
    pass "Returns 1 when user chooses 's' (split)"
else
    fail "Should return 1 for split"
fi

# ============================================================
# trigger_replan — unknown input defaults to abort (returns 1)
# ============================================================
echo "=== trigger_replan — unknown input ==="

echo "z" > "$INPUT_FILE"
if ! trigger_replan "$REPORT_REPLAN" < "$INPUT_FILE" 2>/dev/null; then
    pass "Returns 1 for unrecognized input (default abort)"
else
    fail "Should return 1 for unrecognized input"
fi

# ============================================================
# trigger_replan — EOF on input defaults to abort (returns 1)
# ============================================================
echo "=== trigger_replan — EOF on input ==="

# Empty input file → read returns "" on EOF
true > "$INPUT_FILE"  # 0-byte file

# When read gets EOF, the code does: read -r choice < "$input_fd" || { choice="a"; }
# choice="" → case matches a|A|* → returns 1
if ! trigger_replan "$REPORT_REPLAN" < "$INPUT_FILE" 2>/dev/null; then
    pass "Returns 1 on EOF input (abort fallback)"
else
    fail "Should return 1 when input is EOF"
fi

# ============================================================
# _apply_midrun_delta — appends to CLAUDE.md
# ============================================================
echo "=== _apply_midrun_delta — appends to CLAUDE.md ==="

CLAUDE_FILE="${TMPDIR}/CLAUDE.md"
DELTA_FILE="${TMPDIR}/REPLAN_DELTA.md"

cat > "$CLAUDE_FILE" << 'EOF'
# Project Claude

## Implementation Milestones

#### Milestone 1: Build the thing
Do work.
EOF

cat > "$DELTA_FILE" << 'EOF'
## Updated Milestone 1 Scope

- Narrow to authentication only
- Remove database migration from scope
EOF

_apply_midrun_delta "$DELTA_FILE" 2>/dev/null

if grep -q "## Replan Note" "$CLAUDE_FILE"; then
    pass "CLAUDE.md gains '## Replan Note' section after apply"
else
    fail "'## Replan Note' not found in CLAUDE.md after apply"
fi

if grep -q "Updated Milestone 1 Scope" "$CLAUDE_FILE"; then
    pass "Delta content appended to CLAUDE.md"
else
    fail "Delta content not found in CLAUDE.md"
fi

# Original content preserved
if grep -q "## Implementation Milestones" "$CLAUDE_FILE"; then
    pass "Original CLAUDE.md content preserved after delta apply"
else
    fail "Original content lost after delta apply"
fi

# Delta file moved to archive
if [[ ! -f "$DELTA_FILE" ]]; then
    pass "Delta file archived (removed from original path)"
else
    fail "Delta file should be moved to archive, not remain at original path"
fi

# Verify archive exists
ARCHIVE_FILE=$(find "${LOG_DIR}/archive" -name "*REPLAN_DELTA.md" 2>/dev/null | head -1 || echo "")
if [[ -n "$ARCHIVE_FILE" ]]; then
    pass "Delta file found in archive directory"
else
    fail "Delta file not found in archive directory"
fi

# ============================================================
# _apply_midrun_delta — missing delta file warns and returns 1
# ============================================================
echo "=== _apply_midrun_delta — missing delta file ==="

WARN_COUNT=0
warn() { WARN_COUNT=$((WARN_COUNT + 1)); }

if ! _apply_midrun_delta "${TMPDIR}/nonexistent_delta.md" 2>/dev/null; then
    pass "Returns 1 when delta file not found"
else
    fail "Should return 1 for missing delta file"
fi

if [[ "$WARN_COUNT" -gt 0 ]]; then
    pass "Emits warning when delta file not found"
else
    fail "Expected warning for missing delta file"
fi

warn() { :; }

# ============================================================
# _apply_midrun_delta — missing CLAUDE.md warns and returns 1
# ============================================================
echo "=== _apply_midrun_delta — missing CLAUDE.md ==="

DELTA_FILE2="${TMPDIR}/delta2.md"
echo "Some delta" > "$DELTA_FILE2"

WARN_COUNT=0
warn() { WARN_COUNT=$((WARN_COUNT + 1)); }

# Temporarily rename CLAUDE.md
mv "$CLAUDE_FILE" "${CLAUDE_FILE}.bak"
if ! _apply_midrun_delta "$DELTA_FILE2" 2>/dev/null; then
    pass "Returns 1 when CLAUDE.md not found"
else
    fail "Should return 1 when CLAUDE.md missing"
fi
mv "${CLAUDE_FILE}.bak" "$CLAUDE_FILE"

if [[ "$WARN_COUNT" -gt 0 ]]; then
    pass "Emits warning when CLAUDE.md not found"
else
    fail "Expected warning for missing CLAUDE.md"
fi

warn() { :; }

# ============================================================
# Summary
# ============================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
