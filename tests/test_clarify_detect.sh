#!/usr/bin/env bash
# Test: detect_clarifications() — blocking/non-blocking parse, empty section, missing file
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME
export TEKHTON_SESSION_DIR="$TMPDIR"
export TEKHTON_TEST_MODE="true"

# Stub logging functions
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }

# Stub _safe_read_file
_safe_read_file() { cat "$1" 2>/dev/null || true; }

# Stub color variables (used by handle_clarifications but not detect)
BOLD=""
NC=""

# Source common.sh for any utilities, then clarify.sh
# shellcheck source=../lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null || true

# Reset log functions after sourcing (common.sh may redefine them)
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }

# shellcheck source=../lib/clarify.sh
source "${TEKHTON_HOME}/lib/clarify.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ============================================================
# Test: missing file returns 1
# ============================================================
echo "=== detect_clarifications — missing file ==="

if ! detect_clarifications "${TMPDIR}/nonexistent.md" 2>/dev/null; then
    pass "Returns 1 when report file does not exist"
else
    fail "Should return 1 for missing file"
fi

# ============================================================
# Test: CLARIFICATION_ENABLED=false returns 1
# ============================================================
echo "=== detect_clarifications — disabled ==="

REPORT="${TMPDIR}/report_disabled.md"
cat > "$REPORT" << 'EOF'
## Clarification Required
- [BLOCKING] What is the auth strategy?
EOF

CLARIFICATION_ENABLED=false
if ! detect_clarifications "$REPORT" 2>/dev/null; then
    pass "Returns 1 when CLARIFICATION_ENABLED=false"
else
    fail "Should return 1 when disabled"
fi
CLARIFICATION_ENABLED=true

# ============================================================
# Test: no "## Clarification Required" section returns 1
# ============================================================
echo "=== detect_clarifications — no section ==="

REPORT_NOSECT="${TMPDIR}/report_nosect.md"
cat > "$REPORT_NOSECT" << 'EOF'
## Status: COMPLETE
## What Was Implemented
- Some feature was built
EOF

if ! detect_clarifications "$REPORT_NOSECT" 2>/dev/null; then
    pass "Returns 1 when no Clarification Required section"
else
    fail "Should return 1 when section absent"
fi

# ============================================================
# Test: section present but empty (no tagged items) returns 1
# ============================================================
echo "=== detect_clarifications — empty section ==="

REPORT_EMPTY="${TMPDIR}/report_empty.md"
cat > "$REPORT_EMPTY" << 'EOF'
## Clarification Required

## Other Section
Some content
EOF

if ! detect_clarifications "$REPORT_EMPTY" 2>/dev/null; then
    pass "Returns 1 when section has no [BLOCKING] or [NON_BLOCKING] items"
else
    fail "Should return 1 for empty section"
fi

# ============================================================
# Test: blocking item detected and written to temp file
# ============================================================
echo "=== detect_clarifications — blocking item ==="

REPORT_BLOCK="${TMPDIR}/report_block.md"
cat > "$REPORT_BLOCK" << 'EOF'
## Clarification Required
- [BLOCKING] What authentication strategy should be used?
- [BLOCKING] Which database engine is preferred?

## Other Section
EOF

if detect_clarifications "$REPORT_BLOCK" 2>/dev/null; then
    pass "Returns 0 when blocking items found"
else
    fail "Should return 0 when blocking items present"
fi

BLOCKING_FILE="${TEKHTON_SESSION_DIR}/clarify_blocking.txt"
if [[ -s "$BLOCKING_FILE" ]]; then
    pass "Blocking items written to clarify_blocking.txt"
else
    fail "clarify_blocking.txt should be non-empty"
fi

BLOCKING_COUNT=$(wc -l < "$BLOCKING_FILE" | tr -d '[:space:]')
if [[ "$BLOCKING_COUNT" -eq 2 ]]; then
    pass "Two blocking items extracted"
else
    fail "Expected 2 blocking items, got ${BLOCKING_COUNT}"
