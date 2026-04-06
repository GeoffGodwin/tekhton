#!/usr/bin/env bash
# Test: lib/timing.sh — M61 repo map cache stats section in _hook_emit_timing_report
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

TMPDIR_TIMING="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TIMING"' EXIT

export LOG_DIR="${TMPDIR_TIMING}/logs"
export TIMESTAMP="20260406_120000"
export TOTAL_TIME=0
export TOTAL_AGENT_INVOCATIONS=2
export MAX_AUTONOMOUS_AGENT_CALLS=20
export PROJECT_DIR="$TMPDIR_TIMING"
mkdir -p "$LOG_DIR"

# Source common.sh — provides _PHASE_TIMINGS, _format_duration_human, _phase_start/_phase_end
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"

# Source timing.sh under test
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/timing.sh"

# Helper: reset phase state and log dir between tests
reset_timing_state() {
    # Clear associative arrays
    for key in "${!_PHASE_TIMINGS[@]}"; do
        unset '_PHASE_TIMINGS[$key]'
    done
    for key in "${!_PHASE_STARTS[@]}"; do
        unset '_PHASE_STARTS[$key]'
    done
    rm -f "${LOG_DIR}/TIMING_REPORT.md"
    TOTAL_TIME=0
    TOTAL_AGENT_INVOCATIONS=2
}

# Seed at least one timing entry so the report is not skipped
seed_phase() {
    _PHASE_TIMINGS["coder_agent"]=120
}

# =============================================================================
# T1: hits>0 and gen_time_ms>0 → repo map line with correct saved time
# =============================================================================
echo "=== T1: hits>0 and gen_time_ms>0 ==="

reset_timing_state
seed_phase

get_repo_map_cache_stats() { echo "hits:3 gen_time_ms:1500"; }

_hook_emit_timing_report 0

report="${LOG_DIR}/TIMING_REPORT.md"
if [[ ! -f "$report" ]]; then
    fail "T1: TIMING_REPORT.md not created"
else
    pass "T1: TIMING_REPORT.md created"
fi

if grep -q "Repo map: 1 generation + 3 cache hits" "$report"; then
    pass "T1: repo map line present with correct hit count"
else
    fail "T1: repo map line missing or wrong hit count ($(grep 'Repo map' "$report" || echo 'NOT FOUND'))"
fi

# saved_s = 3 * 1500 / 1000 = 4
if grep -q "saved ~4s" "$report"; then
    pass "T1: saved time calculated correctly (4s)"
else
    fail "T1: wrong saved time in report ($(grep 'Repo map' "$report" || echo 'NOT FOUND'))"
fi

# =============================================================================
# T2: hits=1, gen_time_ms=2000 → saved=2s
# =============================================================================
echo "=== T2: hits=1 gen_time_ms=2000 ==="

reset_timing_state
seed_phase

get_repo_map_cache_stats() { echo "hits:1 gen_time_ms:2000"; }

_hook_emit_timing_report 0

if grep -q "Repo map: 1 generation + 1 cache hits" "$report"; then
    pass "T2: repo map line present with hits=1"
else
    fail "T2: repo map line missing or wrong hit count"
fi

if grep -q "saved ~2s" "$report"; then
    pass "T2: saved time calculated correctly (2s)"
else
    fail "T2: wrong saved time ($(grep 'Repo map' "$report" || echo 'NOT FOUND'))"
fi

# =============================================================================
# T3: hits=0 and gen_time_ms=0 → repo map line omitted entirely
# =============================================================================
echo "=== T3: hits=0 gen_time_ms=0 → no repo map line ==="

reset_timing_state
seed_phase

get_repo_map_cache_stats() { echo "hits:0 gen_time_ms:0"; }

_hook_emit_timing_report 0

if grep -q "Repo map:" "$report"; then
    fail "T3: repo map line should be absent when hits=0 and gen_time_ms=0 (found: $(grep 'Repo map' "$report"))"
else
    pass "T3: repo map line absent when hits=0 and gen_time_ms=0"
fi

# =============================================================================
# T4: gen_time_ms>0 but hits=0 → line appears with saved~0s (boundary)
# =============================================================================
echo "=== T4: hits=0 gen_time_ms=3000 → line appears, saved=0s ==="

reset_timing_state
seed_phase

get_repo_map_cache_stats() { echo "hits:0 gen_time_ms:3000"; }

_hook_emit_timing_report 0

if grep -q "Repo map:" "$report"; then
    pass "T4: repo map line present when gen_time_ms>0 (even with hits=0)"
else
    fail "T4: repo map line absent when gen_time_ms=3000 (expected present)"
fi

if grep -q "saved ~0s" "$report"; then
    pass "T4: saved time is 0s when hits=0"
else
    fail "T4: wrong saved time ($(grep 'Repo map' "$report" || echo 'NOT FOUND'))"
fi

# =============================================================================
# T5: get_repo_map_cache_stats not defined → repo map line omitted
# =============================================================================
echo "=== T5: get_repo_map_cache_stats not declared → no repo map line ==="

reset_timing_state
seed_phase

unset -f get_repo_map_cache_stats

_hook_emit_timing_report 0

if grep -q "Repo map:" "$report"; then
    fail "T5: repo map line should be absent when get_repo_map_cache_stats not declared"
else
    pass "T5: repo map line absent when function not available"
fi

# Restore to avoid leaking into other test sections
get_repo_map_cache_stats() { echo "hits:0 gen_time_ms:0"; }

# =============================================================================
# T6: No phases recorded → report not written (early return)
# =============================================================================
echo "=== T6: No phases → report not written ==="

reset_timing_state
# Do NOT seed_phase — leave _PHASE_TIMINGS empty

get_repo_map_cache_stats() { echo "hits:5 gen_time_ms:1000"; }

_hook_emit_timing_report 0

if [[ ! -f "$report" ]]; then
    pass "T6: no phases → TIMING_REPORT.md not created"
else
    fail "T6: TIMING_REPORT.md should not be created when no phases recorded"
fi

# =============================================================================
# T7: hits=5, gen_time_ms=1000 → saved=5s (rounded integer arithmetic)
# =============================================================================
echo "=== T7: hits=5 gen_time_ms=1000 ==="

reset_timing_state
seed_phase

get_repo_map_cache_stats() { echo "hits:5 gen_time_ms:1000"; }

_hook_emit_timing_report 0

if grep -q "saved ~5s" "$report"; then
    pass "T7: saved time calculated correctly (5*1000/1000=5)"
else
    fail "T7: wrong saved time ($(grep 'Repo map' "$report" || echo 'NOT FOUND'))"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo

[ "$FAIL" -eq 0 ]
