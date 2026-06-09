<!-- milestone-meta
id: "13"
status: "todo"
-->

# m13 (V5) — Provider.Tier() Interface + Claude Tier Handling + Cost-Ranked Chain Default

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1, Milestone 13 — adds cross-provider cost-tier visibility as a first-class concept. m07-m12 build the Codex provider and per-stage selection, with m11's auth resolution privately tracking "subscription" vs "api" tier and m12's pipeline.conf comment recommending cost-ranked chain ordering. m13 promotes tier to the public interface: `provider.Provider` gains a `Tier()` method; the Claude provider implements it (returning "api" because Anthropic's June 15 2026 change makes ALL `claude --print` calls API-metered regardless of Max subscription); the Codex provider returns the tier its m11 auth resolution captured; the `Chain` in m12 consults `Tier()` for default ordering so an operator who specifies `PROVIDER=codex,claude` gets exactly the cost-ranked behavior they expect. m13 also adds `Result.TierUsed` so RUN_SUMMARY can surface which tier the run actually ran on — visibility being the operator's only defense against silent paid-tier consumption. |
| **Gap** | At m12 close, the Codex provider knows its tier internally (m11) but the `provider.Provider` interface has only `Name()` and `RunAgent()`. Stages, the runner, and the chain treat all providers as opaque. There's no way to: (1) reject a chain that includes paid tiers when the operator wants subscription-only, (2) display which tier ran in RUN_SUMMARY, (3) compute cost estimates per tier in telemetry. Additionally, the Claude provider has no awareness of Anthropic's June 15 change — it doesn't report a tier and operators have no way to see "this claude --print call costs ~15x your old subscription quota." m13 closes both gaps. |
| **m13 fills** | (1) `internal/provider/provider.go` — adds `Tier() string` method to the `Provider` interface. Defined values: `"subscription"`, `"api"`, `"local"`, `"unknown"`. (2) `internal/provider/claude/claude.go` — implements `Tier()` returning `"api"` (post-June-15 reality: every `claude --print` is API-metered). Plus a config knob `ClaudePreJune15Override` (env `TEKHTON_CLAUDE_PRE_JUNE_15=true`) that returns `"subscription"` for operators running pre-June-15 OR with grandfathered access — defensive seam for whatever Anthropic's final state turns out to be. (3) `internal/provider/codex/codex.go` — implements `Tier()` consulting the auth resolution from m11. Caches the result on the Provider struct after first resolution. (4) `internal/runner/provider_chain.go` — `Chain.RunAgent` records the tier of the provider that succeeded into `Result.TierUsed`. Default chain construction (when operator specifies `PROVIDER=A,B,C`) sorts by `Tier()` if `--cost-rank-chain` is set (default true). (5) `cmd/tekhton/run.go` — `--require-tier <tier>` flag that fails the run rather than fall through to a more expensive tier. (6) `internal/proto/result.go` — adds `TierUsed string` field to `provider.Result`. (7) RUN_SUMMARY emitter updates to surface `tier_used` per stage. (8) Tests + a one-page `docs/v5-tier-model.md` documenting the tier semantics. |
| **Depends on** | m11, m12 |
| **Files changed** | `internal/provider/provider.go` (modify — add Tier() to interface, ~15 LOC), `internal/provider/claude/claude.go` (modify — implement Tier() + override env, ~40 LOC), `internal/provider/codex/codex.go` (modify — implement Tier() consulting auth, ~30 LOC), `internal/runner/provider_chain.go` (modify — Tier-aware sorting + TierUsed recording, ~60 LOC), `cmd/tekhton/run.go` (modify — --require-tier flag, ~30 LOC), `internal/proto/result.go` (modify — add TierUsed field, ~5 LOC), `internal/finalize/emit_run_summary.go` (modify — surface tier_used, ~25 LOC), `internal/provider/provider_test.go` (modify — Tier() contract tests), `internal/provider/claude/claude_test.go` (modify — Tier() test + env-override test), `internal/provider/codex/codex_test.go` (modify — Tier() test), `internal/runner/provider_chain_test.go` (modify — cost-ranked sort + TierUsed assertion), `docs/v5-tier-model.md` (create, ~100 LOC), `VERSION` |

---

## Design

### Sequencing note

m13 lands AFTER m12 because it depends on the chain logic m12 introduces.
The interface widening is non-breaking (adds a method to an interface
defined in m01 with two implementations; both implementations adopt the
new method in m13).

### Core principle

> Every Provider declares its cost tier. Tekhton uses tier to default
> chain ordering, surface cost provenance in RUN_SUMMARY, and let
> operators forbid paid-tier usage. Tier is NOT a soft hint — it's
> the contract the chain consults to decide whether falling through
> is allowed.

### Goal 1 — Widen the Provider interface

**File:** `internal/provider/provider.go`.

```go
type Provider interface {
    Name() string
    Tier() string  // m13 — see TierXxx constants below
    RunAgent(ctx context.Context, req *Request) (*Result, error)
}

// Tier values. The chain consults these to order providers and gate
// fallthrough via --require-tier.
const (
    TierSubscription = "subscription"  // Free within quota (ChatGPT Plus/Pro/Team, future Claude Pro tier, etc.)
    TierAPI          = "api"           // Paid per-token (Anthropic API, OpenAI API key)
    TierLocal        = "local"         // Free, no quota (local llama.cpp / vLLM — V5 Phase 2)
    TierUnknown      = "unknown"       // Provider cannot determine its tier
)

// TierCostRank returns an integer ordering: smaller is cheaper.
// local (0) < subscription (1) < api (2) < unknown (3).
// Used by Chain to sort providers when --cost-rank-chain is set.
func TierCostRank(tier string) int {
    switch tier {
    case TierLocal:
        return 0
    case TierSubscription:
        return 1
    case TierAPI:
        return 2
    default:
        return 3
    }
}
```

### Goal 2 — Claude provider Tier

**File:** `internal/provider/claude/claude.go`.

Post-June-15 reality: every `claude --print` invocation goes through
API-metered billing regardless of Max subscription. The provider
returns `TierAPI` by default. An env override exists for the operator
who is verifiably pre-June-15 OR has confirmed grandfathered access.

```go
// Tier returns the cost tier of this Claude provider invocation.
//
// Post-2026-06-15: Anthropic switched `claude --print` to API-metered
// pricing regardless of Max subscription. Every invocation costs at
// API rates (~15x prior subscription cost). Tier returns "api".
//
// Operators who are verifiably pre-June-15 OR have grandfathered
// subscription access can set TEKHTON_CLAUDE_PRE_JUNE_15=true to
// override. This is intentionally an env, not a config file knob,
// to keep it explicit + per-environment.
func (p *Provider) Tier() string {
    if os.Getenv("TEKHTON_CLAUDE_PRE_JUNE_15") == "true" {
        return provider.TierSubscription
    }
    return provider.TierAPI
}
```

### Goal 3 — Codex provider Tier

**File:** `internal/provider/codex/codex.go`.

Cached on the Provider struct so the auth-file stat doesn't repeat per
invocation. Computed at the first `RunAgent` call via the m11 auth
resolution.

```go
type Provider struct {
    BinaryPath string
    cachedTier string  // m13 — set on first RunAgent after resolveAuth completes
}

func (p *Provider) Tier() string {
    if p.cachedTier != "" {
        return p.cachedTier
    }
    // First-call discovery (no request context — heuristic).
    if authPath := storedAuthPath(); fileExists(authPath) {
        return provider.TierSubscription
    }
    if os.Getenv("CODEX_API_KEY") != "" {
        return provider.TierAPI
    }
    return provider.TierUnknown
}
```

### Goal 4 — Chain tier consultation

**File:** `internal/runner/provider_chain.go`.

```go
// RunAgent in the Chain records the tier of the successful provider
// into Result.TierUsed. Operators see this in RUN_SUMMARY.
func (c *Chain) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
    // ... existing fall-through loop
    if res.Outcome == provider.OutcomeSuccess {
        res.TierUsed = p.Tier()  // m13 — record provenance
        return res, nil
    }
    // ... etc.
}

// SortByCostRank reorders providers in the chain by Tier() ascending
// (cheaper first). Operators who specify PROVIDER=claude,codex get
// re-ordered to codex,claude unless --no-cost-rank-chain is set.
func (c *Chain) SortByCostRank() {
    sort.SliceStable(c.Providers, func(i, j int) bool {
        return provider.TierCostRank(c.Providers[i].Tier()) <
               provider.TierCostRank(c.Providers[j].Tier())
    })
}
```

### Goal 5 — `--require-tier` flag

**File:** `cmd/tekhton/run.go`.

```go
var requireTier string
cmd.Flags().StringVar(&requireTier, "require-tier", "",
    "Fail the run rather than use a provider above this tier. "+
    "Values: subscription | api | local. Default: no requirement.")

// In the Runner construction path:
if requireTier != "" {
    runnerOpts = append(runnerOpts, runner.WithRequiredTier(requireTier))
}
```

The runner's chain construction rejects providers whose `Tier()` is
costlier than the required tier (uses `TierCostRank`). The chain's
fallthrough loop respects this too — a fall to a costlier tier than
required is treated as a hard failure with `ErrorSubcategory =
"TIER_LIMIT_EXCEEDED"`.

### Goal 6 — `Result.TierUsed` + RUN_SUMMARY

**File:** `internal/proto/result.go`.

```go
type Result struct {
    // ... existing fields
    TierUsed string  // m13 — set by Chain when a provider succeeds. One of TierXxx constants.
}
```

**File:** `internal/finalize/emit_run_summary.go`.

The per-stage summary section gains a `tier_used` row:

```
| Stage    | Provider | Tier         | Turns | Duration |
|----------|----------|--------------|-------|----------|
| intake   | codex    | subscription | 1     | 12s      |
| coder    | codex    | subscription | 6     | 4m17s    |
| review   | codex    | subscription | 1     | 28s      |
| tester   | claude   | api          | 1     | 1m02s    |  ← paid call
```

Paid-tier rows get a visual highlight in the operator-facing banner.

### Goal 7 — Documentation

**File:** `docs/v5-tier-model.md` (~100 LOC).

Documents:
- The four tier values + their cost semantics.
- The June 15 2026 Anthropic change and Tekhton's response.
- How to operate in subscription-only mode (`--require-tier subscription`).
- How to read RUN_SUMMARY's tier column.
- The `TEKHTON_CLAUDE_PRE_JUNE_15` escape hatch.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/provider/provider.go` | Modify | Add `Tier()` to interface + `TierXxx` constants + `TierCostRank`. |
| `internal/provider/claude/claude.go` | Modify | Implement `Tier()` returning `api` (or `subscription` with env override). |
| `internal/provider/codex/codex.go` | Modify | Implement `Tier()` consulting auth resolution + cache. |
| `internal/runner/provider_chain.go` | Modify | `SortByCostRank` + `Result.TierUsed` recording. |
| `cmd/tekhton/run.go` | Modify | `--require-tier` flag + plumbing. |
| `internal/proto/result.go` | Modify | Add `TierUsed string`. |
| `internal/finalize/emit_run_summary.go` | Modify | Surface per-stage tier in summary table. |
| `internal/provider/provider_test.go` | Modify | Interface contract test + TierCostRank table. |
| `internal/provider/claude/claude_test.go` | Modify | Tier() default + env override tests. |
| `internal/provider/codex/codex_test.go` | Modify | Tier() per auth state. |
| `internal/runner/provider_chain_test.go` | Modify | SortByCostRank + TierUsed + --require-tier rejection. |
| `docs/v5-tier-model.md` | Create | Operator-facing tier guide. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] `provider.Provider` interface has three methods: `Name()`, `Tier()`, `RunAgent()`. Verified by `reflect.TypeOf((*provider.Provider)(nil)).Elem().NumMethod() == 3`.
- [ ] Constants `TierSubscription`, `TierAPI`, `TierLocal`, `TierUnknown` exist with the expected string values. Verified by go doc.
- [ ] `TierCostRank` returns 0/1/2/3 for local/subscription/api/unknown respectively. Verified by table-driven test.
- [ ] `claude.Provider.Tier()` returns `"api"` by default. Verified.
- [ ] `claude.Provider.Tier()` returns `"subscription"` when `TEKHTON_CLAUDE_PRE_JUNE_15=true`. Verified.
- [ ] `codex.Provider.Tier()` returns `"subscription"` when `~/.codex/auth.json` exists. Verified.
- [ ] `codex.Provider.Tier()` returns `"api"` when only `CODEX_API_KEY` is set. Verified.
- [ ] `codex.Provider.Tier()` returns `"unknown"` when neither auth source is available. Verified.
- [ ] `Chain.SortByCostRank()` reorders `[Claude, Codex(subscription)]` to `[Codex(subscription), Claude]`. Verified.
- [ ] `Chain.RunAgent` populates `Result.TierUsed` with the tier of the provider that succeeded. Verified.
- [ ] `tekhton run --require-tier subscription` rejects a chain containing an api-tier provider with `ErrorSubcategory = "TIER_LIMIT_EXCEEDED"`. Verified by integration test.
- [ ] RUN_SUMMARY emits a `tier_used` field per stage. Verified by snapshot test against a fixture run.
- [ ] `docs/v5-tier-model.md` exists, documents the four tiers + June 15 framing + `--require-tier` usage + pre-June-15 override. Verified by section-heading grep.
- [ ] No regression in m01-m12 tests (m01's interface widening is non-breaking — Claude provider already in tree, Codex provider is new in m07).
- [ ] `golangci-lint run` and `go vet` clean.
- [ ] Full suite passes.

## Watch For

- **The interface widening is non-breaking.** Adding `Tier() string`
  to an interface requires every implementation to add the method.
  Two implementations exist (Claude, Codex); both are updated in m13.
  Future provider stubs (test fakes) MUST also implement `Tier()` —
  watch for compile errors in older test files.
- **The pre-June-15 override is an env, NOT a config file knob.**
  Per-environment override means dev machines can opt in without
  affecting production CI. Don't promote it to pipeline.conf.
- **`--require-tier` rejects at chain CONSTRUCTION, not at fallthrough.**
  An operator who runs `--require-tier subscription` with a chain
  containing `claude` fails at runner-construction time, not after
  Codex has already exhausted its tier. Fail fast.
- **`TierUsed` carries cost provenance.** Operators rely on this for
  cost auditing. Never set it to anything other than the tier the
  successful provider reported. If Codex (subscription) fell
  through and Claude (api) succeeded, `TierUsed = "api"`.
- **The Claude provider's `Tier()` is a moving target.** Anthropic may
  reintroduce a subscription path or change pricing again. The
  `TEKHTON_CLAUDE_PRE_JUNE_15` env override is the operator's hook
  for any future "this build has subscription access" scenario. Don't
  bake the post-June-15 reality into the provider's hardcoded default
  if Anthropic later reverses course — a future provider revision
  may need to consult its own runtime auth check (similar to Codex's
  `~/.codex/auth.json` heuristic).
- **The local tier (TierLocal) is reserved for V5 Phase 2.** No
  current provider returns it. Don't preemptively wire local-provider
  factories — that's m15+ work.

## Seeds Forward

- **m14 — Cost telemetry + budget caps.** Consumes `Result.TierUsed`
  + `Result.TokenUsage` (from m08) to compute estimated cost per
  stage. RUN_SUMMARY gains a cost column. Pipeline.conf gains
  `STAGE_BUDGET_USD_<STAGE>=` caps with hard-stop enforcement.
- **V5 Phase 2 — Local Qwen.** When `internal/provider/qwen/`
  ships, its `Tier()` returns `TierLocal` (0 cost rank). The chain
  default becomes `qwen,codex,claude` — local first, subscription
  second, paid last.
- **Subscription quota observability.** Codex's `RateLimitSnapshot`
  carries window/remaining data — a future arc could surface
  "subscription quota remaining: 87%" in the dashboard. Out of m13
  scope; the data is captured by m08.
- **Per-provider cost models.** Each provider could declare a cost
  estimator (`CostPerInputToken`, `CostPerOutputToken`) that m14's
  telemetry consumes. Codex API tier prices come from OpenAI;
  Claude API prices come from Anthropic. Out of m13 scope; the
  Tier() seam supports it.
