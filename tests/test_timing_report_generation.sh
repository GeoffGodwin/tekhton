#!/usr/bin/env bash
# =============================================================================
# test_timing_report_generation.sh — Integration test for TIMING_REPORT.md
#
# Tests: _hook_emit_timing_report generates valid markdown, percentage
#        correctness, _format_timing_banner output, _get_top_phases ordering
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

LOG_DIR="$TEST_TMPDIR/logs"
PROJECT_DIR="$TEST_TMPDIR"
mkdir -p "$LOG_DIR"
TIMESTAMP="20260401_120000"

# Stub logging
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source common.sh (timing helpers) and timing.sh (report functions)
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/stages/tester_timing.sh"
source "${TEKHTON_HOME}/lib/timing.sh"

# Globals expected by timing.sh
TOTAL_AGENT_INVOCATIONS=4
MAX_AUTONOMOUS_AGENT_CALLS=20

echo "=== Test: _hook_emit_timing_report generates valid markdown ==="

_PHASE_STARTS=()
_PHASE_TIMINGS=()

# Simulate recorded phases
_PHASE_TIMINGS[coder_agent]=262
_PHASE_TIMINGS[scout_agent]=45
_PHASE_TIMINGS[build_gate]=28
_PHASE_TIMINGS[reviewer_agent]=38
_PHASE_TIMINGS[tester_agent]=12
_PHASE_TIMINGS[context_assembly]=2
_PHASE_TIMINGS[finalization]=1

TOTAL_TIME=388

_hook_emit_timing_report 0

report_file="${LOG_DIR}/TIMING_REPORT.md"
if [[ -f "$report_file" ]]; then
    pass "TIMING_REPORT.md was created"
else
    fail "TIMING_REPORT.md was not created"
    echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
    exit "$FAIL"
fi

# Check it has the table header
if grep -q "| Phase | Duration | % of Total |" "$report_file"; then
    pass "Report contains table header"
else
    fail "Report missing table header"
fi

# Check it has Total wall time
if grep -q "Total wall time:" "$report_file"; then
    pass "Report contains total wall time"
else
    fail "Report missing total wall time"
fi

# Check it has Agent calls
if grep -q "Agent calls:" "$report_file"; then
    pass "Report contains agent call count"
else
    fail "Report missing agent call count"
fi

# Check that the coder agent line exists with correct display name
if grep -q "Coder (agent)" "$report_file"; then
    pass "Report contains 'Coder (agent)' phase"
else
    fail "Report missing 'Coder (agent)' phase"
fi

echo "=== Test: percentages are reasonable ==="

# Extract all percentage values from the table
pct_sum=0
while IFS= read -r line; do
    pct=$(echo "$line" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)%.*/\1/p')
    if [[ -n "$pct" ]]; then
        pct_sum=$((pct_sum + pct))
    fi
done < "$report_file"

# Percentages should sum to roughly 100 (integer rounding may cause +-5)
if [[ "$pct_sum" -ge 90 ]] && [[ "$pct_sum" -le 110 ]]; then
    pass "Percentages sum to ~100% (got ${pct_sum}%)"
else
    fail "Percentages sum to ${pct_sum}% (expected ~100%)"
fi

echo "=== Test: phases sorted by duration descending ==="

# Extract durations from the report (the Duration column)
prev_dur=999999
sorted_ok=true
while IFS= read -r line; do
    # Skip non-table lines
    [[ "$line" =~ ^\| ]] || continue
    [[ "$line" =~ "Phase" ]] && continue
    [[ "$line" =~ "---" ]] && continue
    # Extract the seconds value
    dur_str=$(echo "$line" | awk -F'|' '{print $3}' | tr -d ' ')
    # Parse "4m 22s" or "45s" to seconds
    mins=0; secs=0
    if [[ "$dur_str" =~ ([0-9]+)m ]]; then
        mins="${BASH_REMATCH[1]}"
    fi
    if [[ "$dur_str" =~ ([0-9]+)s ]]; then
        secs="${BASH_REMATCH[1]}"
    fi
    total_secs=$((mins * 60 + secs))
    if [[ "$total_secs" -gt "$prev_dur" ]]; then
        sorted_ok=false
    fi
    prev_dur="$total_secs"
done < "$report_file"

if [[ "$sorted_ok" = true ]]; then
    pass "Phases are sorted by duration descending"
else
    fail "Phases are NOT sorted by duration descending"
fi

echo "=== Test: _get_top_phases returns correct count ==="

top3=$(_get_top_phases 3)
count=$(echo "$top3" | grep -c '|' || echo "0")
if [[ "$count" -eq 3 ]]; then
    pass "_get_top_phases 3 returns 3 phases"
else
    fail "_get_top_phases 3 returned ${count} phases"
fi

# Verify first entry is the largest
first_dur=$(echo "$top3" | head -1 | cut -d'|' -f1)
if [[ "$first_dur" -eq 262 ]]; then
    pass "Top phase is coder_agent (262s)"
else
    fail "Expected top phase duration 262, got ${first_dur}"
fi

echo "=== Test: _format_timing_banner output ==="

banner=$(_format_timing_banner)
if [[ -n "$banner" ]]; then
    pass "_format_timing_banner produces output"
else
    fail "_format_timing_banner returned empty"
fi

# Should contain the top phase display name
if echo "$banner" | grep -q "Coder (agent)"; then
    pass "Banner contains 'Coder (agent)'"
else
    fail "Banner missing 'Coder (agent)'"
fi

echo "=== Test: _phase_display_name maps keys correctly ==="

[[ "$(_phase_display_name "coder_agent")" = "Coder (agent)" ]] && pass "coder_agent → Coder (agent)" || fail "coder_agent mapping"
[[ "$(_phase_display_name "build_gate_analyze")" = "Build gate (analyze)" ]] && pass "build_gate_analyze mapping" || fail "build_gate_analyze mapping"
[[ "$(_phase_display_name "finalization")" = "Finalization" ]] && pass "finalization mapping" || fail "finalization mapping"
[[ "$(_phase_display_name "custom_thing")" = "custom_thing" ]] && pass "Unknown key passes through" || fail "Unknown key passthrough"

echo "=== Test: empty phase timings skips report ==="

_PHASE_TIMINGS=()
rm -f "${LOG_DIR}/TIMING_REPORT.md"
_hook_emit_timing_report 0

if [[ ! -f "${LOG_DIR}/TIMING_REPORT.md" ]]; then
    pass "No report generated when no phases recorded"
else
    fail "Report should not be generated when no phases recorded"
fi

echo "=== Test: unclosed phases are auto-closed ==="

_PHASE_STARTS=()
_PHASE_TIMINGS=()
_PHASE_STARTS[orphan]=1000000000
_hook_emit_timing_report 0

# The orphan phase should have been closed (has some duration)
dur=$(_get_phase_duration "orphan")
if [[ "$dur" -ge 0 ]]; then
    pass "Unclosed phase was auto-closed during report emission"
else
    fail "Unclosed phase was not auto-closed"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
exit "$FAIL"
