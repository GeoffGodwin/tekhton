<!-- milestone-meta
id: "12"
status: "todo"
-->

# m12 (V5) — Per-Stage Provider Selection + Fallback Chain + End-to-End Codex Dogfood

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1, Milestone 12 — wires Codex into the pipeline via per-stage provider selection + cost-ranked fallback chain + end-to-end dogfood. m07-m11 ship a fully-functional Codex provider with parity to Claude on all the seam-defined surfaces. m12 makes it *usable* in production. **Cost framing (post-June-15 reality)**: Anthropic's June 15 2026 change forces `claude --print` to API-metered pricing regardless of Max subscription tier — a ~15x cost increase per call. Codex with ChatGPT subscription is the ONLY subscription/free-quota route Tekhton has in V5 Phase 1 (local models land in Phase 2). The chain default is therefore **explicitly cost-ranked**: Codex (subscription tier) FIRST, Claude (api tier) as the paid fallback the operator opts into. Per-stage provider selection via `pipeline.conf` (PROVIDER=, PROVIDER_<STAGE>=) plus the chain's UpstreamError fallthrough means a Codex quota exhaustion routes to Claude with operator awareness. After m12, an operator can `PROVIDER=codex` and have the full pipeline run on subscription-tier Codex with no surprise paid Claude calls. The fallback to Claude requires explicit opt-in via chain config OR exhaustion of the Codex tier — never silent. m12 also captures the operator-facing documentation. Note: full cross-provider Tier() visibility lands in m13; m12 implements the cost-ranked default chain using m11's internal tier reporting via OutcomeResult metadata. |
| **Gap** | At m11 close, the Codex provider is feature-complete but nothing instantiates it. The runner constructs `claude.New()` unconditionally as its single Provider (m02). `pipeline.conf` has no `PROVIDER=` key. Stages don't know how to consume a Provider other than the default. There's no fallback chain — a Provider returning `OutcomeUpstreamError` propagates the failure to the pipeline-level retry without consulting alternatives. And critically: no operator-facing dogfood evidence proves Codex works end-to-end. m12 wires every piece: pipeline.conf gains a `PROVIDER=` per-stage key (`PROVIDER_intake=`, `PROVIDER_coder=`, etc.) AND a global `PROVIDER=` default. The runner consults config, constructs the right provider per stage, falls back through a comma-separated chain on UpstreamError. A new shim-boundary test executes a fixture milestone on Codex and asserts the full envelope round-trip. Documentation in `docs/v5-polyglot.md` explains the operator workflow. |
| **m12 fills** | (1) `lib/init_config_sections.sh` + `pipeline.conf.example` — adds `PROVIDER=claude` global default plus optional `PROVIDER_<STAGE>=` overrides. (2) `internal/runner/provider_select.go` — `ResolveProvider(stage string) provider.Provider` consulting env (loaded from pipeline.conf), constructing the right provider via factory functions. (3) `internal/runner/provider_chain.go` — `Chain` wrapping multiple providers; `(*Chain).RunAgent` calls them in order, falling through to the next on `OutcomeUpstreamError` per attempt. Honors the `RetryableSubcategories` set from m11. (4) `internal/runner/runner.go` modification — stage dispatch path consults `ResolveProvider(stage)` and injects per-stage. The single `r.Provider` field becomes per-stage configurable. (5) `cmd/tekhton/run.go` modification — new `--provider <name>` flag override (single-shot, overrides pipeline.conf) and `--provider-chain <list>` for explicit chain specification. (6) `docs/v5-polyglot.md` — operator-facing guide: pipeline.conf shape, environment setup (CODEX_API_KEY, OAuth login, Claude key), troubleshooting. (7) Tests: per-stage selection test, chain fallback test, AND a shim-boundary integration test (`tests/test_v5_codex_dogfood.sh`) that drives a fixture milestone through Codex. (8) Dogfood evidence: run a real milestone on Codex; commit the run log under `docs/v5-codex-dogfood-evidence.md`. |
| **Depends on** | m07-m11 (the full Codex provider) |
| **Files changed** | `internal/runner/provider_select.go` (~150 LOC), `internal/runner/provider_chain.go` (~140 LOC), `internal/runner/runner.go` (modify — ~50 LOC delta), `cmd/tekhton/run.go` (modify — ~40 LOC delta for new flags), `lib/init_config_sections.sh` (modify — add PROVIDER section), `templates/pipeline.conf.example` (modify), `docs/v5-polyglot.md` (create, ~200 LOC), `docs/v5-codex-dogfood-evidence.md` (create, dogfood run log), `internal/runner/provider_select_test.go` (~180 LOC), `internal/runner/provider_chain_test.go` (~200 LOC), `tests/test_v5_codex_dogfood.sh` (~150 LOC), `VERSION` |

