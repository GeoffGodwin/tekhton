#!/usr/bin/env bash
# TIMEOUT_SECS=20
# =============================================================================
# test_coder_block_unavailable_gate.sh — m41 Goal 2 regression guard, Go port
#
# m39.4 deleted stages/coder.sh and ported the orchestrator to
# internal/stages/coder/. The m41 fix that this test guards (the
# false-positive trip_commit_gate removal on the block-unavailable path)
# was carried into the Go port — populateMilestone calls deps.TripCommitGate
# only on the genuine hollow-run paths (completion_gate_failed_substantive_work_only),
# not the block-unavailable path. The structural assertions move from grep
# of the bash file to grep of the Go file.
#
# Acceptance criteria tested:
#   AC2: When PopulateMilestoneBlock fails (block-unavailable), the coder
#        stage does NOT call deps.TripCommitGate("milestone_block_unavailable_...").
#        A warn-and-continue replaces it.
#
#   AC3: The genuine hollow-run gate (completion_gate_failed_substantive_work_only)
#        is NOT weakened. It still trips through deps.TripCommitGate in
#        runCompletionGate.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH_GO="${TEKHTON_HOME}/internal/stages/coder/orchestrator.go"

if [[ ! -f "$ORCH_GO" ]]; then
    echo "SKIP: $ORCH_GO not found — m39.4 not yet landed"
    exit 0
fi

PASS=0 FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# =============================================================================
echo "=== AC2: false-positive milestone_block_unavailable trip absent from Go orchestrator ==="

if grep -qE 'milestone_block_unavailable' "$ORCH_GO"; then
    fail "milestone_block_unavailable string found in orchestrator.go — m41 fix reverted"
else
    pass "milestone_block_unavailable string is absent from orchestrator.go"
fi

# =============================================================================
echo "=== AC2: warn-on-failure pair replaced the false-positive gate ==="

if grep -q 'MILESTONE_BLOCK could not be populated' "$ORCH_GO"; then
    pass "block-unavailable warn naming the milestone is present in orchestrator.go"
else
    fail "block-unavailable warn is missing from orchestrator.go"
fi

# =============================================================================
echo "=== AC3: completion_gate_failed_substantive_work_only gate still trips ==="

if grep -q '"completion_gate_failed_substantive_work_only"' "$ORCH_GO"; then
    pass "completion_gate_failed_substantive_work_only gate is present — hollow runs still blocked"
else
    fail "completion_gate_failed_substantive_work_only gate MISSING from orchestrator.go"
fi

# =============================================================================
echo "=== AC2: no milestone_block_unavailable trip exists anywhere in repo ==="

found=$(grep -rE 'milestone_block_unavailable' \
    "${TEKHTON_HOME}/internal" "${TEKHTON_HOME}/lib" "${TEKHTON_HOME}/cmd" \
    2>/dev/null \
    | grep -v '_test\.go' \
    | grep -v '^[^:]*\.md:' || true)
if [[ -z "$found" ]]; then
    pass "no milestone_block_unavailable trip found in Go or lib/"
else
    fail "milestone_block_unavailable trip found: $found"
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
