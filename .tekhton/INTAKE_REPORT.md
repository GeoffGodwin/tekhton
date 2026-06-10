## Verdict
TWEAKED

## Confidence
88

## Reasoning
- Scope is exceptionally well-defined: 4 CREATE + 4 MODIFY + VERSION, with a hard scope boundary, explicit out-of-scope list, and a coder verification command
- Acceptance criteria are concrete and grep-verifiable
- Design section provides actual Go code stubs — minimal ambiguity about intended implementation
- Watch For section proactively surfaces the key risks (TEKHTON_REQUIRE_TIER wiring, missed r.Provider call sites, default ordering)
- **One rubric gap:** The milestone adds multiple user-facing config keys (PROVIDER, PROVIDER_<STAGE>=, TEKHTON_REQUIRE_TIER) but has no "Migration impact" section. The rubric requires one. More importantly, the default behavior change is non-trivial: today runner.go hardcodes `claude.New()`; after m15, any operator who hasn't set PROVIDER will silently get `codex,claude` as their chain — Codex first. This is a breaking behavior change for existing deployments and deserves explicit documentation in the milestone.

## Tweaked Content
<!-- milestone-meta
id: "15"
status: "todo"
-->

# m15 (V5) — Wire Chain to Runner + CLI Flags + Operator Documentation

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1, Milestone 15 — closes the operator-facing gaps left by m12 and m13. Both milestones shipped their Go-side type/interface work cleanly (Chain, SortByCostRank, Tier() on the Provider interface, provider implementations of Tier()) but skipped the integration plumbing: the runner still constructs `claude.New()` unconditionally, no CLI flags for provider/chain/tier overrides exist, `pipeline.conf.example` has no PROVIDER block, `lib/init_config_sections.sh` doesn't emit a PROVIDER section for `tekhton --init`, and the operator-facing docs (`docs/v5-polyglot.md`, `docs/v5-tier-model.md`) were never created. The result: the Chain is dead code in production, instantiated only by tests. Even when m14 ships, an operator literally can't use Codex without editing Go code. m15 wires every gap. After m15, the operator can set `PROVIDER=codex,claude` in pipeline.conf, run `tekhton --milestone X`, and have the cost-ranked chain actually dispatch. |
| **Gap** | At m13 close (commit 198731d), `internal/runner/provider_chain.go::Chain` exists with `NewChain`, `RunAgent`, `SortByCostRank` — but the only caller is `internal/runner/provider_chain_test.go`. `internal/runner/runner.go:149` still hardcodes `Provider: claude.New(supervisor.New(nil, nil))`. There's no `ResolveProvider` function reading the env. There's no `--provider` / `--provider-chain` / `--require-tier` CLI flag. `templates/pipeline.conf.example` is unmodified — no PROVIDER block. `lib/init_config_sections.sh` doesn't emit a PROVIDER section. `docs/v5-polyglot.md` (~200 LOC of operator guidance promised by m12) doesn't exist. `docs/v5-tier-model.md` (~100 LOC tier semantics promised by m13) doesn't exist. m15 covers exactly these gaps — no Go-side type/interface changes (those are done), pure integration + operator-facing surface. |
| **m15 fills** | (1) `internal/runner/provider_select.go` — `ResolveProvider(stage string) (provider.Provider, error)` reads env (`PROVIDER`, `PROVIDER_<STAGE>=`, optional `PROVIDER_CHAIN`) and constructs either a single provider or a `Chain` via the existing `NewChain` from m12. Plus `constructProvider(name string) (provider.Provider, error)` factory dispatching to `claude.New()` / `codex.New()`. (2) `internal/runner/runner.go` modification — per-stage provider dispatch path replaces the single hardcoded `Provider` field. Stage dispatch calls `ResolveProvider(stage)` per invocation. (3) `cmd/tekhton/run.go` modifications — three new flags: `--provider <name>` (single-shot, overrides `PROVIDER` env for this run), `--provider-chain <list>` (comma-separated chain override), `--require-tier <tier>` (fail rather than fall through to a costlier tier per the m13 design). (4) `templates/pipeline.conf.example` modification — adds the PROVIDER block with cost-framing comments per the m12 design (the comments themselves are already drafted in `.claude/milestones/m12-codex-provider-selection-dogfood.md`'s Goal 1 section — copy verbatim). (5) `lib/init_config_sections.sh` modification — adds a PROVIDER section emitter so `tekhton --init` writes the defaults into freshly-created pipeline.conf. (6) `docs/v5-polyglot.md` (~200 LOC, NEW) — operator-facing guide. Sections: Overview, pipeline.conf syntax, Per-stage overrides + fallback chains, Setting up Codex auth (CODEX_API_KEY, `codex login`, `~/.codex/auth.json`), Setting up Claude post-June-15, Troubleshooting (auth fail → which provider?), Cost considerations, Migration path. (7) `docs/v5-tier-model.md` (~100 LOC, NEW) — tier semantics doc. Sections: The four tier values, June 15 framing + Tekhton response, How `--require-tier subscription` works, How to read RUN_SUMMARY's tier column, The `TEKHTON_CLAUDE_PRE_JUNE_15` escape hatch. (8) Tests: `provider_select_test.go` for ResolveProvider + chain construction, runner test for the per-stage dispatch path. |
| **Depends on** | m12, m13 (the type/interface work that m15 wires up) |
| **Files changed** | `internal/runner/provider_select.go` (~150 LOC, CREATE), `internal/runner/provider_select_test.go` (~180 LOC, CREATE), `internal/runner/runner.go` (~50 LOC modify), `cmd/tekhton/run.go` (~50 LOC modify), `templates/pipeline.conf.example` (~30 LOC append), `lib/init_config_sections.sh` (~25 LOC modify), `docs/v5-polyglot.md` (~200 LOC, CREATE), `docs/v5-tier-model.md` (~100 LOC, CREATE), `VERSION` |

---

## Migration Impact

[PM: Added — rubric requires this section when user-facing config is introduced, and the default behavior change warrants explicit documentation.]

**Existing operators (no PROVIDER set in pipeline.conf):** Before m15, the runner unconditionally used Claude. After m15, any run where `PROVIDER` is unset will default to `"codex,claude"` — Codex is tried first, Claude is the fallback. This is intentional (cost-ranked, cheapest-first) but is a **silent breaking change** for operators who rely on the implicit Claude-only default and have not configured `PROVIDER`.

**Required action for operators who want Claude-only behavior:**
Add `PROVIDER=claude` to their `pipeline.conf`. The coder MUST add a clear callout about this default change to `docs/v5-polyglot.md`'s "Migration path" section — not just a mention, but a bolded callout that the old implicit default is now `codex,claude`.

**New config keys introduced:**
- `PROVIDER` — global provider spec (single name or comma-separated chain)
- `PROVIDER_<STAGE>=` — per-stage override (e.g. `PROVIDER_CODER=claude`)
- `TEKHTON_REQUIRE_TIER` — fail-fast tier guard (set by `--require-tier` flag)

No existing config keys are renamed or removed. Operators who don't set any of the above will see Codex attempted first on every stage dispatch starting with this release.

---

## Design

### Sequencing note

m15 lands AFTER m12 + m13. The work is purely additive plumbing — no
existing Go types/interfaces change. The Chain, Tier(), and provider
implementations from m12/m13 stay exactly as they are. m15 wires them
to operator-facing surfaces.

### HARD SCOPE BOUNDARY (m15 ONLY)

**The coder MUST create or modify exactly these files. Creating any
file outside this list FAILS m15. The previous m12 and m13 attempts
SKIPPED these deliverables — the boundary below is the fix.**

CREATE (4 files):
1. `internal/runner/provider_select.go` — `ResolveProvider` + `constructProvider`
2. `internal/runner/provider_select_test.go` — table-driven tests for ResolveProvider
3. `docs/v5-polyglot.md` — operator-facing polyglot guide
4. `docs/v5-tier-model.md` — tier semantics doc

MODIFY (4 files):
5. `internal/runner/runner.go` — per-stage provider dispatch via ResolveProvider
6. `cmd/tekhton/run.go` — add `--provider`, `--provider-chain`, `--require-tier` flags
7. `templates/pipeline.conf.example` — PROVIDER block
8. `lib/init_config_sections.sh` — PROVIDER section emitter

PLUS `VERSION` bump.

**Verification command for the coder before reporting COMPLETE:**

```
test -f internal/runner/provider_select.go && \
test -f docs/v5-polyglot.md && \
test -f docs/v5-tier-model.md && \
grep -q 'func ResolveProvider' internal/runner/provider_select.go && \
grep -q 'PROVIDER=' templates/pipeline.conf.example && \
grep -q -- '--provider' cmd/tekhton/run.go && \
grep -q -- '--require-tier' cmd/tekhton/run.go && \
echo "m15 deliverables present"
```

If this echoes "m15 deliverables present", the coder MAY mark
COMPLETE. Otherwise INCOMPLETE + Drift Observation surfacing the gap.

**DO NOT create/modify in m15** — these are out-of-scope:
- `internal/provider/codex/*` — the Codex provider is done (m07-m11)
- `internal/provider/claude/*` — the Claude Tier() landed in m13
- `internal/provider/provider.go` — the Tier() interface landed in m13
- `internal/runner/provider_chain.go` — m12's Chain is done
- Any cost-related files (`internal/provider/cost.go`, etc.) — m14's scope
- Any test under `tests/test_*.sh` — none required for m15

### Goal 1 — `ResolveProvider`

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
    "github.com/geoffgodwin/tekhton/internal/supervisor"
)