---

## Design

### Sequencing note

m12 is the V5 Phase 1 closer. After m12, the user has a polyglot
pipeline. m13+ work (Qwen local provider, parallel execution engine,
cost-aware routing) lands in V5 Phase 2 once Phase 1 is dogfooded.

### Goal 1 — pipeline.conf configuration

**File:** `templates/pipeline.conf.example`.

Add a new section:

```bash
# === Provider Selection (V5 m12) ============================================
#
# Tekhton supports multiple LLM provider backends. V5 ships with two:
#   claude — Anthropic Claude CLI (legacy default)
#   codex  — OpenAI Codex CLI (V5 polyglot path)
#
# PROVIDER sets the default provider chain for every stage. Individual
# stages can override via PROVIDER_<STAGE>= (snake_case stage name).
#
# Cost framing (post-Anthropic June 15 2026 change):
#   - codex with ChatGPT subscription = FREE within quota (preferred)
#   - codex with API key             = paid per-token
#   - claude (any auth)              = paid per-token (API-metered)
#
# The default chain "codex,claude" exhausts the free Codex subscription
# tier FIRST, then falls back to paid Claude only when Codex returns
# UpstreamError (quota exhausted, network, server overload, etc.).
# Fallthrough does NOT happen for non-retryable errors (auth, context
# overflow, policy) — those return the original failure.
#
# Examples:
#   PROVIDER=codex,claude        # DEFAULT — cost-ranked (subscription → paid fallback)
#   PROVIDER=codex               # Codex only — fail rather than fall to paid
#   PROVIDER=claude              # All stages on paid Claude (operator opt-in)
#   PROVIDER_coder=codex,claude  # Per-stage chain
#
# Override with --provider <chain> or --provider-chain <list> at CLI
# for one-off runs.
#
# Use --require-tier subscription to FAIL rather than fall through to
# paid tiers when subscription quota exhausts. Operator opt-in for
# strict cost control.
PROVIDER=codex,claude

# Per-stage overrides (uncomment to enable):
# PROVIDER_intake=
# PROVIDER_coder=
# PROVIDER_security=
# PROVIDER_review=
# PROVIDER_tester=
# PROVIDER_architect=
# PROVIDER_docs=
# PROVIDER_cleanup=
```

`lib/init_config_sections.sh` gains a corresponding section-emitter so
`tekhton --init` writes these defaults into freshly-created pipeline.conf
files.

### Goal 2 — `ResolveProvider`

**File:** `internal/runner/provider_select.go`.

