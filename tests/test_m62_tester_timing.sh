#!/usr/bin/env bash
# =============================================================================
# test_m62_tester_timing.sh — Unit tests for M62 tester timing instrumentation
#
# Tests:
#   - _parse_tester_timing extracts timing from sample TESTER_REPORT.md
#   - Missing ## Timing section produces -1 values
#   - Malformed timing values produce -1
#   - Continuation accumulation adds timing across multiple parses
#   - Build gate phases appear as indented sub-rows in TIMING_REPORT.md
#   - Sub-phase percentages computed against parent duration
#   - Tester self-reported timing appears as sub-rows
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# shellcheck source=lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"

# Extract only the parsing functions from tester.sh (avoids sourcing full stage)
# shellcheck disable=SC1090
source <(sed -n '/^_parse_tester_timing()/,/^}/p' "${TEKHTON_HOME}/stages/tester_timing.sh")
# shellcheck disable=SC1090
source <(sed -n '/^_compute_tester_writing_time()/,/^}/p' "${TEKHTON_HOME}/stages/tester_timing.sh")

# =========================================================================
echo "=== Test: Parse timing from valid TESTER_REPORT.md ==="
# =========================================================================

_TESTER_TIMING_EXEC_COUNT=-1
_TESTER_TIMING_EXEC_APPROX_S=-1
_TESTER_TIMING_FILES_WRITTEN=-1

cat > "$TEST_TMPDIR/report_good.md" <<'EOF'
## Planned Tests
- [x] `tests/test_foo.sh` — test foo

## Test Run Results
Passed: 5  Failed: 0

## Bugs Found
None

## Timing
- Test executions: 3
- Approximate total test execution time: 45s
- Test files written: 2
EOF

_parse_tester_timing "$TEST_TMPDIR/report_good.md" "replace"

if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq 3 ]]; then
    pass "Extracted test execution count: 3"
else
    fail "Expected exec count 3, got ${_TESTER_TIMING_EXEC_COUNT}"
fi

if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq 45 ]]; then
    pass "Extracted execution time: 45s"
else
    fail "Expected exec time 45, got ${_TESTER_TIMING_EXEC_APPROX_S}"
fi

if [[ "$_TESTER_TIMING_FILES_WRITTEN" -eq 2 ]]; then
    pass "Extracted files written: 2"
else
    fail "Expected files written 2, got ${_TESTER_TIMING_FILES_WRITTEN}"
fi

# =========================================================================
echo "=== Test: Missing ## Timing section produces -1 ==="
# =========================================================================

_TESTER_TIMING_EXEC_COUNT=-1
_TESTER_TIMING_EXEC_APPROX_S=-1
_TESTER_TIMING_FILES_WRITTEN=-1

cat > "$TEST_TMPDIR/report_no_timing.md" <<'EOF'
## Planned Tests
- [x] `tests/test_foo.sh` — test foo

## Test Run Results
Passed: 5  Failed: 0

## Bugs Found
None
EOF

_parse_tester_timing "$TEST_TMPDIR/report_no_timing.md" "replace"

if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq -1 ]]; then
    pass "Missing timing section: exec count = -1"
else
    fail "Expected exec count -1, got ${_TESTER_TIMING_EXEC_COUNT}"
fi

if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq -1 ]]; then
    pass "Missing timing section: exec time = -1"
else
    fail "Expected exec time -1, got ${_TESTER_TIMING_EXEC_APPROX_S}"
fi

if [[ "$_TESTER_TIMING_FILES_WRITTEN" -eq -1 ]]; then
    pass "Missing timing section: files written = -1"
else
    fail "Expected files written -1, got ${_TESTER_TIMING_FILES_WRITTEN}"
fi

# =========================================================================
echo "=== Test: Malformed timing values produce -1 ==="
# =========================================================================

_TESTER_TIMING_EXEC_COUNT=-1
_TESTER_TIMING_EXEC_APPROX_S=-1
_TESTER_TIMING_FILES_WRITTEN=-1

cat > "$TEST_TMPDIR/report_malformed.md" <<'EOF'
## Timing
- Test executions: many
- Approximate total test execution time: about 30 seconds
- Test files written: several
EOF

_parse_tester_timing "$TEST_TMPDIR/report_malformed.md" "replace"

