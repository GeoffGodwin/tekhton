#!/usr/bin/env bash
# =============================================================================
# test_m62_fixes_integration.sh — Integration test verifying all M62/M61
# fixes work together in a realistic scenario
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== test_m62_fixes_integration.sh ==="

# Test 1: Verify all modified files exist and are readable.
# m21: lib/finalize_summary.sh ported to internal/finalize/emit_run_summary.go.
# Post-audit: lib/timing.sh deleted (orphan; canonical owner is
# internal/finalize/emit_timing_report.go).
# m37.2: stages/review.sh ported to internal/stages/review/RunStage; the
# review-stage file existence assertion is superseded by go-side coverage.
files_ok=0
[[ -r "${TEKHTON_HOME}/lib/indexer.sh" ]] && files_ok=$((files_ok + 1))
[[ -r "${TEKHTON_HOME}/stages/tester.sh" ]] && files_ok=$((files_ok + 1))
if [[ $files_ok -eq 2 ]]; then
    pass "All modified files are readable"
else
    fail "Some modified files are missing or unreadable"
fi

# Test 2: Verify tester.sh can be sourced (syntax check)
if bash -n "${TEKHTON_HOME}/stages/tester.sh" 2>/dev/null; then
    pass "stages/tester.sh passes syntax check"
else
    fail "stages/tester.sh has syntax errors"
fi

# Test 3: lib/timing.sh deleted post-audit (orphan dead code);
# canonical owner is internal/finalize/emit_timing_report.go.
pass "lib/timing.sh syntax check superseded by Go port"

# Test 4: m21 — lib/finalize_summary.sh ported to Go. Syntax coverage now
# comes from `go build ./internal/finalize/...`; skip the bash syntax check.
pass "lib/finalize_summary.sh syntax check superseded by Go build (m21)"

# Test 5: Verify indexer.sh can be sourced (syntax check)
if bash -n "${TEKHTON_HOME}/lib/indexer.sh" 2>/dev/null; then
    pass "lib/indexer.sh passes syntax check"
else
    fail "lib/indexer.sh has syntax errors"
fi

# Test 6: m37.2 — stages/review.sh ported to internal/stages/review/.
# Bash syntax check superseded by Go-side build + parity fixtures.
pass "stages/review.sh syntax check superseded by Go port (m37.2)"

# Test 7: Verify _TESTER_TIMING_WRITING_S is properly set to -1 (in tester_timing.sh after M65 extraction)
if grep -q '_TESTER_TIMING_WRITING_S=-1' "${TEKHTON_HOME}/stages/tester_timing.sh"; then
    pass "Tester timing initialization includes _TESTER_TIMING_WRITING_S"
else
    fail "Tester timing initialization missing _TESTER_TIMING_WRITING_S"
fi

# Test 8: m21 — tester-guard logic ported to Go. The equivalent invariant
# (per-stage tester-special-case branch) is asserted by the runSummary
# `stages` collector and covered by emit_run_summary_test.go.
pass "Finalize summary tester guard superseded by Go port (m21)"

# Test 9: lib/timing.sh deleted post-audit; the M62 phase-prefix logic
# moved to internal/finalize (covered by emit_timing_report_test.go).
pass "lib/timing.sh phase-prefix logic superseded by Go port"

# Test 10: m37.2 — the _REVIEW_MAP_FILES bash global was retired alongside
# the review.sh port. The cycle-1 file-list comparison logic in repo-map cache
# invalidation is covered by Go-side cycle tests in internal/stages/review/.
pass "Review.sh _REVIEW_MAP_FILES scope superseded by Go port (m37.2)"

echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
