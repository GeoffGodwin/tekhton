<!-- milestone-meta
id: "14"
status: "todo"
-->

# m14 (V5) — Cost Telemetry + RUN_SUMMARY Cost Banner + Per-Stage Budget Caps

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1, Milestone 14 — closes the cost-effectiveness story for V5 Phase 1. m13 added `Tier()` visibility and `Result.TierUsed` provenance, so operators can see WHICH tier each stage ran on. m14 adds the dollar amount: per-tier cost estimation, RUN_SUMMARY cost banner, per-stage budget caps with hard-stop enforcement, and a pre-run cost forecast. With Anthropic's June 15 2026 change tripling-to-15xing every Claude call's cost, operators need three concrete defenses: (1) see actual cost incurred per run, (2) cap per-stage spend so a runaway agent can't blow the budget, (3) forecast cost before kicking off a milestone so they can decide whether to use a cheaper provider or skip the run. m14 ships all three. After m14, V5 Phase 1 is feature-complete: polyglot working, cost-aware by default, operator has full visibility and budget controls. |
| **Gap** | At m13 close, `Result.TierUsed` tells operators which tier ran but no code translates that into dollars. `OutcomeResult.TokenUsage` from m08 (Codex) and the Claude supervisor's equivalent token counting are captured but not aggregated into a cost figure. There's no per-stage cost ceiling — a coder agent stuck in a 200-turn loop on Claude API tier can rack up $20+ in tokens with no early termination. There's no pre-run forecast — operators kick off a milestone hopefully without knowing whether it will cost $0.10 or $10. The pipeline.conf has provider knobs but no budget knobs. m14 closes every gap. |
| **m14 fills** | (1) `internal/provider/cost.go` — per-tier cost estimator types: `CostEstimator` interface with `EstimateCost(*Result) (USDCents int64)`, default implementations for Claude API (~$3/$15 per 1M input/output tokens at 2026-06 rates), Codex API (~$2/$8 per 1M input/output at 2026-06 rates), Codex subscription (returns 0 within quota), local (returns 0). Estimators load rates from a `costrates.json` config (overridable). (2) `internal/provider/cost_aggregator.go` — `RunCostAggregator` accumulates per-stage costs across a pipeline run. Exposes `TotalCents() int64`, `PerStageCents() map[string]int64`, `PerTierCents() map[string]int64`. (3) `pipeline.conf` extension — `STAGE_BUDGET_USD_<STAGE>=` per-stage caps (e.g., `STAGE_BUDGET_USD_CODER=5.00`). When a stage's estimated cost would exceed the cap, the pipeline halts before the next agent call with `ErrorSubcategory = "BUDGET_EXCEEDED"`. Plus a global `RUN_BUDGET_USD=` cap for the whole run. (4) `RUN_SUMMARY.md` extension — new cost banner section showing per-stage cost (tier, tokens, dollars), per-tier breakdown, and total. Subscription-tier stages show "(subscription)" with $0 cost; paid tiers show actual estimates. (5) Pre-run cost forecast — `tekhton --milestone X --forecast` prints estimated cost based on prior similar runs (from causal log history) without invoking any agents. Operators see "Last 5 m04-size runs averaged $1.20 on Claude API tier" before deciding. (6) `--max-cost-usd` CLI flag — single-run budget override. (7) Tests + a dogfood capture in `docs/v5-cost-banner-example.md`. |
| **Depends on** | m13 (needs `Tier()` and `Result.TierUsed` to attribute cost to a tier) |
| **Files changed** | `internal/provider/cost.go` (~180 LOC), `internal/provider/cost_aggregator.go` (~140 LOC), `internal/provider/costrates.json` (rates fixture, ~50 lines), `internal/runner/runner.go` (modify — pre-stage budget check + aggregator wiring, ~60 LOC delta), `internal/finalize/emit_run_summary.go` (modify — cost banner section, ~70 LOC delta), `cmd/tekhton/run.go` (modify — `--forecast` and `--max-cost-usd` flags, ~80 LOC delta), `cmd/tekhton/forecast.go` (new — forecast subcommand body, ~140 LOC), `lib/init_config_sections.sh` (modify — emit STAGE_BUDGET_USD section), `templates/pipeline.conf.example` (modify), `internal/provider/cost_test.go` (~200 LOC), `internal/runner/budget_test.go` (~180 LOC), `tests/test_budget_enforcement.sh` (new shim-boundary test, ~120 LOC), `docs/v5-cost-banner-example.md` (~60 LOC), `VERSION` |

