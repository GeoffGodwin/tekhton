#!/usr/bin/env bash
# =============================================================================
# test_m62_resume_cumulative_overcount.sh — Verify that accumulate mode
# correctly adds delta values across continuations.
#
# Context (M62):
#   prompts/tester_resume.prompt.md instructs the agent to write per-continuation
#   delta values (not cumulative totals). tester_continuation.sh calls
#   _parse_tester_timing "accumulate", which adds deltas to the running total.
#
# This test verifies:
#   1. replace + accumulate with delta values works correctly
#   2. Multiple sequential accumulations produce correct sums
#   3. Accumulate on -1 baseline sets (not adds)
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
echo "=== Test: replace then accumulate — second file has DELTA values ==="
# (Baseline: this is the scenario existing tests already cover)
# =========================================================================

_TESTER_TIMING_EXEC_COUNT=-1
_TESTER_TIMING_EXEC_APPROX_S=-1
_TESTER_TIMING_FILES_WRITTEN=-1

cat > "$TEST_TMPDIR/primary_run.md" <<'EOF'
## Timing
- Test executions: 5
- Approximate total test execution time: 100s
- Test files written: 3
EOF

_parse_tester_timing "$TEST_TMPDIR/primary_run.md" "replace"

if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq 5 ]]; then
    pass "After replace: exec count = 5"
else
    fail "After replace: expected exec count 5, got ${_TESTER_TIMING_EXEC_COUNT}"
fi

# Continuation with DELTA values (3 more tests, 60s more)
cat > "$TEST_TMPDIR/continuation_delta.md" <<'EOF'
## Timing
- Test executions: 3
- Approximate total test execution time: 60s
- Test files written: 2
EOF

_parse_tester_timing "$TEST_TMPDIR/continuation_delta.md" "accumulate"

if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq 8 ]]; then
    pass "Accumulate with delta: 5 + 3 = 8"
else
    fail "Accumulate with delta: expected 8, got ${_TESTER_TIMING_EXEC_COUNT}"
fi

if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq 160 ]]; then
    pass "Accumulate with delta: 100 + 60 = 160s"
else
    fail "Accumulate with delta: expected 160, got ${_TESTER_TIMING_EXEC_APPROX_S}"
fi

if [[ "$_TESTER_TIMING_FILES_WRITTEN" -eq 5 ]]; then
    pass "Accumulate with delta: 3 + 2 = 5"
else
    fail "Accumulate with delta: expected 5, got ${_TESTER_TIMING_FILES_WRITTEN}"
fi

# =========================================================================
echo "=== Test: replace then accumulate — second file has DELTA values (variation) ==="
# (Resume prompt instructs agents to write per-continuation deltas)
# =========================================================================

_TESTER_TIMING_EXEC_COUNT=-1
_TESTER_TIMING_EXEC_APPROX_S=-1
_TESTER_TIMING_FILES_WRITTEN=-1

# Primary run: 5 executions, 100s, 3 files
cat > "$TEST_TMPDIR/primary_run2.md" <<'EOF'
## Timing
- Test executions: 5
- Approximate total test execution time: 100s
- Test files written: 3
EOF

_parse_tester_timing "$TEST_TMPDIR/primary_run2.md" "replace"

# Continuation report: agent writes DELTA values (this continuation only)
# Agent ran 3 more tests in 60s and wrote 2 more files
cat > "$TEST_TMPDIR/continuation_delta2.md" <<'EOF'
## Timing
- Test executions: 3
- Approximate total test execution time: ~60s
- Test files written: 2
EOF

_parse_tester_timing "$TEST_TMPDIR/continuation_delta2.md" "accumulate"

# Expected: 5+3=8, 100+60=160, 3+2=5
expected_exec=8
expected_time=160
expected_files=5

if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq "$expected_exec" ]]; then
    pass "Delta resume: exec count = ${expected_exec}"
else
    fail "Delta resume: expected exec count ${expected_exec}, got ${_TESTER_TIMING_EXEC_COUNT}"