if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq -1 ]]; then
    pass "Malformed exec count: -1"
else
    fail "Expected malformed exec count -1, got ${_TESTER_TIMING_EXEC_COUNT}"
fi

# Note: "about 30 seconds" does NOT match — the regex requires digits immediately
# after the field prefix (e.g., "Approximate total test execution time: ~?([0-9]+)").
# The truly malformed case is any non-numeric token after the colon.
if [[ "$_TESTER_TIMING_FILES_WRITTEN" -eq -1 ]]; then
    pass "Malformed files written: -1"
else
    fail "Expected malformed files written -1, got ${_TESTER_TIMING_FILES_WRITTEN}"
fi

# =========================================================================
echo "=== Test: Missing report file produces -1 (no crash) ==="
# =========================================================================

_TESTER_TIMING_EXEC_COUNT=-1
_TESTER_TIMING_EXEC_APPROX_S=-1
_TESTER_TIMING_FILES_WRITTEN=-1

_parse_tester_timing "$TEST_TMPDIR/nonexistent.md" "replace"

if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq -1 ]]; then
    pass "Missing file: exec count = -1"
else
    fail "Expected -1 for missing file, got ${_TESTER_TIMING_EXEC_COUNT}"
fi

# =========================================================================
echo "=== Test: Continuation accumulation ==="
# =========================================================================

_TESTER_TIMING_EXEC_COUNT=-1
_TESTER_TIMING_EXEC_APPROX_S=-1
_TESTER_TIMING_FILES_WRITTEN=-1

# First parse: replace mode
cat > "$TEST_TMPDIR/report_cont1.md" <<'EOF'
## Timing
- Test executions: 2
- Approximate total test execution time: 20s
- Test files written: 1
EOF

_parse_tester_timing "$TEST_TMPDIR/report_cont1.md" "replace"

if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq 2 ]]; then
    pass "First parse: exec count = 2"
else
    fail "First parse: expected 2, got ${_TESTER_TIMING_EXEC_COUNT}"
fi

# Second parse: accumulate mode
cat > "$TEST_TMPDIR/report_cont2.md" <<'EOF'
## Timing
- Test executions: 3
- Approximate total test execution time: 30s
- Test files written: 2
EOF

_parse_tester_timing "$TEST_TMPDIR/report_cont2.md" "accumulate"

if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq 5 ]]; then
    pass "Accumulated exec count: 2 + 3 = 5"
else
    fail "Expected accumulated exec count 5, got ${_TESTER_TIMING_EXEC_COUNT}"
fi

if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq 50 ]]; then
    pass "Accumulated exec time: 20 + 30 = 50"
else
    fail "Expected accumulated exec time 50, got ${_TESTER_TIMING_EXEC_APPROX_S}"
fi

if [[ "$_TESTER_TIMING_FILES_WRITTEN" -eq 3 ]]; then
    pass "Accumulated files written: 1 + 2 = 3"
else
    fail "Expected accumulated files written 3, got ${_TESTER_TIMING_FILES_WRITTEN}"
fi

# =========================================================================
echo "=== Test: _compute_tester_writing_time ==="
# =========================================================================

_TESTER_TIMING_EXEC_APPROX_S=45

result=$(_compute_tester_writing_time 120)
if [[ "$result" -eq 75 ]]; then
    pass "Writing time: 120 - 45 = 75s"
else
    fail "Expected writing time 75, got ${result}"
fi

# Edge case: exec time > agent duration (agent overestimated)
_TESTER_TIMING_EXEC_APPROX_S=150
result=$(_compute_tester_writing_time 120)
if [[ "$result" -eq 0 ]]; then
    pass "Writing time clamped to 0 when exec > duration"
else
    fail "Expected clamped writing time 0, got ${result}"
fi

# Edge case: no exec time available
_TESTER_TIMING_EXEC_APPROX_S=-1
result=$(_compute_tester_writing_time 120)
if [[ "$result" -eq -1 ]]; then
    pass "Writing time -1 when exec time unavailable"
else
    fail "Expected -1 when exec time unavailable, got ${result}"
fi

# The TIMING_REPORT.md emission tests that used to live here were retired
# when lib/timing.sh was deleted — that path is owned by Go now
# (internal/finalize/emit_timing_report.go + emit_timing_report_test.go).

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