// ResolveProvider returns the Provider that should run for the given
// stage. Reads env (PROVIDER and PROVIDER_<STAGE>=) for the spec.
// Comma-list spec yields a Chain via NewChain.
func ResolveProvider(stage string) (provider.Provider, error) {
    envKey := "PROVIDER_" + strings.ToUpper(stage)
    spec := os.Getenv(envKey)
    if spec == "" {
        spec = os.Getenv("PROVIDER")
    }
    if spec == "" {
        spec = "codex,claude"  // m12-default — cost-ranked
    }
    names := splitCSV(spec)
    if len(names) == 0 {
        return nil, fmt.Errorf("provider: empty spec for stage %q", stage)
    }
    providers := make([]provider.Provider, 0, len(names))
    for _, name := range names {
        p, err := constructProvider(name)
        if err != nil {
            return nil, err
        }
        providers = append(providers, p)
    }
    if len(providers) == 1 {
        return providers[0], nil
    }
    return NewChain(providers...), nil
}

func constructProvider(name string) (provider.Provider, error) {
    switch strings.ToLower(strings.TrimSpace(name)) {
    case "claude":
        return claude.New(supervisor.New(nil, nil)), nil
    case "codex":
        return codex.New()
    default:
        return nil, fmt.Errorf("unknown provider %q", name)
    }
}

