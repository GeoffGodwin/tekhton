<!-- milestone-meta
id: "19"
status: "todo"
-->

# m19 — Provider-Aware Supervise Seam: Retire Remaining Claude Direct-Calls

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | June 15 cutover readiness. m12/m15 made the eight pipeline stages provider-aware via `ResolveProvider`, but every agent that runs *outside* the stage dispatch path is still hardwired to the Claude supervisor. The most important one runs in **every milestone run**: the finalize final-checks fix agent (`internal/finalize/orchestrator.go:29` delegates `_hook_final_checks` to `lib/hooks_final_checks.sh` via `runBashHookFn`, which calls bash `run_agent` → `tekhton supervise`). After June 15 these paths either fail (no Claude subscription CLI) or silently bill the metered API. |
| **Gap** | (1) `cmd/tekhton/supervise.go:67` constructs `supervisor.New(nil, nil)` directly — `PROVIDER`/`PROVIDER_<STAGE>` env is ignored, and `internal/supervisor/supervisor.go:35` pins `defaultBinary = "claude"`. Every bash `run_agent` caller is therefore Claude-only: `lib/hooks_final_checks.sh` (final-fix agent), `lib/specialists.sh`, `lib/dry_run.sh`, `lib/draft_milestones.sh`, `lib/orchestrate_complete.sh`, `lib/orchestrate_preflight.sh`, `lib/run_summary_reconstruct.sh`. (2) `cmd/tekhton/run_stage.go:76` hardcodes `claude.New(supervisor.New(nil, nil))` for all eight stages instead of calling `runner.ResolveProvider`. (3) `internal/tester/tdd/tdd.go` and `internal/test_audit/audit.go` call `supervisor.New` directly. (4) `internal/runner/provider_chain.go::RunAgent` returns `(nil, nil)` on an empty `Providers` slice (documented as a test comment at `provider_chain_test.go:258-273` instead of fixed — carried forward in `.tekhton/NON_BLOCKING_LOG.md`). |
| **m19 fills** | Makes `tekhton supervise` the provider-aware seam: an optional `provider` field on the `agent.request.v1` envelope (`internal/proto/agent_v1.go`), with fallback to `ResolveProvider(label)`-style env resolution when absent, so all existing bash `run_agent` callers inherit `PROVIDER`/`PROVIDER_<STAGE>` behavior with zero bash changes. Adds a proto→provider request mapping helper so the resolved provider (codex, qwen-local, or a chain) can serve a supervise request. Replaces the hardcoded Claude construction in `run_stage.go`, `tdd.go`, and `test_audit/audit.go` with `ResolveProvider` (or an injected provider). Adds the empty-chain early-exit guard in `provider_chain.go`. |
| **Depends on** | m15 |
| **Files changed** | `internal/proto/agent_v1.go`, `cmd/tekhton/supervise.go`, `cmd/tekhton/run_stage.go`, `internal/runner/provider_select.go`, `internal/runner/provider_chain.go`, `internal/runner/supervise_bridge.go` (new), `internal/tester/tdd/tdd.go`, `internal/test_audit/audit.go`, tests for each, `tests/test_supervise_provider_boundary.sh` (new shim-boundary test), `docs/v5-provider-seam.md` |

---

## Design

### Sequencing note

m19 lands before m20 (planning batch) and m21 (quota gating) — both route
through the seam this milestone builds. Do not start m20/m21 work here.

### Goal 1 — `provider` field on agent.request.v1

Add to `proto.AgentRequestV1` (`internal/proto/agent_v1.go:40-49`):

```go
// Provider optionally names the provider spec ("codex", "qwen-local",
// "codex,claude") that should serve this request. Empty means resolve
// from env (PROVIDER_<LABEL> → PROVIDER → default) at the supervise seam.
Provider string `json:"provider,omitempty"`
```

Validation: accept empty; non-empty values are passed to the same
construction path `ResolveProvider` uses (`constructProvider` /
`splitCSV` in `internal/runner/provider_select.go`). Unknown names fail
the request with `proto.ErrInvalidRequest` semantics (exitUsage), not a
silent Claude fallback.

### Goal 2 — provider resolution inside `tekhton supervise`

In `cmd/tekhton/supervise.go`, replace the unconditional
`supervisor.New(nil, nil)` with:

1. If `req.Provider != ""` → build from that spec.
2. Else → `runner.ResolveProvider(sanitizeLabel(req.Label))`. Real bash
   labels are display strings, not stage names — e.g. `"Analyze Cleanup"`
   (`lib/hooks_final_checks.sh:78`), `"Test Fix (attempt 2)"` (`:184`),
   `"Specialist (security)"` (`lib/specialists.sh:143`). `sanitizeLabel`
   uppercases and maps every non-`[A-Z0-9]` run to `_` so the
   `PROVIDER_<LABEL>` lookup is always a valid env var name; in practice
   aux labels won't have a per-label override set, so resolution falls
   back to the global `PROVIDER` — that fallback is the contract that
   matters and must be tested with a space-and-parens label.
3. The resolved `provider.Provider` serves the request via a new bridge
   helper `internal/runner/supervise_bridge.go::RunProtoRequest(ctx, p,
   *proto.AgentRequestV1) (*proto.AgentResultV1, error)` that maps
   proto request ⇄ `provider.Request`/`provider.Result`. The Claude
   provider already wraps the supervisor, so the `claude` spec must
   preserve today's behavior **including the retry envelope**: route the
   claude case through `supervisor.Retry` with `DefaultPolicy()` exactly
   as the current code does (`--no-retry` keeps its meaning). Non-claude
   providers use their own retry/rate-limit handling (m11).

Resolution must be observable: log the chosen provider name to stderr at
the existing supervise log level so shim-boundary tests can assert it.

### Goal 3 — retire the other direct constructions

- `cmd/tekhton/run_stage.go:76` — replace the single hardcoded
  `claude.New(...)` with per-stage `runner.ResolveProvider(stageName)`,
  mirroring `cmd/tekhton/run.go:335-356`.
- `internal/tester/tdd/tdd.go` and `internal/test_audit/audit.go` —
  accept an injected `provider.Provider` (resolved by the caller via
  `ResolveProvider`) instead of constructing `supervisor.New` inline.
  Keep the supervisor import out of these packages entirely.
