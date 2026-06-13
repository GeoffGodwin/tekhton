<!-- milestone-meta
id: "21"
status: "todo"
-->

# m21 — Quota Probe Provider-Gating + Post-Cutover Cost-Leak Guards

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | June 15 cutover safety. Two cost hazards survive m13–m15: (a) the quota-pause probe layer fires real `claude` calls (`claude --output-format json -p`, `claude --max-turns 0`) to detect quota refresh — post-cutover each "free probe" becomes a metered API charge, and the probes run on a loop during pauses; (b) the default chain `codex,claude` means any Codex upstream error silently falls through to metered Claude API billing with nothing louder than a tier value in RUN_SUMMARY. The operator asked for cost-ranked routing, not surprise invoices. |
| **Gap** | (1) `lib/quota_probe.sh:35,48,70,73,89` and `internal/supervisor/quota_probe.go:137` (`binary = "claude"`) probe claude unconditionally — even when the active provider spec doesn't include claude, and regardless of claude's tier (subscription vs metered API). `cmd/tekhton/quota.go` exposes this directly. (2) `internal/runner/provider_chain.go::RunAgent` falls through tiers silently — no causal event, no stderr warning, no opt-in gate when the fallthrough crosses from a free/subscription tier to `api`. (3) `docs/v5-tier-model.md:77-79`: `tier_used=""` on single-provider runs, so RUN_SUMMARY can't even tell the operator which tier actually billed (carried forward in `.tekhton/NON_BLOCKING_LOG.md`). |
| **m21 fills** | (1) Provider-gates the quota probe: probes only run when claude is in the effective provider spec for the paused agent, and **paid-tier probing requires explicit opt-in** — when claude's `Tier()` reports `api`, the layered probe degrades to version/clock-based waiting unless `QUOTA_PROBE_ALLOW_PAID=true`. Applies to both the Go probe (`internal/supervisor/quota_probe.go`) and the bash legacy probe (`lib/quota_probe.sh`). (2) Chain fallthrough telemetry + gate: `Chain.RunAgent` emits a causal event (`provider_fallthrough`) and a stderr warning naming from-provider, to-provider, and both tiers on every fallthrough; when the fallthrough would *increase* `TierCostRank` to `api`, it is blocked unless `PROVIDER_ALLOW_PAID_FALLBACK=true` (flat default `false` — deterministic, no date conditionals; the operator opts in once in pipeline.conf). (3) `TierUsed` is stamped on every successful result, single provider or chain. (4) Gates the one remaining Go-side claude exec outside the provider/supervisor: `internal/preflight/claude_env.go::checkClaudeVersion` (line ~93-97) runs `claude --version` whenever the binary is on PATH — it becomes a no-op when claude is absent from every resolved stage spec, so a zero-claude run truly execs zero claude (m23 asserts this end-to-end). |
| **Depends on** | m19 |
| **Files changed** | `internal/supervisor/quota_probe.go`, `lib/quota_probe.sh`, `lib/quota.sh`, `cmd/tekhton/quota.go`, `internal/runner/provider_chain.go`, `internal/runner/supervise_bridge.go`, `internal/preflight/claude_env.go`, `internal/causal` (event const), `internal/config/defaults.go`, `templates/pipeline.conf.example`, `docs/v5-tier-model.md`, tests |

---

## Design

### Sequencing note

Depends on m19 only for the seam's provider observability (knowing the
effective spec for a paused agent). The chain changes are independent of
m20 and may not be reordered after m23 (which asserts them).

### Goal 1 — provider-gated, paid-aware quota probing

The M125 layered probe (version → zero-turn → fallback JSON probe) stays
intact for the subscription-tier world. Two new gates in front of it:

1. **Chain membership:** the probe layer receives the effective provider
   spec (from the supervise seam / env). If `claude` is not in the spec,
   `enter_quota_pause`'s probe loop is skipped entirely — a quota pause
   for codex/qwen-local uses that provider's own retry-after signal
   (m11) and the chunked sleep, never a claude probe.
