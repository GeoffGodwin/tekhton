#!/usr/bin/env bash
# =============================================================================
# tests/test_budget_enforcement.sh — m14 budget deliverables shim-boundary test
#
# Tests (operator-facing artifacts that don't require Go compilation):
#   A1. internal/provider/cost.go exists with CostEstimator interface
#   A2. internal/provider/cost_aggregator.go exists with RunCostAggregator
#   A3. internal/provider/costrates.json exists and is valid JSON with
#       required keys (claude:api, codex:api, codex:subscription, claude:subscription)
#   A4. cmd/tekhton/forecast.go exists
#   A5. docs/v5-cost-banner-example.md exists
#   B1. templates/pipeline.conf.example has STAGE_BUDGET_USD_CODER
#   B2. templates/pipeline.conf.example has RUN_BUDGET_USD
#   B3. lib/init_config_sections.sh emits STAGE_BUDGET_USD section
#   C1. internal/finalize/emit_run_summary.go contains Cost Summary section
#   C2. cmd/tekhton/run.go has --max-cost-usd flag
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAIL=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# =============================================================================
# Section A — Core implementation files must exist
# =============================================================================

# A1: cost.go with CostEstimator interface
if [ -f "${TEKHTON_HOME}/internal/provider/cost.go" ]; then
    if grep -q "CostEstimator" "${TEKHTON_HOME}/internal/provider/cost.go"; then
        pass "A1: cost.go exists and declares CostEstimator"
    else
        fail "A1: cost.go exists but is missing CostEstimator interface"
    fi
else
    fail "A1: internal/provider/cost.go does not exist (m14 core deliverable absent)"
fi

# A2: cost_aggregator.go with RunCostAggregator
if [ -f "${TEKHTON_HOME}/internal/provider/cost_aggregator.go" ]; then
    if grep -q "RunCostAggregator" "${TEKHTON_HOME}/internal/provider/cost_aggregator.go"; then
        pass "A2: cost_aggregator.go exists and declares RunCostAggregator"
    else
        fail "A2: cost_aggregator.go exists but is missing RunCostAggregator"
    fi
else
    fail "A2: internal/provider/cost_aggregator.go does not exist (m14 core deliverable absent)"
fi

# A3: costrates.json is valid JSON with required keys
if [ -f "${TEKHTON_HOME}/internal/provider/costrates.json" ]; then
    if ! python3 -c "import json,sys; d=json.load(open(sys.argv[1])); [d[k] for k in ['claude:api','codex:api','codex:subscription','claude:subscription']]" \
        "${TEKHTON_HOME}/internal/provider/costrates.json" 2>/dev/null; then
        fail "A3: costrates.json exists but is missing required tier keys or is invalid JSON"
    else
        pass "A3: costrates.json valid with all four required tier keys"
    fi
else
    fail "A3: internal/provider/costrates.json does not exist (m14 core deliverable absent)"
fi

# A4: forecast.go
if [ -f "${TEKHTON_HOME}/cmd/tekhton/forecast.go" ]; then
    pass "A4: cmd/tekhton/forecast.go exists"
else
    fail "A4: cmd/tekhton/forecast.go does not exist (--forecast subcommand absent)"
fi

# A5: docs/v5-cost-banner-example.md
if [ -f "${TEKHTON_HOME}/docs/v5-cost-banner-example.md" ]; then
    pass "A5: docs/v5-cost-banner-example.md exists"
else
    fail "A5: docs/v5-cost-banner-example.md does not exist (dogfood doc absent)"
fi

# =============================================================================
# Section B — Operator-facing config (pipeline.conf.example + init)
# =============================================================================

CONF_EXAMPLE="${TEKHTON_HOME}/templates/pipeline.conf.example"

# B1: STAGE_BUDGET_USD_CODER in pipeline.conf.example
if [ -f "$CONF_EXAMPLE" ]; then
    if grep -q "STAGE_BUDGET_USD_CODER" "$CONF_EXAMPLE"; then
        pass "B1: pipeline.conf.example has STAGE_BUDGET_USD_CODER"
    else
        fail "B1: pipeline.conf.example missing STAGE_BUDGET_USD_CODER (m14 budget block absent)"
    fi

    # B2: RUN_BUDGET_USD in pipeline.conf.example
    if grep -q "RUN_BUDGET_USD" "$CONF_EXAMPLE"; then
        pass "B2: pipeline.conf.example has RUN_BUDGET_USD"
    else
        fail "B2: pipeline.conf.example missing RUN_BUDGET_USD (m14 run cap absent)"
    fi
else
    fail "B1: templates/pipeline.conf.example not found"
    fail "B2: templates/pipeline.conf.example not found"
fi

# B3: lib/init_config_sections.sh emits STAGE_BUDGET_USD
INIT_CFG="${TEKHTON_HOME}/lib/init_config_sections.sh"
if [ -f "$INIT_CFG" ]; then
    if grep -q "STAGE_BUDGET_USD" "$INIT_CFG"; then
        pass "B3: lib/init_config_sections.sh emits STAGE_BUDGET_USD section"
    else
        fail "B3: lib/init_config_sections.sh missing STAGE_BUDGET_USD (tekhton --init won't emit budget section)"
    fi
else
    fail "B3: lib/init_config_sections.sh not found"
fi

# =============================================================================
# Section C — RUN_SUMMARY cost banner + CLI flag
# =============================================================================

# C1: emit_run_summary.go has Cost Summary section
EMIT_SUMMARY="${TEKHTON_HOME}/internal/finalize/emit_run_summary.go"
if [ -f "$EMIT_SUMMARY" ]; then
    if grep -q "Cost Summary" "$EMIT_SUMMARY"; then
        pass "C1: emit_run_summary.go contains Cost Summary section"
    else
        fail "C1: emit_run_summary.go missing Cost Summary (m14 RUN_SUMMARY banner not implemented)"
    fi
else
    fail "C1: internal/finalize/emit_run_summary.go not found"
fi

# C2: cmd/tekhton/run.go has --max-cost-usd flag
RUN_GO="${TEKHTON_HOME}/cmd/tekhton/run.go"
if [ -f "$RUN_GO" ]; then
    if grep -q "max-cost-usd" "$RUN_GO"; then
        pass "C2: cmd/tekhton/run.go has --max-cost-usd flag"
    else
        fail "C2: cmd/tekhton/run.go missing --max-cost-usd flag (m14 CLI override absent)"
    fi
else
    fail "C2: cmd/tekhton/run.go not found"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "All budget enforcement checks passed."
    exit 0
else
    echo "Budget enforcement checks FAILED — see above."
    exit 1
fi