fi

if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq "$expected_time" ]]; then
    pass "Delta resume: exec time = ${expected_time}s"
else
    fail "Delta resume: expected exec time ${expected_time}, got ${_TESTER_TIMING_EXEC_APPROX_S}"
fi

if [[ "$_TESTER_TIMING_FILES_WRITTEN" -eq "$expected_files" ]]; then
    pass "Delta resume: files written = ${expected_files}"
else
    fail "Delta resume: expected files written ${expected_files}, got ${_TESTER_TIMING_FILES_WRITTEN}"
fi

# =========================================================================
echo "=== Test: three sequential continuations — each writes delta values ==="
# (Verifies accumulation is correct across multiple continuations)
# =========================================================================

_TESTER_TIMING_EXEC_COUNT=-1
_TESTER_TIMING_EXEC_APPROX_S=-1
_TESTER_TIMING_FILES_WRITTEN=-1

# Primary run: replace (4 exec, 80s, 2 files)
cat > "$TEST_TMPDIR/run0.md" <<'EOF'
## Timing
- Test executions: 4
- Approximate total test execution time: 80s
- Test files written: 2
EOF
_parse_tester_timing "$TEST_TMPDIR/run0.md" "replace"

# Continuation 1: delta (2 more exec, 40s, 1 file)
cat > "$TEST_TMPDIR/run1.md" <<'EOF'
## Timing
- Test executions: 2
- Approximate total test execution time: 40s
- Test files written: 1
EOF
_parse_tester_timing "$TEST_TMPDIR/run1.md" "accumulate"

# Continuation 2: delta (2 more exec, 40s, 1 file)
cat > "$TEST_TMPDIR/run2.md" <<'EOF'
## Timing
- Test executions: 2
- Approximate total test execution time: 40s
- Test files written: 1
EOF
_parse_tester_timing "$TEST_TMPDIR/run2.md" "accumulate"

# Expected: 4+2+2=8, 80+40+40=160, 2+1+1=4
if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq 8 ]]; then
    pass "Three-continuation delta: exec count = 8 (correct)"
else
    fail "Three-continuation delta: expected 8, got ${_TESTER_TIMING_EXEC_COUNT}"
fi

if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq 160 ]]; then
    pass "Three-continuation delta: exec time = 160s (correct)"
else
    fail "Three-continuation delta: expected 160s, got ${_TESTER_TIMING_EXEC_APPROX_S}"
fi

if [[ "$_TESTER_TIMING_FILES_WRITTEN" -eq 4 ]]; then
    pass "Three-continuation delta: files written = 4 (correct)"
else
    fail "Three-continuation delta: expected 4, got ${_TESTER_TIMING_FILES_WRITTEN}"
fi

# =========================================================================
echo "=== Test: accumulate on -1 baseline + delta report (first continuation, no prior replace) ==="
# When the primary run _parse_tester_timing "replace" was never called but the
# continuation fires "accumulate" on a delta report — should set, not add to -1.
# =========================================================================

_TESTER_TIMING_EXEC_COUNT=-1
_TESTER_TIMING_EXEC_APPROX_S=-1
_TESTER_TIMING_FILES_WRITTEN=-1

cat > "$TEST_TMPDIR/first_accum.md" <<'EOF'
## Timing
- Test executions: 7
- Approximate total test execution time: 140s
- Test files written: 4
EOF

# Accumulate on -1 baseline: should behave like a set (not add)
_parse_tester_timing "$TEST_TMPDIR/first_accum.md" "accumulate"

if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq 7 ]]; then
    pass "Accumulate on -1 baseline: exec count set to 7"
else
    fail "Accumulate on -1 baseline: expected 7, got ${_TESTER_TIMING_EXEC_COUNT}"
fi

if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq 140 ]]; then
    pass "Accumulate on -1 baseline: exec time set to 140"
else
    fail "Accumulate on -1 baseline: expected 140, got ${_TESTER_TIMING_EXEC_APPROX_S}"
fi

# =========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