func splitCSV(s string) []string {
    parts := strings.Split(s, ",")
    out := parts[:0]
    for _, p := range parts {
        if p = strings.TrimSpace(p); p != "" {
            out = append(out, p)
        }
    }
    return out
}
```

### Goal 2 — Runner integration

**File:** `internal/runner/runner.go`.

Replace the hardcoded `Provider:` field (line 149 area) with a
per-stage dispatch:

```go
// Per-stage provider resolution. Each stage calls ResolveProvider
// at dispatch time so per-stage overrides via PROVIDER_<STAGE>= take
// effect. Cache resolutions on the runner to avoid repeated env reads.
type Runner struct {
    // ... existing fields
    providerCache map[string]provider.Provider  // stage → resolved provider
}

func (r *Runner) providerForStage(stage string) (provider.Provider, error) {
    if r.providerCache == nil {
        r.providerCache = make(map[string]provider.Provider)
    }
    if p, ok := r.providerCache[stage]; ok {
        return p, nil
    }
    p, err := ResolveProvider(stage)
    if err != nil {
        return nil, err
    }
    r.providerCache[stage] = p
    return p, nil
}
```

Call sites that previously used `r.Provider` (the single Provider
field) switch to `r.providerForStage(currentStage)`.

### Goal 3 — CLI flags

**File:** `cmd/tekhton/run.go`.

```go
var (
    providerOverride      string
    providerChainOverride string
    requireTier           string
)
cmd.Flags().StringVar(&providerOverride, "provider", "",
    "Override PROVIDER env for this run (single provider name)")
cmd.Flags().StringVar(&providerChainOverride, "provider-chain", "",
    "Override PROVIDER env with an explicit chain (comma-separated)")
cmd.Flags().StringVar(&requireTier, "require-tier", "",
    "Fail rather than fall through to a costlier tier "+
    "(subscription | api | local)")