```go
package runner

import (
    "fmt"
    "os"
    "strings"

    "github.com/geoffgodwin/tekhton/internal/provider"
    "github.com/geoffgodwin/tekhton/internal/provider/claude"
    "github.com/geoffgodwin/tekhton/internal/provider/codex"
)

// ResolveProvider determines which provider implementation should run
// for the given stage. Consults pipeline.conf via env (PROVIDER and
// PROVIDER_<STAGE>= keys). When the resolved value is a comma-list,
// returns a Chain wrapping the providers in order.
func ResolveProvider(stage string) (provider.Provider, error) {
    // Per-stage override takes precedence.
    envKey := "PROVIDER_" + strings.ToUpper(stage)
    spec := os.Getenv(envKey)
    if spec == "" {
        spec = os.Getenv("PROVIDER")
    }
    if spec == "" {
        spec = "claude"  // Last-resort default.
    }

    names := splitCSV(spec)
    if len(names) == 0 {
        return nil, fmt.Errorf("provider: empty spec for stage %q", stage)
    }

    providers := make([]provider.Provider, 0, len(names))
    for _, name := range names {
        p, err := constructProvider(name)
        if err != nil {
            return nil, fmt.Errorf("provider: %w", err)
        }
        providers = append(providers, p)
    }

    if len(providers) == 1 {
        return providers[0], nil
    }
    return NewChain(providers), nil
}

func constructProvider(name string) (provider.Provider, error) {
    switch strings.ToLower(strings.TrimSpace(name)) {
    case "claude", "":
        return claude.New(), nil
    case "codex":
        return codex.New()
    // Future: case "qwen": return qwen.New()
    default:
        return nil, fmt.Errorf("unknown provider %q", name)
    }
}

func splitCSV(s string) []string {
    parts := strings.Split(s, ",")
    out := parts[:0]
    for _, p := range parts {
        p = strings.TrimSpace(p)
        if p != "" {
            out = append(out, p)
        }
    }
    return out
}
```

### Goal 3 — `Chain` fallback

**File:** `internal/runner/provider_chain.go`.

```go
package runner

import (
    "context"
    "errors"
    "fmt"

    "github.com/geoffgodwin/tekhton/internal/provider"
)

// Chain wraps multiple providers. RunAgent tries each in order; if
// the result is UpstreamError with a retryable subcategory, falls
// through to the next provider. Non-retryable failures return
// immediately (no point trying the next provider for an
// AUTH/CONTEXT_OVERFLOW/POLICY failure that would persist regardless
// of backend).
type Chain struct {
    Providers []provider.Provider
}

func NewChain(providers []provider.Provider) *Chain {
    return &Chain{Providers: providers}
}

func (c *Chain) Name() string {
    names := make([]string, 0, len(c.Providers))
    for _, p := range c.Providers {
        names = append(names, p.Name())
    }
    return "chain[" + strings.Join(names, ",") + "]"
}

// Subcategories that should fall through to the next provider.
// Mirrors the m11 retry policy intent: backend-specific transient
// failures should hedge; backend-independent failures should fail
// fast.
var fallthroughSubcategories = map[string]bool{
    "QUOTA":      true,
    "OVERLOADED": true,
    "NETWORK":    true,
    "STREAM":     true,
    "SERVER_5XX": true,
    // RETRY_EXHAUSTED intentionally omitted: if Provider A exhausted
    // retries, Provider B will likely exhaust them too. Fall through
    // only for fast-failure categories.
}

func (c *Chain) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
    if len(c.Providers) == 0 {
        return nil, errors.New("provider chain: empty chain")
    }
    var lastResult *provider.Result
    var lastErr error
    for i, p := range c.Providers {
        res, err := p.RunAgent(ctx, req)
        if err != nil {
            // Process-level error — try next provider.
            lastErr = err
            continue
        }
        lastResult = res
        if res.Outcome == provider.OutcomeSuccess {
            return res, nil
        }
        if !fallthroughSubcategories[res.ErrorSubcategory] {
            // Non-retryable — return as-is (don't try next provider).
            return res, nil
        }
        if i == len(c.Providers)-1 {
            return res, nil  // Last provider; return whatever we got.
        }
        // Try next provider.
    }
    if lastResult != nil {
        return lastResult, nil
    }
    return nil, fmt.Errorf("provider chain: all providers failed: %w", lastErr)
}
```

### Goal 4 — Runner integration

`internal/runner/runner.go` updates: the dispatch path consults
`ResolveProvider(stage)` per stage instead of using `r.Provider`
globally. The `Runner.Provider` field becomes a `map[string]provider.Provider`
populated lazily as stages are dispatched.

`cmd/tekhton/run.go` gains two flags:
- `--provider <name>`: single-shot override of `PROVIDER` for this run
- `--provider-chain <list>`: comma-separated chain override

### Goal 5 — Documentation