- After this goal, `grep -rln "supervisor.New" internal/ cmd/ | grep -v _test`
  returns only: `internal/runner/provider_select.go` (claude factory),
  `cmd/tekhton/quota.go` (quota probe — m21's scope, leave it).

### Goal 4 — empty-chain guard

`internal/runner/provider_chain.go::RunAgent`: when `len(c.Providers) == 0`,
return a non-nil `*provider.Result` with `Outcome: OutcomeUpstreamError`,
`ErrorSubcategory: "EMPTY_CHAIN"`, and a non-nil error. Update
`provider_chain_test.go:258-273` from documenting the `(nil, nil)` return
to asserting the guard.

### Goal 5 — shim-boundary test

`tests/test_supervise_provider_boundary.sh`, following the pattern in
`tests/test_pin_version_validation.sh`: source `lib/agent.sh` shims, place
a fake `codex` binary on PATH that records its invocation and emits a
minimal valid event stream, set `PROVIDER=codex`, drive `run_agent`, and
assert (a) the fake codex binary was invoked, (b) no `claude` invocation
occurred (PATH-shim `claude` that fails loudly), (c) the
agent.response.v1 envelope parses. Self-skip when the Go binary is not
built.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/proto/agent_v1.go` | Modify | Add optional `Provider` field + validation note. |
| `cmd/tekhton/supervise.go` | Modify | Provider resolution (envelope field → env → default) replacing direct `supervisor.New`. |
| `internal/runner/supervise_bridge.go` | Create | proto.AgentRequestV1 ⇄ provider.Request/Result mapping + label sanitization + claude retry-policy preservation. |
| `internal/runner/provider_select.go` | Modify | Expose spec-construction for envelope-provided specs; no resolution-order change. |
| `internal/runner/supervise_bridge_test.go` | Create | Mapping round-trip + claude-spec retry parity tests. |
| `cmd/tekhton/run_stage.go` | Modify | Per-stage `ResolveProvider` replaces hardcoded claude provider. |
| `internal/tester/tdd/tdd.go` | Modify | Injected provider; remove `supervisor.New`. |
| `internal/test_audit/audit.go` | Modify | Injected provider; remove `supervisor.New`. |
| `internal/runner/provider_chain.go` | Modify | Empty-chain early-exit guard. |
| `internal/runner/provider_chain_test.go` | Modify | Guard assertion replaces (nil,nil) documentation comment. |
| `tests/test_supervise_provider_boundary.sh` | Create | Shim-boundary test: bash `run_agent` honors `PROVIDER=codex`. |
| `docs/v5-provider-seam.md` | Modify | Document the supervise seam resolution order. |

---

## Acceptance Criteria

- [ ] `proto.AgentRequestV1` has a `Provider string` field with json tag `provider,omitempty`, and `Validate()` accepts an empty value.
- [ ] With `PROVIDER=codex` in env and no `provider` field in the envelope, `tekhton supervise` invokes the codex provider, not the claude supervisor (asserted by `supervise` unit test with a fake provider factory or PATH shim).
- [ ] With `provider: "qwen-local"` in the envelope, `tekhton supervise` constructs the local provider; with an unknown name (`provider: "gpt9"`) it exits with the exitUsage code and does not invoke any provider.
- [ ] A request whose label is `Test Fix (attempt 2)` (spaces + parens) resolves via the global `PROVIDER` env without error (bridge test asserts the sanitized env lookup and the fallback).
- [ ] With no `PROVIDER` env and no envelope field, `tekhton supervise` behavior on the claude path is byte-compatible with pre-m19 output for the same request fixture (existing supervise parity tests pass unmodified, except where they assert internal construction).
- [ ] `grep -rln "supervisor.New" internal/ cmd/ --include="*.go" | grep -v _test` returns only `internal/runner/provider_select.go` and `cmd/tekhton/quota.go`.
- [ ] `cmd/tekhton/run_stage.go` contains no import of `internal/provider/claude`; it calls `runner.ResolveProvider` per stage.
- [ ] `Chain.RunAgent` with zero providers returns a non-nil result with `ErrorSubcategory == "EMPTY_CHAIN"` and a non-nil error; `provider_chain_test.go` asserts this.
- [ ] `tests/test_supervise_provider_boundary.sh` passes: fake codex binary invoked, PATH-shim claude never invoked, valid agent.response.v1 emitted; test self-skips when `tekhton` binary is absent.
- [ ] All new tests pass: `internal/runner/supervise_bridge_test.go`, updated `provider_chain_test.go`, supervise command tests, `tests/test_supervise_provider_boundary.sh`.
- [ ] No regression: `go build ./... && go vet ./...` clean, `go test ./...` passes, existing supervise/run_stage parity tests pass.
- [ ] `docs/v5-provider-seam.md` documents the three-step resolution order (envelope field → `PROVIDER_<LABEL>`/`PROVIDER` env → `codex,claude` default).

## Watch For

- **Recursion hazard:** the claude provider wraps the supervisor, and `tekhton supervise` now constructs providers. The claude path must call the in-process supervisor (`supervisor.Retry`), never re-exec `tekhton supervise`.
- **Retry-policy parity:** today supervise applies `supervisor.Retry(DefaultPolicy())` unconditionally (m10). Codex/qwen-local have their own retry logic from m11 — do not double-wrap them in the supervisor retry envelope.
- **Model-name passthrough:** bash callers put Claude-style names (`sonnet`, `opus`, `claude-*`) in the envelope `model` field. Verify how `internal/provider/codex` treated the Model field during the m12 dogfood (likely ignores/overrides) and keep that behavior; do not invent a model-name mapping layer here.
- **`--no-retry` flag semantics** must survive: it bypasses retry on the claude path; for non-claude providers it should be a documented no-op, not an error.
- **Label values are display strings,** not stage names — they contain spaces and parens (`"Test Fix (attempt 2)"`). Without sanitization, `PROVIDER_<LABEL>` lookup builds an invalid env var name. The required test case is a space-and-parens label resolving cleanly to the global `PROVIDER`.
- **Out of scope:** `lib/plan_batch.sh` raw claude call (m20), quota probe (m21), any prompt changes.

## Seeds Forward

- **m20 (planning batch):** `_call_planning_batch` can be rewritten as a thin `run_agent`/`tekhton supervise` caller only once this seam resolves providers.
- **m21 (quota gating):** provider resolution at the seam tells the quota probe whether claude is even in the active chain.
- **m23 (zero-claude verification):** the PATH-shim claude technique introduced in the shim-boundary test here is reused as the global no-claude assertion harness.
- **Eventual bash retirement:** with supervise provider-aware, the remaining bash `run_agent` callers need no per-file porting work to be multi-provider — they inherit it.
