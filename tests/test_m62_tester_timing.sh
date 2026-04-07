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

# =========================================================================
echo "=== Test: Build gate sub-phases in TIMING_REPORT.md ==="
# =========================================================================

# shellcheck source=lib/timing.sh
source "${TEKHTON_HOME}/lib/timing.sh"

# Reset phase data
_PHASE_STARTS=()
_PHASE_TIMINGS=()

# Simulate build gate phases
_PHASE_TIMINGS=([build_gate]=30 [build_gate_compile]=15 [build_gate_analyze]=10 [build_gate_constraints]=5)

# Set globals needed by the report emitter (consumed by sourced timing.sh)
# shellcheck disable=SC2034
LOG_DIR="$TEST_TMPDIR"
# shellcheck disable=SC2034
TIMESTAMP="20260406_120000"
# shellcheck disable=SC2034
TOTAL_TIME=100
# shellcheck disable=SC2034
TOTAL_AGENT_INVOCATIONS=3
# shellcheck disable=SC2034
MAX_AUTONOMOUS_AGENT_CALLS=20
_TESTER_TIMING_EXEC_APPROX_S=-1  # Disable tester timing for this test

# Need _PHASE_STARTS for the close-unclosed-phases logic
declare -gA _PHASE_STARTS=()

# Stub get_repo_map_cache_stats to avoid errors
get_repo_map_cache_stats() { echo "hits:0 gen_time_ms:0"; }

_hook_emit_timing_report 0

report_content=$(cat "$TEST_TMPDIR/TIMING_REPORT.md")

if echo "$report_content" | grep -q '↳ Build gate (compile)'; then
    pass "Build gate compile sub-phase appears indented"
else
    fail "Build gate compile sub-phase not found in report"
    echo "$report_content"
fi

if echo "$report_content" | grep -q '↳ Build gate (analyze)'; then
    pass "Build gate analyze sub-phase appears indented"
else
    fail "Build gate analyze sub-phase not found in report"
fi

if echo "$report_content" | grep -q '↳ Build gate (constraints)'; then
    pass "Build gate constraints sub-phase appears indented"
else
    fail "Build gate constraints sub-phase not found in report"
fi

# Verify sub-phases have "of parent" in their percentage column
if echo "$report_content" | grep -q 'of parent'; then
    pass "Sub-phase percentages reference parent"
else
    fail "Sub-phase percentages should reference parent, not total"
    echo "$report_content"
fi

# Verify sub-phase percentages sum to ~100% of parent
# build_gate_compile=15/30=50%, build_gate_analyze=10/30=33%, build_gate_constraints=5/30=16%
# Total: 99% (rounding)
compile_pct=$(echo "$report_content" | grep '↳ Build gate (compile)' | grep -oE '[0-9]+% of parent' | grep -oE '^[0-9]+')
analyze_pct=$(echo "$report_content" | grep '↳ Build gate (analyze)' | grep -oE '[0-9]+% of parent' | grep -oE '^[0-9]+')
constraints_pct=$(echo "$report_content" | grep '↳ Build gate (constraints)' | grep -oE '[0-9]+% of parent' | grep -oE '^[0-9]+')

sum_pct=$(( ${compile_pct:-0} + ${analyze_pct:-0} + ${constraints_pct:-0} ))
if [[ "$sum_pct" -ge 95 ]] && [[ "$sum_pct" -le 105 ]]; then
    pass "Sub-phase percentages sum to ~100% of parent (${sum_pct}%)"
else
    fail "Sub-phase percentages sum to ${sum_pct}%, expected ~100%"
fi

# =========================================================================
echo "=== Test: Tester self-reported timing sub-rows ==="
# =========================================================================

_PHASE_STARTS=()
_PHASE_TIMINGS=([tester_agent]=600)
_TESTER_TIMING_EXEC_COUNT=5
_TESTER_TIMING_EXEC_APPROX_S=300
_TESTER_TIMING_FILES_WRITTEN=3
# shellcheck disable=SC2034
TOTAL_TIME=1000

_hook_emit_timing_report 0

report_content=$(cat "$TEST_TMPDIR/TIMING_REPORT.md")

if echo "$report_content" | grep -q '↳ Test execution'; then
    pass "Tester execution sub-row appears"
else
    fail "Tester execution sub-row not found"
    echo "$report_content"
fi

if echo "$report_content" | grep -q '↳ Test writing'; then
    pass "Tester writing sub-row appears"
else
    fail "Tester writing sub-row not found"
    echo "$report_content"
fi

# Verify ~ prefix for estimated values
if echo "$report_content" | grep '↳ Test execution' | grep -q '~'; then
    pass "Tester execution shows ~ prefix for estimated values"
else
    fail "Tester execution should show ~ prefix"
fi

if echo "$report_content" | grep '↳ Test writing' | grep -q '~'; then
    pass "Tester writing shows ~ prefix for estimated values"
else
    fail "Tester writing should show ~ prefix"
fi

# Verify "of tester" in percentage column
if echo "$report_content" | grep '↳ Test execution' | grep -q 'of tester'; then
    pass "Tester execution percentage references tester"
else
    fail "Tester execution percentage should reference tester"
fi

# =========================================================================
echo "=== Test: No tester timing sub-rows when data unavailable ==="
# =========================================================================

_PHASE_STARTS=()
_PHASE_TIMINGS=([tester_agent]=600)
_TESTER_TIMING_EXEC_COUNT=-1
_TESTER_TIMING_EXEC_APPROX_S=-1
_TESTER_TIMING_FILES_WRITTEN=-1
# shellcheck disable=SC2034
TOTAL_TIME=1000

_hook_emit_timing_report 0

report_content=$(cat "$TEST_TMPDIR/TIMING_REPORT.md")

if ! echo "$report_content" | grep -q '↳ Test execution'; then
    pass "No tester sub-rows when timing unavailable"
else
    fail "Tester sub-rows should not appear when timing is -1"
fi

# =========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