// In the RunE body:
if providerOverride != "" {
    os.Setenv("PROVIDER", providerOverride)
}
if providerChainOverride != "" {
    os.Setenv("PROVIDER", providerChainOverride)
}
if requireTier != "" {
    os.Setenv("TEKHTON_REQUIRE_TIER", requireTier)
}
```

The `TEKHTON_REQUIRE_TIER` env is consulted by the Chain at construction
time (m13's `Chain.RunAgent` already references this — verify the wiring
works).

### Goal 4 — pipeline.conf.example

**File:** `templates/pipeline.conf.example`.

Append the PROVIDER block from m12's design (Goal 1, verbatim — already
drafted there). Reproduced for completeness:

```bash
# === Provider Selection (V5 m12) ============================================
# (full block from m12's Goal 1 — copy verbatim)
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

### Goal 5 — `lib/init_config_sections.sh`

Add an `_emit_provider_section` function that writes the PROVIDER block
into the rendered `pipeline.conf` during `tekhton --init`. Mirrors the
existing emitter pattern for other sections.

### Goal 6 — `docs/v5-polyglot.md`

Operator-facing guide (~200 LOC). Section list:

1. **Overview** — links to `docs/v5-provider-seam.md`.
2. **pipeline.conf syntax** — `PROVIDER`, `PROVIDER_<STAGE>=`, comma lists.
3. **Per-stage overrides + fallback chains** — when to use which.
4. **Setting up Codex auth** — three paths: `codex login` for OAuth (subscription, free within quota); `CODEX_API_KEY` env (paid API); `ProviderSpecific["codex.api_key"]` per-run override.
5. **Setting up Claude post-June-15** — `claude --print` API-metered; `TEKHTON_CLAUDE_PRE_JUNE_15=true` escape hatch.
6. **Troubleshooting** — auth fail signals, tier confusion, `--require-tier` not behaving as expected.
7. **Cost considerations** — subscription preferred, API last resort.
8. **Migration path** — switching a single stage to Codex without disrupting the rest. [PM: This section MUST include a bolded callout that upgrading to m15 changes the implicit default from Claude-only to `codex,claude`. Operators who want Claude-only must add `PROVIDER=claude` to pipeline.conf explicitly.]

### Goal 7 — `docs/v5-tier-model.md`

Tier semantics doc (~100 LOC). Section list:

1. **The four tier values** (`subscription`, `api`, `local`, `unknown`) — what each means.
2. **June 15 2026 framing** — why `claude --print` is api tier now.
3. **How `--require-tier subscription` works** — fail-fast rather than silent paid fall-through.
4. **How to read RUN_SUMMARY's tier column** — provenance.
5. **The `TEKHTON_CLAUDE_PRE_JUNE_15` escape hatch** — when to use it.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/runner/provider_select.go` | Create | `ResolveProvider`, `constructProvider`, `splitCSV`. ~150 LOC. |
| `internal/runner/provider_select_test.go` | Create | Table-driven tests for ResolveProvider per env state. ~180 LOC. |
| `internal/runner/runner.go` | Modify | Per-stage provider dispatch via `providerForStage`. |
| `cmd/tekhton/run.go` | Modify | `--provider`, `--provider-chain`, `--require-tier` flags + plumbing. |
| `templates/pipeline.conf.example` | Modify | Append PROVIDER block. |
| `lib/init_config_sections.sh` | Modify | Add `_emit_provider_section`. |
| `docs/v5-polyglot.md` | Create | Operator polyglot guide. ~200 LOC. |
| `docs/v5-tier-model.md` | Create | Tier semantics doc. ~100 LOC. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] `ResolveProvider("coder")` returns a `claude.Provider` when `PROVIDER=claude` env set. Verified.
- [ ] `ResolveProvider("coder")` returns a `codex.Provider` when `PROVIDER=codex` set. Verified.
- [ ] `ResolveProvider("coder")` returns a `*Chain` when `PROVIDER=codex,claude` set. Verified.
- [ ] `PROVIDER_CODER=codex` takes precedence over `PROVIDER=claude` for coder stage. Verified.
- [ ] When neither env is set, `ResolveProvider` defaults to `"codex,claude"` (cost-ranked). Verified.
- [ ] `runner.go` consults `providerForStage(stage)` for each stage dispatch — no remaining `claude.New(...)` literal in `runner.go`. Verified by `! grep -nE 'claude\.New\(' internal/runner/runner.go`.
- [ ] `cmd/tekhton/run.go` defines `--provider`, `--provider-chain`, `--require-tier` flags. Verified by grep.
- [ ] `--provider <name>` CLI flag override beats env. Verified by integration test.
- [ ] `templates/pipeline.conf.example` contains `PROVIDER=codex,claude` as default + commented per-stage overrides. Verified.
- [ ] `lib/init_config_sections.sh` emits the PROVIDER block into a freshly-rendered pipeline.conf. Verified by `tekhton --init` smoke test against a temp dir.
- [ ] `docs/v5-polyglot.md` exists with ≥7 `##` sections per the design. Verified.
- [ ] `docs/v5-tier-model.md` exists with ≥5 `##` sections per the design. Verified.
- [ ] `docs/v5-polyglot.md` "Migration path" section contains an explicit callout that the default provider changed from implicit Claude to `codex,claude` and documents how to restore Claude-only behavior. Verified by `grep -q 'PROVIDER=claude' docs/v5-polyglot.md`. [PM: Added — required by Migration Impact section.]
- [ ] No regression in m07-m13 tests OR m01-m06 V5 reliability tests OR earlier.
- [ ] `golangci-lint run` and `go vet` clean.
- [ ] Full suite passes.