---

## Design

### Sequencing note

m14 lands AFTER m13 — needs `Tier()` to attribute cost per provider.
m14 is also the V5 Phase 1 closer; everything after is Phase 2 work
(local Qwen, parallel execution, cross-provider quality benchmarks).

### Goal 1 — Cost estimator

**File:** `internal/provider/cost.go`.

```go
package provider

// CostEstimator returns the estimated cost in USD cents for a
// provider Result. Implementations consult per-tier rates and the
// Result's token usage.
type CostEstimator interface {
    EstimateCents(res *Result, providerName, tier string) int64
}

// DefaultEstimator loads rates from costrates.json (or the embedded
// default) and applies them based on Result.TierUsed.
type DefaultEstimator struct {
    rates map[string]TierRates  // key: "<provider>:<tier>"
}

type TierRates struct {
    InputCentsPer1M  int64  // Input tokens — cents per 1 million
    OutputCentsPer1M int64  // Output tokens — cents per 1 million
}

func (e *DefaultEstimator) EstimateCents(res *Result, providerName, tier string) int64 {
    if tier == TierSubscription || tier == TierLocal {
        return 0  // Free within quota OR free, period.
    }
    key := providerName + ":" + tier
    rates, ok := e.rates[key]
    if !ok {
        return 0  // Unknown rate — refuse to guess.
    }
    inputTokens, outputTokens := extractTokensFromResult(res)
    cents := (inputTokens*rates.InputCentsPer1M + outputTokens*rates.OutputCentsPer1M) / 1_000_000
    return cents
}
```

**Default rates** (as of 2026-06; loaded from `costrates.json`):

```json
{
  "claude:api": {
    "input_cents_per_1m": 300,
    "output_cents_per_1m": 1500,
    "_note": "Claude 4.6 Sonnet base rate per 1M tokens; ~15x prior subscription cost"
  },
  "codex:api": {
    "input_cents_per_1m": 200,
    "output_cents_per_1m": 800,
    "_note": "OpenAI o4-mini equivalent; check OpenAI pricing page for latest"
  },
  "codex:subscription": {
    "input_cents_per_1m": 0,
    "output_cents_per_1m": 0,
    "_note": "ChatGPT Plus/Pro/Team subscription — free within quota window"
  },
  "claude:subscription": {
    "input_cents_per_1m": 0,
    "output_cents_per_1m": 0,
    "_note": "Pre-June-15 path OR future hypothetical Anthropic subscription return"
  }
}
```

The rates file is config-overridable via `TEKHTON_COST_RATES_FILE`
env. Operators on enterprise/discounted pricing can drop in a custom
file.

### Goal 2 — Aggregator

**File:** `internal/provider/cost_aggregator.go`.

Accumulates per-stage results into a `RunCostAggregator`. Used by the
runner to enforce budgets and by the finalize chain to emit the cost
banner.

```go
type RunCostAggregator struct {
    Estimator     CostEstimator
    PerStage      map[string]int64  // stage → cents
    PerTier       map[string]int64  // tier → cents
    PerProvider   map[string]int64  // provider name → cents
    TotalCents    int64
}

func (a *RunCostAggregator) Record(stage string, res *Result) {
    cents := a.Estimator.EstimateCents(res, ?, res.TierUsed)
    a.PerStage[stage] += cents
    a.PerTier[res.TierUsed] += cents
    a.PerProvider[?] += cents
    a.TotalCents += cents
}

func (a *RunCostAggregator) WouldExceedStageBudget(stage string, projectedCents int64, capCents int64) bool {
    return a.PerStage[stage] + projectedCents > capCents
}
```