2. **Paid-tier opt-in:** when the claude provider's `Tier()` returns
   `api` (the post-June-15 state, see `TEKHTON_CLAUDE_PRE_JUNE_15` in
   `docs/v5-tier-model.md`), the zero-turn and JSON probes (the ones
   that hit the API) are disabled unless `QUOTA_PROBE_ALLOW_PAID=true`.
   The free `claude --version` liveness layer may still run. Log one
   line explaining the degraded probe mode.

Config: `QUOTA_PROBE_ALLOW_PAID` (default `false`), clamped/validated
alongside the existing `QUOTA_PROBE_*` keys in both default tables
(`internal/config/defaults.go` + bash consumer reads per the V4 env
contract, `docs/v4-env-contract.md`).

### Goal 2 — chain fallthrough telemetry and the paid-fallback gate

In `Chain.RunAgent` (`internal/runner/provider_chain.go`):

- On each fallthrough (OutcomeUpstreamError → next provider): emit a
  `provider_fallthrough` causal event `{from, from_tier, to, to_tier,
  label}` and a single stderr warning line.
- Before attempting the next provider, if
  `TierCostRank(next.Tier()) > TierCostRank(prev.Tier())` and
  `next.Tier() == TierAPI` and `PROVIDER_ALLOW_PAID_FALLBACK` resolves
  false: stop the chain, returning the last result annotated
  `ErrorSubcategory: "PAID_FALLBACK_BLOCKED"`. The error message must
  name the env key to flip.
- `PROVIDER_ALLOW_PAID_FALLBACK` default: `false`, unconditionally —
  no date-conditional behavior in code (deterministic per
  Non-Negotiable rule 4; the claude tier value already encodes the
  cutover via `TEKHTON_CLAUDE_PRE_JUNE_15`). The operator who wants
  automatic metered fallback sets it once in pipeline.conf — the
  comment block in `templates/pipeline.conf.example` explains the
  June-15 reasoning. Note this is an intentional behavior change to
  the m12 chain default: existing chain tests asserting silent
  fallthrough set the flag rather than being deleted.

### Goal 4 — gate the preflight claude liveness check

`internal/preflight/claude_env.go::checkClaudeVersion` execs
`claude --version` whenever a claude binary is on PATH. Gate it on
claude appearing in at least one resolved stage spec (same dry
resolution the m23 preflight rule uses); when claude is out of the
chain, the check returns a skip finding instead of exec'ing. Without
this, any zero-claude assertion (m23) fails on preflight itself.

### Goal 3 — uniform `TierUsed`

