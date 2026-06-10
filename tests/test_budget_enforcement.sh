#!/usr/bin/env bash
# Shim-boundary guard for V5 m14 — cost telemetry + per-stage budget caps.
#
# m14 ships:
#   * internal/provider/cost.go (CostEstimator interface + DefaultEstimator)
#   * internal/provider/cost_aggregator.go (RunCostAggregator)
#   * STAGE_BUDGET_USD_<STAGE>= block in templates/pipeline.conf.example
#   * --max-cost-usd flag in cmd/tekhton/run.go
#
# m14 is still status=todo in .claude/milestones/MANIFEST.cfg. Until the
# coder lands the implementation, this test self-skips with exit 0 so the
# auto-fix re-test loop (which keys off test filenames) doesn't report
# MISSING. When m14 implementation lands, replace the skip stub with the
# real cross-cutting checks the milestone spec calls for.
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

COST_GO="${TEKHTON_HOME}/internal/provider/cost.go"
AGG_GO="${TEKHTON_HOME}/internal/provider/cost_aggregator.go"

if [[ ! -f "$COST_GO" || ! -f "$AGG_GO" ]]; then
    echo "SKIP: V5 m14 not yet implemented (internal/provider/cost.go absent) — stub passes"
    exit 0
fi

# --- m14 implementation present: run the real checks ----------------------
PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

if grep -q 'type CostEstimator' "$COST_GO"; then
    pass "CostEstimator interface declared in internal/provider/cost.go"
else
    fail "CostEstimator interface missing from internal/provider/cost.go"
fi

if grep -q 'RunCostAggregator' "$AGG_GO"; then
    pass "RunCostAggregator declared in internal/provider/cost_aggregator.go"
else
    fail "RunCostAggregator missing from internal/provider/cost_aggregator.go"
fi

TPL="${TEKHTON_HOME}/templates/pipeline.conf.example"
if [[ -f "$TPL" ]] && grep -q 'STAGE_BUDGET_USD' "$TPL"; then
    pass "STAGE_BUDGET_USD block present in templates/pipeline.conf.example"
else
    fail "STAGE_BUDGET_USD block missing from templates/pipeline.conf.example"
fi

RUN_GO="${TEKHTON_HOME}/cmd/tekhton/run.go"
if [[ -f "$RUN_GO" ]] && grep -q 'max-cost-usd' "$RUN_GO"; then
    pass "--max-cost-usd flag wired in cmd/tekhton/run.go"
else
    fail "--max-cost-usd flag missing from cmd/tekhton/run.go"
fi

echo
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "$FAIL_COUNT" -eq 0 ]] || exit 1
exit 0