### Goal 3 — Pipeline.conf budget caps

**File:** `templates/pipeline.conf.example`.

```bash
# === Per-Stage Budget Caps (V5 m14) =========================================
#
# Hard-stop spending limits per stage. Once a stage's cumulative paid-tier
# cost would exceed the cap (e.g., the next coder turn projected at $0.30
# would push past the $5 stage cap), the pipeline halts with
# ErrorSubcategory=BUDGET_EXCEEDED. Subscription-tier and local-tier costs
# are $0 and don't count toward caps.
#
# Set to 0 to disable a cap. Set RUN_BUDGET_USD to cap the whole run.
#
# Examples:
#   STAGE_BUDGET_USD_CODER=5.00       # Coder stage capped at $5/run
#   STAGE_BUDGET_USD_REVIEWER=1.00    # Reviewer capped at $1/run
#   RUN_BUDGET_USD=10.00              # Whole run capped at $10
#
# Default: all caps disabled. Operators on subscription-tier providers
# typically don't need caps; operators on api-tier should set them
# explicitly per their tolerance.

STAGE_BUDGET_USD_INTAKE=0
STAGE_BUDGET_USD_CODER=0
STAGE_BUDGET_USD_SECURITY=0
STAGE_BUDGET_USD_REVIEW=0
STAGE_BUDGET_USD_TESTER=0
STAGE_BUDGET_USD_ARCHITECT=0
STAGE_BUDGET_USD_DOCS=0
STAGE_BUDGET_USD_CLEANUP=0
RUN_BUDGET_USD=0
```

### Goal 4 — Runner budget enforcement

**File:** `internal/runner/runner.go`.

Before each stage agent invocation, the runner checks the aggregator:

```go
// In the stage dispatch path:
stageCap := getStageBudgetCents(stage)
runCap := getRunBudgetCents()

if stageCap > 0 || runCap > 0 {
    projected := projectStageCost(stage, req)  // heuristic from prior turn averages
    if stageCap > 0 && r.CostAggregator.WouldExceedStageBudget(stage, projected, stageCap) {
        return failResult("BUDGET_EXCEEDED", fmt.Sprintf(
            "stage %s budget $%.2f would be exceeded (currently $%.2f, projected +$%.2f)",
            stage,
            float64(stageCap)/100,
            float64(r.CostAggregator.PerStage[stage])/100,
            float64(projected)/100))
    }
    if runCap > 0 && r.CostAggregator.TotalCents + projected > runCap {
        return failResult("BUDGET_EXCEEDED", "run budget would be exceeded")
    }
}

// ... invoke agent
// After result:
r.CostAggregator.Record(stage, res)
```

### Goal 5 — RUN_SUMMARY cost banner

**File:** `internal/finalize/emit_run_summary.go`.

New section in the rendered RUN_SUMMARY.md:

```markdown
## Cost Summary

| Stage    | Provider | Tier         | Tokens (in/out)  | Cost (USD) |
|----------|----------|--------------|------------------|------------|
| intake   | codex    | subscription | 8K / 2K          | (free)     |
| coder    | codex    | subscription | 84K / 12K        | (free)     |
| security | codex    | subscription | 4K / 1K          | (free)     |
| review   | codex    | subscription | 22K / 3K         | (free)     |
| tester   | claude   | api          | 18K / 6K         | $0.36      |
|----------|----------|--------------|------------------|------------|
| TOTAL    |          |              | 136K / 24K       | $0.36      |

Per-tier breakdown: subscription $0.00, api $0.36
```

Operators who fall through to paid tiers see exactly which stage cost
what.

### Goal 6 — Pre-run forecast

**File:** `cmd/tekhton/forecast.go`.

`tekhton --milestone X --forecast` consults the causal log's history
for prior similar-shaped milestones, computes mean+stddev cost, and
prints a forecast without invoking any agents:

```
$ tekhton --milestone m08 --forecast

Forecast for m08 (V5 Codex JSON Event Decoder):
  Based on 4 prior m07-shape runs (interface widening, multiple test files):
    Mean cost: $0.42
    Stddev:    $0.18
    Range:     $0.12 - $0.71
  Provider chain (cost-ranked): codex, claude
  Estimated tier mix:
    codex:subscription      85% chance ($0 cost)
    claude:api              15% chance (~$0.40 cost)

To run: tekhton --milestone m08 --auto-advance --auto-advance-limit 1
To run with strict cost cap: tekhton --milestone m08 --max-cost-usd 1.00
```

### Goal 7 — `--max-cost-usd` flag

Single-run override of `RUN_BUDGET_USD`. Takes precedence over
pipeline.conf when set.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/provider/cost.go` | Create | `CostEstimator` interface + `DefaultEstimator` + rate loading. ~180 LOC. |
| `internal/provider/cost_aggregator.go` | Create | Per-stage / per-tier / per-provider accumulator. ~140 LOC. |
| `internal/provider/costrates.json` | Create | Default rate table. ~50 lines. |
| `internal/runner/runner.go` | Modify | Pre-stage budget check + aggregator wiring. ~60 LOC. |
| `internal/finalize/emit_run_summary.go` | Modify | Cost banner section. ~70 LOC. |
| `cmd/tekhton/run.go` | Modify | `--max-cost-usd` flag + plumbing. ~40 LOC. |
| `cmd/tekhton/forecast.go` | Create | `--forecast` subcommand body. ~140 LOC. |
| `lib/init_config_sections.sh` | Modify | Emit STAGE_BUDGET_USD section. |
| `templates/pipeline.conf.example` | Modify | Budget block. |
| `internal/provider/cost_test.go` | Create | Estimator + rate-loading tests. ~200 LOC. |
| `internal/runner/budget_test.go` | Create | Budget enforcement tests with stub providers. ~180 LOC. |
| `tests/test_budget_enforcement.sh` | Create | Shim-boundary integration test. ~120 LOC. |
| `docs/v5-cost-banner-example.md` | Create | Example RUN_SUMMARY with cost banner. ~60 LOC. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] `DefaultEstimator.EstimateCents` returns 0 for `Result.TierUsed = "subscription"` or `"local"`. Verified.
- [ ] `DefaultEstimator.EstimateCents` returns >0 for `Result.TierUsed = "api"` with non-zero token usage. Verified.
- [ ] `costrates.json` parses cleanly and contains entries for `claude:api`, `codex:api`, `codex:subscription`, `claude:subscription`. Verified.
- [ ] `TEKHTON_COST_RATES_FILE=<path>` env override loads custom rates. Verified.
- [ ] `RunCostAggregator.Record` increments per-stage, per-tier, per-provider AND total. Verified.
- [ ] `WouldExceedStageBudget` returns true when projected cost would push past the cap. Verified.
- [ ] Runner halts a stage with `ErrorSubcategory = "BUDGET_EXCEEDED"` when the per-stage budget would be exceeded. Verified by `TestRunner_StageBudgetEnforced`.
- [ ] Runner halts a run with `ErrorSubcategory = "BUDGET_EXCEEDED"` when the total run budget would be exceeded. Verified.
- [ ] Subscription-tier and local-tier stages do NOT count toward budget caps (cost = $0). Verified.
- [ ] RUN_SUMMARY.md contains a `## Cost Summary` section with per-stage rows, per-tier totals, and grand total. Verified by snapshot test.
- [ ] Paid-tier rows in the cost banner are visually distinguished (e.g., asterisks or color) from free-tier rows. Verified.
- [ ] `tekhton --forecast` prints mean/stddev/range from prior runs in the causal log AND does NOT invoke any agents. Verified by `TestForecast_NoAgentCalls`.
- [ ] `--max-cost-usd <X>` overrides `RUN_BUDGET_USD` for the single run. Verified.
- [ ] `pipeline.conf.example` contains the `STAGE_BUDGET_USD_<STAGE>=` block + `RUN_BUDGET_USD=`. Verified.
- [ ] `tekhton --init` emits the new section into freshly-created pipeline.conf files. Verified.
- [ ] `tests/test_budget_enforcement.sh` drives a run that hits a budget cap and asserts BUDGET_EXCEEDED. Verified.
- [ ] `docs/v5-cost-banner-example.md` shows a realistic RUN_SUMMARY with the cost banner. Verified.
- [ ] No regression in m07-m13 tests.
- [ ] `golangci-lint run` and `go vet` clean.
- [ ] Full suite passes.