fi

# Verify the [BLOCKING] prefix is stripped (sed 's/^- //')
if grep -q "What authentication strategy" "$BLOCKING_FILE"; then
    pass "Blocking item text preserved"
else
    fail "Blocking item text missing or malformed"
fi

# ============================================================
# Test: non-blocking item detected and written to temp file
# ============================================================
echo "=== detect_clarifications — non-blocking item ==="

# Reset temp files
rm -f "${TEKHTON_SESSION_DIR}/clarify_blocking.txt" "${TEKHTON_SESSION_DIR}/clarify_nonblocking.txt"

REPORT_NB="${TMPDIR}/report_nonblock.md"
cat > "$REPORT_NB" << 'EOF'
## Clarification Required
- [NON_BLOCKING] Is Redis preferred for caching?

## Status
Done
EOF

if detect_clarifications "$REPORT_NB" 2>/dev/null; then
    pass "Returns 0 when non-blocking items found"
else
    fail "Should return 0 when non-blocking items present"
fi

NB_FILE="${TEKHTON_SESSION_DIR}/clarify_nonblocking.txt"
if [[ -s "$NB_FILE" ]]; then
    pass "Non-blocking items written to clarify_nonblocking.txt"
else
    fail "clarify_nonblocking.txt should be non-empty"
fi

# ============================================================
# Test: mixed blocking and non-blocking items
# ============================================================
echo "=== detect_clarifications — mixed items ==="

rm -f "${TEKHTON_SESSION_DIR}/clarify_blocking.txt" "${TEKHTON_SESSION_DIR}/clarify_nonblocking.txt"

REPORT_MIX="${TMPDIR}/report_mix.md"
cat > "$REPORT_MIX" << 'EOF'
## Clarification Required
- [BLOCKING] Which database?
- [NON_BLOCKING] Prefer tabs or spaces?
- [BLOCKING] Which cloud provider?
EOF

if detect_clarifications "$REPORT_MIX" 2>/dev/null; then
    pass "Returns 0 for mixed items"
else
    fail "Should return 0 for mixed items"
fi

BLOCKING_COUNT=$(wc -l < "${TEKHTON_SESSION_DIR}/clarify_blocking.txt" | tr -d '[:space:]')
NB_COUNT=$(wc -l < "${TEKHTON_SESSION_DIR}/clarify_nonblocking.txt" | tr -d '[:space:]')

if [[ "$BLOCKING_COUNT" -eq 2 ]]; then
    pass "Two blocking items in mixed report"
else
    fail "Expected 2 blocking, got ${BLOCKING_COUNT}"
fi

if [[ "$NB_COUNT" -eq 1 ]]; then
    pass "One non-blocking item in mixed report"
else
    fail "Expected 1 non-blocking, got ${NB_COUNT}"
fi

# ============================================================
# Test: section stops at next ## heading
# ============================================================
echo "=== detect_clarifications — section boundary ==="

rm -f "${TEKHTON_SESSION_DIR}/clarify_blocking.txt" "${TEKHTON_SESSION_DIR}/clarify_nonblocking.txt"

REPORT_BOUND="${TMPDIR}/report_bound.md"
cat > "$REPORT_BOUND" << 'EOF'
## Clarification Required
- [BLOCKING] Real question here?

## Files Modified
- [BLOCKING] This is in a different section, should be ignored
EOF

if detect_clarifications "$REPORT_BOUND" 2>/dev/null; then
    pass "Returns 0 for bounded section"
else
    fail "Should detect blocking item"
fi

BLOCKING_COUNT=$(wc -l < "${TEKHTON_SESSION_DIR}/clarify_blocking.txt" | tr -d '[:space:]')
if [[ "$BLOCKING_COUNT" -eq 1 ]]; then
    pass "Section boundary respected — only 1 blocking item extracted"
else
    fail "Expected 1 item (section boundary), got ${BLOCKING_COUNT}"
fi

# ============================================================
# Summary
# ============================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
