#!/usr/bin/env bash
# TIMEOUT_SECS=20
# =============================================================================
# test_coder_block_unavailable_gate.sh — m41 Goal 2 structural regression guard
#
# Acceptance criteria tested:
#   AC2: When set_focused_milestone_block fails (block-unavailable), the coder
#        stage does NOT call trip_commit_gate. The fix removed the
#        `trip_commit_gate "milestone_block_unavailable_..."` call. This test
#        verifies that removal and its replacement (a warn-and-continue pair).
#
#   AC3: The genuine hollow-run gates (coder_did_not_produce_summary,
#        completion_gate_failed_substantive_work_only) are NOT weakened by the
#        m41 change. A hollow run must still be blocked by those gates.
#
# Testing approach: structural. stages/coder.sh is 1200+ lines and requires
# the full pipeline environment to exercise end-to-end. A structural grep
# test is a recognised pattern in this codebase (cf. scripts/wedge-audit.sh,
# tests/test_tekhton_dir_root_cleanliness.sh) for enforcing invariants that
# cannot be covered by unit-testing a single function in isolation.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODER_SH="${TEKHTON_HOME}/stages/coder.sh"

PASS=0 FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# =============================================================================
echo "=== AC2: false-positive trip_commit_gate removed from coder.sh ==="

# m41 removed `trip_commit_gate "milestone_block_unavailable_..."`. If it
# ever comes back (e.g. an accidental revert), this assertion fires red and
# names the culprit so the operator can restore the m41 fix without grepping.
if grep -qE 'trip_commit_gate[[:space:]]+"?milestone_block_unavailable' "$CODER_SH"; then
    fail "milestone_block_unavailable trip_commit_gate is back in stages/coder.sh — m41 fix reverted"
else
    pass "trip_commit_gate 'milestone_block_unavailable' is absent from coder.sh"
fi

# =============================================================================
echo "=== AC2: warn-and-continue pair replaced the false-positive gate ==="

# The m41 change replaces the gate with two warn calls. At minimum the
# "downstream hollow-run gates remain in effect" message must be present so
# operators reading the log understand the new semantic.
if grep -q "hollow-run gates remain in effect" "$CODER_SH"; then
    pass "m41 warn 'hollow-run gates remain in effect' is present in coder.sh"
else
    fail "m41 warn message missing from coder.sh — warn-and-continue path not installed"
fi

# The block-unavailable warn must also include the context variable so the
# operator can identify which milestone failed to resolve.
if grep -q 'MILESTONE_BLOCK could not be populated' "$CODER_SH"; then
    pass "block-unavailable warn naming the milestone is present in coder.sh"
else
    fail "block-unavailable warn is missing from coder.sh"
fi

# =============================================================================
echo "=== AC3: coder_did_not_produce_summary hollow-run gate still present ==="

# m41 narrows ONE false-positive trip. It must NOT remove the genuine
# hollow-run gate that fires when the coder produces no CODER_SUMMARY.
if grep -q 'trip_commit_gate "coder_did_not_produce_summary"' "$CODER_SH"; then
    pass "coder_did_not_produce_summary gate is present — hollow runs still blocked"
else
    fail "coder_did_not_produce_summary gate MISSING from coder.sh — hollow runs will not be blocked"
fi

# =============================================================================
echo "=== AC3: completion_gate_failed_substantive_work_only gate still present ==="

if grep -q 'trip_commit_gate "completion_gate_failed_substantive_work_only"' "$CODER_SH"; then
    pass "completion_gate_failed_substantive_work_only gate is present — hollow runs still blocked"
else
    fail "completion_gate_failed_substantive_work_only gate MISSING from coder.sh"
fi

# =============================================================================
echo "=== AC2: no OTHER milestone_block_unavailable trip exists anywhere ==="

# Sanity-check that the removed call is not hiding elsewhere in the repo's
# bash surface (staged areas, shim files, lib/) with a different quoting style.
found=$(grep -rE 'trip_commit_gate[[:space:]]+"?milestone_block_unavailable' \
    "${TEKHTON_HOME}/stages" "${TEKHTON_HOME}/lib" 2>/dev/null || true)
if [[ -z "$found" ]]; then
    pass "no milestone_block_unavailable trip found in stages/ or lib/"
else
    fail "milestone_block_unavailable trip found outside coder.sh: $found"
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