## Watch For

- **m13's Chain wiring for `TEKHTON_REQUIRE_TIER`.** The `--require-tier`
  flag sets env that the Chain should consult AT RUN TIME. If m13's
  Chain.RunAgent doesn't actually read `TEKHTON_REQUIRE_TIER`, m15
  needs to add the read. Verify before declaring this acceptance
  criterion satisfied. If wiring is missing, fold the fix into m15
  (don't open m16 for one missing env read).
- **Don't recreate m12 or m13 work.** The Chain exists. The
  `Tier()` interface exists. Both Claude and Codex implement `Tier()`.
  If `internal/runner/provider_chain.go` looks "incomplete" to the
  coder, that's a misreading — leave it alone.
- **The runner's per-stage dispatch is the integration point.**
  Today `Runner.Provider` is a single value. After m15 it becomes
  a per-stage lookup. Existing call sites that read `r.Provider`
  need to switch to `r.providerForStage(stage)`. Watch for missed
  call sites — `grep -nE 'r\.Provider\b'` should return zero matches
  in `internal/runner/` and `cmd/` after the migration.
- **Document the `TEKHTON_CLAUDE_PRE_JUNE_15` env in `docs/v5-tier-model.md`.**
  It's an operator escape hatch and should be discoverable. The
  Claude provider's source mentions it; the docs should too.
- **The default `PROVIDER=codex,claude` is cost-ranked.** Don't
  default to `claude,codex` — that defeats m13's whole purpose. The
  default goes cheapest-first.
- **Don't add cost telemetry references in m15's docs.** m14 owns
  the cost banner + budget caps + forecast story. m15's
  `docs/v5-polyglot.md` mentions cost in the "Cost considerations"
  section but should NOT explain budget caps or RUN_SUMMARY cost
  rows — those land in m14's own docs.
- **Migration impact callout is required in docs.** The "Migration path" section of `docs/v5-polyglot.md` MUST explicitly warn that m15 changes the effective default from Claude-only (implicit pre-m15 behavior) to `codex,claude`. Operators who want Claude-only must set `PROVIDER=claude`. [PM: Added to mirror the Migration Impact section.]

## Seeds Forward

- **m14 — Cost telemetry.** Independent of m15. After both ship,
  RUN_SUMMARY surfaces tier_used (from m13 via Chain), cost (from
  m14), and operator can configure both per-stage budget caps (m14)
  and provider chain (m15) from `pipeline.conf`.
- **V5 Phase 1 close.** After m14 + m15, V5 Phase 1 is feature-
  complete. The operator can actually use Codex end-to-end with
  cost visibility + caps.
- **m16 candidate — false-complete detection.** The m09 + m12 + m13
  false-complete pattern is worth a future reliability fix. A
  finalize-time check could parse the milestone file's "Files
  Modified" table and verify each declared file was touched in
  the run's diff. Out of m15 scope; tracked as a Phase 2 candidate.
- **Per-stage Provider construction overhead.** Today
  `providerForStage` caches per-stage. For 8 stages with `PROVIDER=codex,claude`
  the runner constructs the chain 8 times. Negligible cost today
  but worth profiling if it surfaces. The cache invalidation
  policy is "runner lifetime" — no need to invalidate within a
  run.
