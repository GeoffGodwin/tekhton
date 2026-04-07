#!/usr/bin/env bash
# =============================================================================
# test_m65_tester_timing_functions.sh — Functional tests for _parse_tester_timing()
# and _compute_tester_writing_time() with real input.
#
# The coverage gap from M65 review: test_tester_timing_initialization.sh only
# verifies globals via grep — it never calls the actual functions. This file
# fills that gap.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== test_m65_tester_timing_functions.sh ==="

# Source tester_timing.sh to load the functions and globals
source "${TEKHTON_HOME}/stages/tester_timing.sh"

# Helper: reset all timing globals to -1 between tests
reset_timing_globals() {
    _TESTER_TIMING_EXEC_COUNT=-1
    _TESTER_TIMING_EXEC_APPROX_S=-1
    _TESTER_TIMING_FILES_WRITTEN=-1
    _TESTER_TIMING_WRITING_S=-1
}

# Helper: write a TESTER_REPORT.md with a Timing section to a temp file
make_report() {
    local path="$1"
    local exec_count="$2"
    local exec_time="$3"
    local files_written="$4"
    cat > "$path" <<EOF
## Planned Tests
- [x] \`tests/test_foo.sh\` — example

## Test Run Results
Passed: 5  Failed: 0

## Bugs Found
None

## Files Modified
- [x] \`tests/test_foo.sh\`

## Timing
- Test executions: ${exec_count}
- Approximate total test execution time: ${exec_time}s
- Test files written: ${files_written}
EOF
}

# ---------------------------------------------------------------------------
# Group 1: _parse_tester_timing — replace mode (default)
# ---------------------------------------------------------------------------

echo ""
echo "--- Group 1: _parse_tester_timing replace mode ---"

# Test 1: parses exec count correctly
reset_timing_globals
make_report "${TMPDIR_TEST}/report1.md" "3" "45" "2"
_parse_tester_timing "${TMPDIR_TEST}/report1.md"
if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq 3 ]]; then
    pass "_parse_tester_timing: exec count parsed as 3"
else
    fail "_parse_tester_timing: expected exec count=3, got $_TESTER_TIMING_EXEC_COUNT"
fi

# Test 2: parses exec time correctly
if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq 45 ]]; then
    pass "_parse_tester_timing: exec time parsed as 45"
else
    fail "_parse_tester_timing: expected exec time=45, got $_TESTER_TIMING_EXEC_APPROX_S"
fi

# Test 3: parses files written correctly
if [[ "$_TESTER_TIMING_FILES_WRITTEN" -eq 2 ]]; then
    pass "_parse_tester_timing: files written parsed as 2"
else
    fail "_parse_tester_timing: expected files_written=2, got $_TESTER_TIMING_FILES_WRITTEN"
fi

# Test 4: _TESTER_TIMING_WRITING_S stays at -1 (not set by _parse_tester_timing)
if [[ "$_TESTER_TIMING_WRITING_S" -eq -1 ]]; then
    pass "_parse_tester_timing: _TESTER_TIMING_WRITING_S stays -1 (not set by parser)"
else
    fail "_parse_tester_timing: _TESTER_TIMING_WRITING_S should stay -1, got $_TESTER_TIMING_WRITING_S"
fi

# ---------------------------------------------------------------------------
# Group 2: _parse_tester_timing — missing Timing section
# ---------------------------------------------------------------------------

echo ""
echo "--- Group 2: _parse_tester_timing missing Timing section ---"

reset_timing_globals
cat > "${TMPDIR_TEST}/report_notiming.md" <<'EOF'
## Planned Tests
- [x] `tests/test_foo.sh` — example

## Test Run Results
Passed: 3  Failed: 0

## Bugs Found
None
EOF
_parse_tester_timing "${TMPDIR_TEST}/report_notiming.md"

if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq -1 ]]; then
    pass "_parse_tester_timing: exec count stays -1 when no Timing section"
else
    fail "_parse_tester_timing: expected -1 with no Timing, got $_TESTER_TIMING_EXEC_COUNT"
fi
if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq -1 ]]; then
    pass "_parse_tester_timing: exec time stays -1 when no Timing section"
else
    fail "_parse_tester_timing: expected -1 with no Timing, got $_TESTER_TIMING_EXEC_APPROX_S"
fi

# ---------------------------------------------------------------------------
# Group 3: _parse_tester_timing — missing file
# ---------------------------------------------------------------------------

echo ""
echo "--- Group 3: _parse_tester_timing missing file ---"

reset_timing_globals
_parse_tester_timing "${TMPDIR_TEST}/nonexistent.md"
if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq -1 ]]; then
    pass "_parse_tester_timing: returns cleanly when file missing, globals stay -1"
else
    fail "_parse_tester_timing: expected -1 for missing file, got $_TESTER_TIMING_EXEC_COUNT"
fi

# ---------------------------------------------------------------------------
# Group 4: _parse_tester_timing — accumulate mode
# ---------------------------------------------------------------------------

echo ""
echo "--- Group 4: _parse_tester_timing accumulate mode ---"

reset_timing_globals
make_report "${TMPDIR_TEST}/report_a.md" "2" "30" "1"
make_report "${TMPDIR_TEST}/report_b.md" "3" "20" "2"

# First call sets initial values
_parse_tester_timing "${TMPDIR_TEST}/report_a.md" "accumulate"
if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq 2 ]]; then
    pass "_parse_tester_timing accumulate: first call sets exec count to 2"
else
    fail "_parse_tester_timing accumulate: expected 2 after first call, got $_TESTER_TIMING_EXEC_COUNT"
fi

# Second call accumulates
_parse_tester_timing "${TMPDIR_TEST}/report_b.md" "accumulate"
if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq 5 ]]; then
    pass "_parse_tester_timing accumulate: second call adds to exec count (2+3=5)"
else
    fail "_parse_tester_timing accumulate: expected 5 after second call, got $_TESTER_TIMING_EXEC_COUNT"
fi
if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq 50 ]]; then
    pass "_parse_tester_timing accumulate: exec time accumulated (30+20=50)"
else
    fail "_parse_tester_timing accumulate: expected 50, got $_TESTER_TIMING_EXEC_APPROX_S"
fi
if [[ "$_TESTER_TIMING_FILES_WRITTEN" -eq 3 ]]; then
    pass "_parse_tester_timing accumulate: files written accumulated (1+2=3)"
else
    fail "_parse_tester_timing accumulate: expected 3, got $_TESTER_TIMING_FILES_WRITTEN"
fi

# ---------------------------------------------------------------------------
# Group 5: _parse_tester_timing — replace mode overwrites
# ---------------------------------------------------------------------------

echo ""
echo "--- Group 5: _parse_tester_timing replace mode overwrites prior values ---"

reset_timing_globals
make_report "${TMPDIR_TEST}/report_first.md" "5" "90" "4"
_parse_tester_timing "${TMPDIR_TEST}/report_first.md"
# Globals now: exec_count=5, exec_time=90, files_written=4

make_report "${TMPDIR_TEST}/report_second.md" "1" "10" "1"
_parse_tester_timing "${TMPDIR_TEST}/report_second.md"  # replace mode
if [[ "$_TESTER_TIMING_EXEC_COUNT" -eq 1 ]]; then
    pass "_parse_tester_timing replace: overwrites previous exec count (5→1)"
else
    fail "_parse_tester_timing replace: expected 1 after overwrite, got $_TESTER_TIMING_EXEC_COUNT"
fi
if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq 10 ]]; then
    pass "_parse_tester_timing replace: overwrites previous exec time (90→10)"
else
    fail "_parse_tester_timing replace: expected 10 after overwrite, got $_TESTER_TIMING_EXEC_APPROX_S"
fi

# ---------------------------------------------------------------------------
# Group 6: _compute_tester_writing_time — normal case
# ---------------------------------------------------------------------------

echo ""
echo "--- Group 6: _compute_tester_writing_time normal case ---"

reset_timing_globals
_TESTER_TIMING_EXEC_APPROX_S=30

result=$(_compute_tester_writing_time 120)
if [[ "$result" -eq 90 ]]; then
    pass "_compute_tester_writing_time: 120s agent - 30s exec = 90s writing"
else
    fail "_compute_tester_writing_time: expected 90, got $result"
fi

# ---------------------------------------------------------------------------
# Group 7: _compute_tester_writing_time — clamped to zero
# ---------------------------------------------------------------------------

echo ""
echo "--- Group 7: _compute_tester_writing_time clamped to zero ---"

reset_timing_globals
_TESTER_TIMING_EXEC_APPROX_S=200

result=$(_compute_tester_writing_time 50)
if [[ "$result" -eq 0 ]]; then
    pass "_compute_tester_writing_time: clamped to 0 when exec_time > agent_duration"
else
    fail "_compute_tester_writing_time: expected 0, got $result"
fi

# ---------------------------------------------------------------------------
# Group 8: _compute_tester_writing_time — unavailable data returns -1
# ---------------------------------------------------------------------------

echo ""
echo "--- Group 8: _compute_tester_writing_time returns -1 when data unavailable ---"

reset_timing_globals
# exec_approx_s is -1 (sentinel: not set)
result=$(_compute_tester_writing_time 120)
if [[ "$result" -eq -1 ]]; then
    pass "_compute_tester_writing_time: returns -1 when _TESTER_TIMING_EXEC_APPROX_S=-1"
else
    fail "_compute_tester_writing_time: expected -1 with uninitialised exec_time, got $result"
fi

# agent_duration=0 also returns -1
_TESTER_TIMING_EXEC_APPROX_S=30
result=$(_compute_tester_writing_time 0)
if [[ "$result" -eq -1 ]]; then
    pass "_compute_tester_writing_time: returns -1 when agent_duration=0"
else
    fail "_compute_tester_writing_time: expected -1 with agent_duration=0, got $result"
fi

# ---------------------------------------------------------------------------
# Group 9: _parse_tester_timing — tilde prefix on exec time (e.g. ~45s)
# ---------------------------------------------------------------------------

echo ""
echo "--- Group 9: _parse_tester_timing handles tilde-prefixed exec time ---"

reset_timing_globals
cat > "${TMPDIR_TEST}/report_tilde.md" <<'EOF'
## Timing
- Test executions: 2
- Approximate total test execution time: ~45s
- Test files written: 1
EOF
_parse_tester_timing "${TMPDIR_TEST}/report_tilde.md"
if [[ "$_TESTER_TIMING_EXEC_APPROX_S" -eq 45 ]]; then
    pass "_parse_tester_timing: parses tilde-prefixed exec time (~45)"
else
    fail "_parse_tester_timing: expected 45 from ~45s, got $_TESTER_TIMING_EXEC_APPROX_S"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