## Watch For

- **The rate table is approximate, NOT authoritative.** Cost
  estimates are within ±15% of actual. Operators should treat the
  banner as a tracking tool, not a billing audit. The `_note` field
  in `costrates.json` documents the source for each rate.
- **Caps are projected-cost based, not exact-cost-after.** A stage
  about to invoke its 7th turn projects "based on first 6 turns'
  avg token usage, this turn will cost ~$0.25." If actual usage
  spikes, the stage can overshoot the cap by one turn before the
  next check catches it. Document this in `docs/v5-tier-model.md`.
- **The aggregator is per-run, not persistent.** It resets at run
  start. Daily/weekly cumulative caps are a future enhancement —
  out of m14 scope.
- **`--forecast` reads the causal log.** If the operator is running
  Tekhton for the first time on a fresh project, the log is empty
  and the forecast prints "no prior runs — cannot forecast." That's
  acceptable; the feature exists for repeated-shape work.
- **The `_note` field in costrates.json is for humans.** The Go
  loader ignores `_note` keys. Don't try to parse them. Their
  purpose is documenting the rate source for operators reading
  the file.
- **Subscription quota tracking is OUT OF SCOPE.** Codex's
  `RateLimitSnapshot` carries quota window info but tracking
  "you've used 73% of your weekly ChatGPT quota" is a separate
  feature. m14 records cost = $0 for subscription tier; quota
  exhaustion is detected by m11's retry logic falling through
  to api tier (where m14 starts counting cost).
- **Budget caps interact with chain fallthrough.** If a stage
  on Codex (subscription, $0) succeeds, no cost is added.
  If Codex fails with QUOTA and falls through to Claude (api),
  the projected Claude cost gets checked against the cap BEFORE
  the Claude invocation. Operators see "stage halted before
  spending $4 on Claude API."

## Seeds Forward

- **Per-day / per-week cumulative caps.** A persistent ledger
  tracking spend across runs would let operators set "$50/day max
  on Tekhton." Out of m14 scope; the per-run aggregator is the
  building block.
- **Cost-aware milestone scheduling.** The forecast feature could
  feed a scheduler that auto-defers milestones likely to overspend
  until quota resets. Out of MVP.
- **Provider rate auto-discovery.** Codex's token_count events
  contain enough data to compute the actual per-call rate by
  comparing successive runs. A future arc could self-calibrate
  the rate table. Out of m14 scope.
- **Cost telemetry export.** Per-stage cost data could be exported
  to Prometheus/Grafana for org-wide observability. Out of MVP.
- **Pre-run cost dialog.** A future enhancement could prompt the
  operator before each run: "This milestone is forecast to cost
  $X. Continue?". Interactive opt-in for high-cost runs. Out of
  m14 scope.
- **V5 Phase 2 — Local Qwen.** Once `internal/provider/qwen/`
  ships with `Tier() = TierLocal`, the cost aggregator records $0
  for every local stage. The forecast feature becomes more
  accurate (more historical $0 runs to mean-stddev across).
- **V5 Phase 2 — Cost-aware fallback policy.** Today's chain falls
  through on UpstreamError. A future policy could fall through on
  "projected cost on next provider is significantly higher" — e.g.,
  prefer to retry the cheap provider rather than fall to the
  expensive one for transient failures. Tracked as Seeds.