Stamp `Result.TierUsed` on the single-provider path too (where the
caller bypasses Chain): the natural seam is the supervise bridge /
stage dispatch where the resolved provider is known — set
`TierUsed = p.Tier()` whenever it is empty on a successful result.
Update `docs/v5-tier-model.md:77-79` to remove the "single-provider runs
leave tier_used empty" caveat, and assert the field is non-empty in the
RUN_SUMMARY emit test.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/supervisor/quota_probe.go` | Modify | Chain-membership + paid-tier gates ahead of the layered probe. |
| `lib/quota_probe.sh` | Modify | Same two gates on the bash legacy probe path; reads `${QUOTA_PROBE_ALLOW_PAID:-false}` per env contract. |
| `cmd/tekhton/quota.go` | Modify | Plumb spec/tier context into the probe; `--allow-paid` flag override. |
| `internal/runner/provider_chain.go` | Modify | Fallthrough causal event + stderr warning + paid-fallback gate. |
| `internal/runner/supervise_bridge.go` | Modify | Stamp `TierUsed` for single-provider successes. |
| `internal/preflight/claude_env.go` | Modify | `checkClaudeVersion` gated on claude-in-resolved-spec; skip finding otherwise. |
| `internal/causal` event constants | Modify | `provider_fallthrough` event type registration. |
| `internal/config/defaults.go` | Modify | `QUOTA_PROBE_ALLOW_PAID`, `PROVIDER_ALLOW_PAID_FALLBACK` defaults. |
| `lib/quota.sh` | Modify | Bash-side `${QUOTA_PROBE_ALLOW_PAID:-false}` env-contract read at the probe consumption point. |
| `templates/pipeline.conf.example` | Modify | Document both keys with June-15 cost framing. |
| `docs/v5-tier-model.md` | Modify | Fallthrough gate semantics; tier_used now always recorded. |
| `internal/supervisor/quota_probe_test.go` | Modify | Probe gating table tests (chain membership × tier × opt-in flag). |
| `internal/runner/provider_chain_test.go` | Modify | Fallthrough event + paid-fallback gate tests. |
| `internal/preflight/claude_env_test.go` | Modify | Skip-when-out-of-chain assertion. |
| `tests/test_quota.sh` | Modify | Bash probe gating under PATH-shim claude. |

---

## Acceptance Criteria

- [ ] With a provider spec of `codex` (no claude) for the paused agent, neither `internal/supervisor/quota_probe.go` nor `lib/quota_probe.sh` executes any `claude` invocation during a quota pause (Go test with fake exec recorder; bash test with PATH-shim claude).
- [ ] With claude in the spec and claude `Tier() == "api"` and `QUOTA_PROBE_ALLOW_PAID` unset, the zero-turn and JSON probe layers do not run; the version-layer may; a log line states the degraded mode.
- [ ] With `QUOTA_PROBE_ALLOW_PAID=true`, pre-m21 layered probe behavior is restored (existing M125 probe tests pass under this flag).
- [ ] `Chain.RunAgent` fallthrough emits a `provider_fallthrough` causal event containing `from`, `from_tier`, `to`, `to_tier` (asserted in a chain test with two fake providers).
- [ ] With `PROVIDER_ALLOW_PAID_FALLBACK` unset and a chain whose next provider has tier `api` and a higher cost rank, the chain stops with `ErrorSubcategory == "PAID_FALLBACK_BLOCKED"` and the error message contains `PROVIDER_ALLOW_PAID_FALLBACK`.
- [ ] With `PROVIDER_ALLOW_PAID_FALLBACK=true`, the chain falls through to the api-tier provider and stamps its tier in `TierUsed`.
- [ ] A successful single-provider run (no chain) produces a non-empty `tier_used` in RUN_SUMMARY (emit test updated).
- [ ] `internal/preflight` does not exec `claude --version` when no resolved stage spec contains claude — `checkClaudeVersion` returns a skip finding instead (table test with fake exec recorder).
- [ ] `scripts/audit-raw-claude.sh` passes on the tree with `lib/quota_probe.sh` as its only (annotated, permanent) allowlist entry.
- [ ] All new tests pass; no regression in `go test ./...`, `bash tests/run_tests.sh`, existing M124/M125 quota tests (under the compat flag where behavior intentionally changed).
- [ ] `templates/pipeline.conf.example` and `docs/v5-tier-model.md` document both new keys.

## Watch For

- **Determinism (rule 4):** no wall-clock date checks for "post-June-15" behavior — tier reporting already encodes the cutover via `TEKHTON_CLAUDE_PRE_JUNE_15`; gate on tier, never on date.
- **Behavior change is opt-out-able:** `PROVIDER_ALLOW_PAID_FALLBACK=false` default changes the m12 chain's observable behavior. The default flip must be loud in docs and the pipeline.conf template; existing chain tests asserting fallthrough need the flag set, not deleted.
- **TUI pause panel (M124/M125):** `tui_ops_pause.sh` renders probe countdowns; degraded-probe mode must still feed it a next-wake time or the panel shows garbage.
- **Don't touch m14 budget caps:** per-stage cost caps are adjacent but separate; resist merging their logic into the chain gate.
- **The bash probe is legacy-path only** — keep its change minimal (two guard clauses), no refactor; it retires with the bash orchestrator.

## Seeds Forward

- **m23 (zero-claude verification):** asserts no claude execution during induced quota pauses under `PROVIDER=codex` — this milestone makes that true.
- **Cost-governance (DESIGN_v5 NFR arc):** the `provider_fallthrough` causal event is the data source for future spend-ceiling enforcement.
- **Operator trust:** uniform `tier_used` makes the RUN_SUMMARY cost banner (m14) trustworthy for billing reconciliation.
