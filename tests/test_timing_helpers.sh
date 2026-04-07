#!/usr/bin/env bash
# =============================================================================
# test_timing_helpers.sh — Unit tests for M46 timing helpers
#
# Tests: _phase_start, _phase_end, _get_phase_duration, _format_duration_human,
#        nested phases, missing _phase_end, accumulation behavior
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging (common.sh helpers)
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source common.sh for timing helpers
source "${TEKHTON_HOME}/lib/common.sh"

echo "=== Test: _phase_start / _phase_end basic ==="

# Reset state
_PHASE_STARTS=()
_PHASE_TIMINGS=()

_phase_start "test_phase"
sleep 1
_phase_end "test_phase"

dur=$(_get_phase_duration "test_phase")
if [[ "$dur" -ge 1 ]] && [[ "$dur" -le 3 ]]; then
    pass "_phase_start/_phase_end records ~1s duration (got ${dur}s)"
else
    fail "_phase_start/_phase_end expected ~1s, got ${dur}s"
fi

echo "=== Test: _get_phase_duration for unrecorded phase ==="

dur=$(_get_phase_duration "never_started")
if [[ "$dur" -eq 0 ]]; then
    pass "Unrecorded phase returns 0"
else
    fail "Unrecorded phase expected 0, got ${dur}"
fi

echo "=== Test: missing _phase_end does not crash ==="

_PHASE_STARTS=()
_PHASE_TIMINGS=()

_phase_start "orphan_phase"
# Never call _phase_end — should not crash
_phase_end "nonexistent_phase"  # Should silently return
pass "Missing _phase_end handled gracefully"

echo "=== Test: _phase_end without _phase_start is graceful ==="

_PHASE_STARTS=()
_PHASE_TIMINGS=()

_phase_end "never_started_phase"
dur=$(_get_phase_duration "never_started_phase")
if [[ "$dur" -eq 0 ]]; then
    pass "_phase_end without _phase_start is graceful (duration=0)"
else
    fail "Expected 0 for phase never started, got ${dur}"
fi

echo "=== Test: accumulation (repeated phases) ==="

_PHASE_STARTS=()
_PHASE_TIMINGS=()

_phase_start "repeated"
sleep 1
_phase_end "repeated"

_phase_start "repeated"
sleep 1
_phase_end "repeated"

dur=$(_get_phase_duration "repeated")
if [[ "$dur" -ge 2 ]] && [[ "$dur" -le 4 ]]; then
    pass "Accumulated duration for repeated phase (got ${dur}s)"
else
    fail "Expected ~2s accumulated, got ${dur}s"
fi

echo "=== Test: nested phases ==="

_PHASE_STARTS=()
_PHASE_TIMINGS=()

_phase_start "outer"
_phase_start "inner"
sleep 1
_phase_end "inner"
_phase_end "outer"

inner_dur=$(_get_phase_duration "inner")
outer_dur=$(_get_phase_duration "outer")

if [[ "$inner_dur" -ge 1 ]] && [[ "$outer_dur" -ge 1 ]]; then
    pass "Nested phases both recorded (inner=${inner_dur}s, outer=${outer_dur}s)"
else
    fail "Nested phases: inner=${inner_dur}s, outer=${outer_dur}s"
fi

if [[ "$outer_dur" -ge "$inner_dur" ]]; then
    pass "Outer duration >= inner duration"
else
    fail "Outer (${outer_dur}s) should be >= inner (${inner_dur}s)"
fi

echo "=== Test: _format_duration_human ==="

result=$(_format_duration_human 0)
[[ "$result" = "0s" ]] && pass "0 seconds" || fail "Expected '0s', got '${result}'"

result=$(_format_duration_human 45)
[[ "$result" = "45s" ]] && pass "45 seconds" || fail "Expected '45s', got '${result}'"

result=$(_format_duration_human 60)
[[ "$result" = "1m 0s" ]] && pass "60 seconds" || fail "Expected '1m 0s', got '${result}'"

result=$(_format_duration_human 262)
[[ "$result" = "4m 22s" ]] && pass "262 seconds" || fail "Expected '4m 22s', got '${result}'"

result=$(_format_duration_human 3600)
[[ "$result" = "60m 0s" ]] && pass "3600 seconds" || fail "Expected '60m 0s', got '${result}'"

echo "=== Test: _get_epoch_secs returns an integer ==="

ts=$(_get_epoch_secs)
if [[ "$ts" =~ ^[0-9]+$ ]]; then
    pass "_get_epoch_secs returns integer (${ts})"
else
    fail "_get_epoch_secs returned non-integer: '${ts}'"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
exit "$FAIL"