**File:** `docs/v5-polyglot.md` (~200 LOC).

Operator-facing guide:
- Overview of the provider seam (link to `docs/v5-provider-seam.md`)
- pipeline.conf `PROVIDER` syntax
- Per-stage overrides + fallback chains
- Setting up Codex (CODEX_API_KEY, `codex login`, ~/.codex/auth.json)
- Setting up Claude (Claude CLI install, auth)
- Troubleshooting common errors (auth fail → which provider's error?)
- Cost considerations (cloud vs cloud comparison)
- Migration path: switching a single stage to Codex without disrupting the rest

### Goal 6 — Dogfood

**File:** `tests/test_v5_codex_dogfood.sh` (~150 LOC).

Shim-boundary integration test:
1. Set up a fixture milestone (small, deterministic — e.g., add a comment to one Go file).
2. Set `PROVIDER=codex` in env.
3. Run `tekhton --milestone <fixture>`.
4. Assert: the milestone completes with success disposition, the manifest flips done, and the commit has the expected change.

Self-skips when the Codex binary isn't installed (so contributors without Codex don't break CI).

**File:** `docs/v5-codex-dogfood-evidence.md` (~80 LOC).

Captured run log from a real Codex dogfood run on a small milestone.
Includes:
- The pipeline.conf used
- The milestone file content
- The captured RUN_SUMMARY.json
- The final commit subject + first few lines of body
- Total cost (token usage from Codex)
- Comparison notes (Claude-equivalent run, where available)

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/runner/provider_select.go` | Create | `ResolveProvider` consulting env. ~150 LOC. |
| `internal/runner/provider_chain.go` | Create | `Chain` with fallthrough policy. ~140 LOC. |
| `internal/runner/runner.go` | Modify | Per-stage provider resolution. ~50 LOC. |
| `cmd/tekhton/run.go` | Modify | `--provider` / `--provider-chain` flags. ~40 LOC. |
| `lib/init_config_sections.sh` | Modify | Emit PROVIDER section. |
| `templates/pipeline.conf.example` | Modify | Provider config block. |
| `docs/v5-polyglot.md` | Create | Operator guide. ~200 LOC. |
| `docs/v5-codex-dogfood-evidence.md` | Create | Dogfood run log. ~80 LOC. |
| `internal/runner/provider_select_test.go` | Create | Per-stage selection table. ~180 LOC. |
| `internal/runner/provider_chain_test.go` | Create | Fallback chain tests with stub providers. ~200 LOC. |
| `tests/test_v5_codex_dogfood.sh` | Create | Shim-boundary integration test. ~150 LOC. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] `ResolveProvider("coder")` returns a `claude.Provider` when `PROVIDER=claude` is in env. Verified.
- [ ] `ResolveProvider("coder")` returns a `codex.Provider` when `PROVIDER=codex`. Verified.
- [ ] `ResolveProvider("coder")` returns a `*Chain` wrapping codex+claude when `PROVIDER=codex,claude`. Verified.
- [ ] `PROVIDER_CODER=codex` takes precedence over `PROVIDER=claude` for the coder stage. Verified.
- [ ] Other stages still use the global `PROVIDER=claude` when the per-stage override isn't set. Verified.
- [ ] `Chain.RunAgent` tries providers in order and returns the first success. Verified by `TestChain_FirstSucceeds`.
- [ ] `Chain.RunAgent` falls through to provider 2 when provider 1 returns `OutcomeUpstreamError / QUOTA`. Verified by `TestChain_FallsThroughOnQuota`.
- [ ] `Chain.RunAgent` does NOT fall through for non-retryable subcategories (AUTH, CONTEXT_OVERFLOW). Verified by `TestChain_DoesNotFallThroughOnAuth`.
- [ ] `Chain.Name()` returns `"chain[codex,claude]"` for a two-provider chain. Verified.
- [ ] The `--provider <name>` CLI flag overrides `PROVIDER` env for the single run. Verified.
- [ ] The `--provider-chain <list>` flag overrides with an explicit chain. Verified.
- [ ] `pipeline.conf.example` contains the `PROVIDER` and `PROVIDER_<STAGE>=` block. Verified.
- [ ] `tekhton --init` emits the new section into freshly-created `pipeline.conf` files. Verified.
- [ ] `docs/v5-polyglot.md` exists, documents `PROVIDER` syntax, fallback chains, and per-provider auth setup. Verified by `grep -nE '^## ' docs/v5-polyglot.md` returning at least 5 sections.
- [ ] `docs/v5-codex-dogfood-evidence.md` exists with a captured RUN_SUMMARY from a real Codex run. Verified manually.
- [ ] `tests/test_v5_codex_dogfood.sh` passes when Codex is installed; self-skips when not. Verified.
- [ ] No regression in m07-m11 tests, m01-m06 V5 phase 1 tests, or any pre-V5 reliability tests.
- [ ] `golangci-lint run` and `go vet` clean.
- [ ] Full suite passes.

## Watch For

- **The chain's fallthrough subcategory set is DIFFERENT from m11's
  retry set.** m11 retries the same provider (transient flakes
  recover); m12 falls through to a DIFFERENT provider (provider-
  specific failures hedge). The sets overlap but aren't identical:
  m12 doesn't fall through `RETRY_EXHAUSTED` because if Provider A
  exhausted retries, Provider B might just exhaust them too — fall
  through only for fast-failure categories.
- **Don't construct providers eagerly.** `ResolveProvider` is called
  per stage. Build the provider on demand. Caching can come later if
  profiling shows it matters; premature caching adds complexity.
- **Env var capitalization matters.** `PROVIDER_coder` vs
  `PROVIDER_CODER`. The bash side (pipeline.conf) typically uses
  uppercase; the Go side must match. Use `strings.ToUpper(stage)`
  consistently.
- **Codex MUST be installed on the dogfood machine.** The dogfood
  evidence document records a real run. If the CI machine doesn't
  have Codex, the test skip path takes over — but the evidence
  document must come from an actual successful run on a machine
  where the CLI is available.
- **Fallback can mask single-provider bugs.** If Codex is buggy AND
  the chain falls through to Claude, the operator never sees the
  Codex failure. Surface it loudly: every fallthrough should log a
  warning so operators know "we used the fallback for this stage."
  Add a `Result.FallthroughCount` field tracking how many providers
  in the chain were tried (m12 surfaces this on the Result envelope).
- **Don't drop `RawProviderData` in the chain path.** When Provider B
  succeeds after Provider A failed, the returned Result carries B's
  data — but A's failure is useful for postmortem. A future enhancement
  could surface a `FallbackHistory []Result` field; m12's MVP just
  logs A's failure to stderr and returns B's success cleanly.

## Seeds Forward

- **m13+ — Local Qwen provider** (V5 Phase 2). The
  `constructProvider` switch gains a `"qwen"` case. The local
  agent loop wraps a `Complete`-style interface (different from
  Claude/Codex's `RunAgent`-style). Adds the `Provider` interface's
  second method (m01 D1 design's "Hybrid" path actually consumed).
- **Cost-aware routing** (V5 Phase 2). The chain could route by
  cost budget: Claude for hard milestones, Codex for medium,
  local Qwen for grunt. Requires cost telemetry per provider —
  m08 captures `TokenUsageInfo`, m11 captures rate limits;
  building on this for cost-aware fallback is straightforward.
- **Parallel execution engine** (V5 Phase 2). The provider
  abstraction makes parallel multi-stage execution per provider
  practical — different milestones running on different providers
  simultaneously. m12's chain pattern extends to a parallel-pool
  pattern: one provider per parallel slot.
- **Cross-provider parity benchmarks.** A future arc could capture
  per-stage performance metrics across providers (time, cost,
  quality verdicts) to inform routing decisions. Out of MVP scope;
  the telemetry seams are positioned.
- **Provider-specific stage rendering hints.** Different providers
  may have different prompt-rendering preferences (Codex prefers
  shorter, more directive prompts than Claude). A future arc could
  expose per-provider prompt variants via the prompt template
  engine.
