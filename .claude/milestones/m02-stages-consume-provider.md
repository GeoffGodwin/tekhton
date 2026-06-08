<!-- milestone-meta
id: "02"
status: "todo"
-->

# m02 (V5) — Stages Consume Provider Interface (Supervisor Direct-Call Retirement)

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1, Milestone 2. m01 shipped the `provider.Provider` interface and Claude reference implementation. m02 migrates every pipeline stage from calling `internal/supervisor/` directly to consuming `provider.Provider`. After m02, the supervisor is invoked only through the Claude provider — no stage code references it. This unblocks m05-m08: the Codex provider can plug into the same seam and stages don't care which provider runs. The work is mechanical (8 stages × ~30 min of seam edits each) but the parity test from m01 is the safety net — every migrated stage must continue to produce identical agent results before and after the switch. |
| **Gap** | At m01 close, the seam exists but nothing consumes it. Eight pipeline stages have their own `invokeXxxAgent` helper that calls `internal/supervisor.Run()` directly: `internal/stages/intake/intake.go::invokeIntakeAgent`, `internal/stages/review/cycle.go::invokeReviewerAgent` + `rework.go::invokeCoderRework` + `specialist.go::invokeSpecialistAgent`, `internal/stages/security/run.go::invokeScanAgent`, `internal/stages/coder/coder.go::invokeCoderAgent`, `internal/stages/tester/dispatch.go::invokeTesterAgent`, `internal/stages/docs/docs.go::invokeDocsAgent`, `internal/stages/cleanup/cleanup.go::invokeCleanupAgent`, `internal/stages/architect/architect.go::invokeArchitectAgent`. Each one builds a `supervisor.AgentRequest`, calls `Run`, and translates the `supervisor.AgentResult` back. That translation now belongs in `internal/provider/claude/`. The stage seams should consume `provider.Provider` (an interface), not `*supervisor.Supervisor` (a concrete type). |
| **m02 fills** | A per-stage migration that changes each `invokeXxxAgent` function to accept a `provider.Provider` instead of a `*supervisor.Supervisor`, populates a `*provider.Request`, calls `Provider.RunAgent`, and consumes a `*provider.Result`. The Provider is dependency-injected through stage configuration (a new field on the per-stage `config` struct) with `claude.New()` as the default. After m02 lands, `grep -nE 'supervisor\.' internal/stages/` returns zero matches — the supervisor is purely a Claude-provider implementation detail. The supervisor package is NOT moved or modified; its API stays unchanged. The per-stage seam test files (`*_test.go`) update to mock `provider.Provider` instead of `*supervisor.Supervisor`. A new shim-boundary test drives a full single-stage invocation through the migrated seam and asserts the result is byte-for-byte identical to a pre-m02 baseline. |
| **Depends on** | m01 |
| **Files changed** | `internal/stages/intake/intake.go` + tests, `internal/stages/review/cycle.go` + `rework.go` + `specialist.go` + tests, `internal/stages/security/run.go` + tests, `internal/stages/coder/coder.go` + tests, `internal/stages/tester/dispatch.go` + tests, `internal/stages/docs/docs.go` + tests, `internal/stages/cleanup/cleanup.go` + tests, `internal/stages/architect/architect.go` + tests, `cmd/tekhton/run.go` (Provider factory wiring), `internal/runner/runner.go` (Provider injection plumbing), `tests/test_stages_provider_migration.sh` (new shim-boundary test) |

### V5 Phase 1 arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m01 | Provider interface + Claude reference. Seam exists, nothing consumes it yet. |
| **m02** | **Eight stages migrate from direct supervisor calls to consuming Provider. After m02, supervisor is private to the Claude provider.** |
| m03 | `ToolSchema` type + Claude translator. The `Tools` field on Request becomes meaningful. |
| m04-m07 | Codex provider end-to-end. |
| m08-m10 | Selection, fallback, dogfood. |

---

## Design

### Sequencing note

m02 runs after m01. The migration is per-stage and each stage can land
independently — but for milestone bookkeeping all eight stages migrate
in this single milestone so the auto-advance closes cleanly. The
implementer should land the stages one at a time (separate test runs)
to make bisection easy if a parity failure appears.

### Goal 1 — Per-stage seam migration

For each of the eight stages, change the agent-invocation helper's
signature and body. Pattern (worked example using the intake stage):

**Before (current m01-era code):**

```go
// internal/stages/intake/intake.go
func invokeIntakeAgent(ctx context.Context, cfg config, prompt string) (*supervisor.AgentResult, error) {
    sup := supervisor.New()
    return sup.Run(ctx, &supervisor.AgentRequest{
        Prompt:   prompt,
        MaxTurns: cfg.MaxTurns,
        Model:    cfg.Model,
        Label:    "Intake",
        // ...
    })
}
```

**After m02:**

```go
// internal/stages/intake/intake.go
func invokeIntakeAgent(ctx context.Context, cfg config, prompt string) (*provider.Result, error) {
    return cfg.Provider.RunAgent(ctx, &provider.Request{
        Prompt:   prompt,
        MaxTurns: cfg.MaxTurns,
        Model:    cfg.Model,
        Label:    "Intake",
        // ...
    })
}
```

The per-stage `config` struct gets a new field:

```go
type config struct {
    // ... existing fields
    Provider provider.Provider // m02 — injected by runner; defaults to claude.New().
}
```

Callers that consume the result (the cycle loop in review, the scan
loop in security, etc.) change to consume `*provider.Result` instead
of `*supervisor.AgentResult`. The field mapping is one-for-one for
the cross-provider fields; per-Claude-specific fields previously
read from `supervisor.AgentResult` become inaccessible to stages —
they live in `provider.Result.RawProviderData` instead, and stages
that needed them (none observed today after the m37.2 / m38.6 ports)
would need to be re-evaluated.

### Goal 2 — Runner-level Provider injection

**File:** `internal/runner/runner.go`.

The runner builds each stage's request and dispatches to the stage
runner. m02 adds a per-stage Provider to the dispatch path:

```go
type Runner struct {
    // ... existing fields
    Provider provider.Provider // m02 — default Claude; m09 makes this per-stage configurable.
}

func New(...) *Runner {
    return &Runner{
        // ... existing wiring
        Provider: claude.New(),
    }
}
```

When the runner constructs a stage's config, it injects the Provider:

```go
// In the stage-dispatch site:
stageCfg := buildStageConfig(...)  // existing
stageCfg.Provider = r.Provider     // m02 — inject

stageRes, err := stagerunner.Run(ctx, stageReq)
```

The `cmd/tekhton/run.go` builder for the Runner accepts an optional
Provider override via a CLI flag (`--provider claude` for now —
m09 widens this to `--provider claude,codex,qwen`).

### Goal 3 — Test updates

Every stage's `*_test.go` files that mock the supervisor today need
to migrate to mocking `provider.Provider`. Pattern:

**Before:**

```go
type fakeSupervisor struct {
    response *supervisor.AgentResult
}

func (f *fakeSupervisor) Run(_ context.Context, _ *supervisor.AgentRequest) (*supervisor.AgentResult, error) {
    return f.response, nil
}

// In tests:
sup := &fakeSupervisor{response: &supervisor.AgentResult{...}}
result := invokeIntakeAgent(ctx, config{Supervisor: sup}, prompt)
```

**After m02:**

```go
type fakeProvider struct {
    response *provider.Result
}

func (f *fakeProvider) Name() string { return "fake" }
func (f *fakeProvider) RunAgent(_ context.Context, _ *provider.Request) (*provider.Result, error) {
    return f.response, nil
}

// In tests:
p := &fakeProvider{response: &provider.Result{...}}
result := invokeIntakeAgent(ctx, config{Provider: p}, prompt)
```

The test fixtures (return-value canned responses) translate one-for-one
from `supervisor.AgentResult` fields to `provider.Result` fields, with
the m01 Outcome mapping applied.

### Goal 4 — Shim-boundary regression guard

**File:** `tests/test_stages_provider_migration.sh` (new, ~120 lines).

Drives `tekhton --milestone <fixture>` against a synthesized milestone
fixture. The fixture's coder agent produces a deterministic single-file
change (e.g., add a comment to a known file). The test asserts:

1. The resulting commit's diff matches a pre-m02 baseline byte-for-byte.
2. The RUN_SUMMARY.json reports the same agent_calls count.
3. No file under `internal/supervisor/` was touched in the commit
   (proves the supervisor's API stayed unchanged through the migration).

Self-skips when the Go binary isn't built — same pattern as the
m44-m50 shim-boundary tests.

### Goal 5 — Audit: no direct supervisor references in stages

The acceptance criterion below mandates `grep -nE 'supervisor\.' internal/stages/`
returns zero matches. Run the audit during implementation; if a stage
still references the supervisor package, the migration for that stage
is incomplete. The intent is hard separation: stages know about
`provider.Provider`, the Claude provider knows about the supervisor,
and the two don't cross.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/stages/intake/intake.go` | Modify | `invokeIntakeAgent` consumes `cfg.Provider` instead of constructing a supervisor. |
| `internal/stages/intake/intake_test.go` | Modify | Mock `provider.Provider` instead of supervisor. |
| `internal/stages/intake/config.go` | Modify | Add `Provider provider.Provider` to the config struct. |
| `internal/stages/review/cycle.go` | Modify | `invokeReviewerAgent` consumes `cfg.Provider`. |
| `internal/stages/review/rework.go` | Modify | `invokeCoderRework`, `invokeJrCoderRework` consume `cfg.Provider`. |
| `internal/stages/review/specialist.go` | Modify | `invokeSpecialistAgent` consumes `cfg.Provider`. |
| `internal/stages/review/cycle_test.go` + sibling tests | Modify | Mock `provider.Provider`. |
| `internal/stages/security/run.go` | Modify | `invokeScanAgent` consumes `cfg.Provider`. |
| `internal/stages/security/run_test.go` | Modify | Mock `provider.Provider`. |
| `internal/stages/coder/coder.go` | Modify | `invokeCoderAgent` consumes `cfg.Provider`. |
| `internal/stages/coder/coder_test.go` | Modify | Mock `provider.Provider`. |
| `internal/stages/tester/dispatch.go` | Modify | `invokeTesterAgent` consumes `cfg.Provider`. |
| `internal/stages/tester/tester_test.go` + siblings | Modify | Mock `provider.Provider`. |
| `internal/stages/docs/docs.go` | Modify | `invokeDocsAgent` consumes `cfg.Provider`. |
| `internal/stages/docs/docs_test.go` | Modify | Mock `provider.Provider`. |
| `internal/stages/cleanup/cleanup.go` | Modify | `invokeCleanupAgent` consumes `cfg.Provider`. |
| `internal/stages/cleanup/cleanup_test.go` | Modify | Mock `provider.Provider`. |
| `internal/stages/architect/architect.go` | Modify | `invokeArchitectAgent` consumes `cfg.Provider`. |
| `internal/stages/architect/architect_test.go` | Modify | Mock `provider.Provider`. |
| `internal/runner/runner.go` | Modify | Add `Runner.Provider`; inject into stage configs during dispatch. |
| `internal/runner/runner_test.go` | Modify | Add test covering Provider injection. |
| `cmd/tekhton/run.go` | Modify | Wire the Runner's Provider field via a default `claude.New()` factory. |
| `tests/test_stages_provider_migration.sh` | Create | Shim-boundary regression guard. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] `grep -nE 'internal/supervisor' internal/stages/` returns ZERO matches. Verified by direct `grep` after the migration. The supervisor is no longer imported by any stage package.
- [ ] `grep -nE 'supervisor\.AgentRequest|supervisor\.AgentResult|supervisor\.Supervisor' internal/stages/` returns ZERO matches. Verified the same way.
- [ ] Every stage's `config` struct has a `Provider provider.Provider` field. Verified by `grep -nE 'Provider provider.Provider' internal/stages/*/config.go` returning at least 8 matches (one per stage).
- [ ] `internal/runner/runner.go::Runner` has a `Provider provider.Provider` field that defaults to `claude.New()`. Verified by `grep -nE 'Provider provider.Provider' internal/runner/runner.go` + a unit test asserting `New().Provider != nil`.
- [ ] Every stage's existing tests pass after the migration. Verified by `go test ./internal/stages/... -count=1` exit 0.
- [ ] The m01 parity test (`internal/provider/claude/parity_test.go`) still passes — m02 didn't break the Claude provider. Verified by `go test -run TestClaudeProvider_ParityWithDirectSupervisor ./internal/provider/claude/...`.
- [ ] The shim-boundary test `tests/test_stages_provider_migration.sh` passes: pre-m02 vs post-m02 commit diffs are byte-for-byte identical for a synthesized fixture. Verified by running the test.
- [ ] `internal/supervisor/` is NOT modified in this milestone. Verified by `git diff HEAD~ internal/supervisor/` returning empty.
- [ ] No regression in: `internal/runner/...`, `cmd/tekhton/...`, `internal/finalize/...` tests.
- [ ] `shellcheck tests/test_stages_provider_migration.sh` returns zero warnings.
- [ ] `golangci-lint run ./internal/stages/... ./internal/runner/... ./cmd/tekhton/...` and `go vet` clean.
- [ ] Full suite passes: `bash tests/run_tests.sh` + `go test ./...`.

## Watch For

- **Land the eight stages one at a time** even though they all sit in
  one milestone. After each stage migrates, run that stage's tests +
  the m01 parity test. If a parity failure appears, bisecting one
  stage is cheap; bisecting all eight at once is painful.
- **Don't widen the `provider.Request` field set during this
  migration.** If a stage today consumes a supervisor field that
  isn't in `provider.Result`, that's a m01 oversight — file a Drift
  Observation, return the closest-fit value, and let m03+ widen the
  Result type if needed. Adding fields mid-migration risks leaving
  half the stages on the old shape.
- **The `Provider` field in each stage's config must be injected, not
  defaulted.** Tempting shortcut: `if cfg.Provider == nil { cfg.Provider = claude.New() }`.
  Don't. The runner is the authoritative injection site (Goal 2);
  per-stage defaulting masks wiring bugs where the runner forgot to
  inject. Let nil-Provider panic in tests so the wiring gap surfaces.
- **The test mocks need the full `provider.Provider` interface,
  including `Name()`.** Don't ship test fakes that only implement
  `RunAgent` — the compiler will complain but operator-facing test
  output is clearer when fakes return a meaningful `Name()` like
  `"fake-claude"` or `"recorded-fixture"`.
- **Per-stage parity guards.** Before declaring a stage migrated,
  capture a pre-migration RUN_SUMMARY.json for a fixture invocation
  and a post-migration one. Diff them. If anything except timing
  varies, the migration changed observable behavior — investigate
  before continuing.
- **Don't move the supervisor package.** Tempting to relocate to
  `internal/provider/claude/internal/supervisor/`. Don't — that's a
  larger refactor and risks invalidating the parity test. Leave the
  supervisor where it is; the Claude provider imports it from there.
  A future cleanup milestone can relocate after the polyglot story
  is proven.

## Seeds Forward

- **m03 — ToolSchema.** With Provider injection live across stages,
  m03's `ToolSchema` can flow through `provider.Request.Tools` and
  reach the Claude provider where the translation happens. Stages
  don't change for m03; they just populate `Request.Tools` with the
  Tekhton-internal schema and the Claude translator handles the rest.
- **m05-m08 — Codex provider.** Drops in as a second
  `provider.Provider` implementation. No stage changes needed.
  Runner construction adds a Codex factory wiring path.
- **Per-stage provider selection (m09).** Once stages consume an
  injected Provider via config, `pipeline.conf` learning a per-stage
  `PROVIDER=` becomes mechanical: the runner reads the config,
  constructs the right Provider per stage, injects.
- **Stage-level fallback chains.** A future enhancement to the
  runner's injection path could wrap the per-stage Provider in a
  fallback chain (`primary → secondary → tertiary`). The stage code
  doesn't care; from its perspective `cfg.Provider.RunAgent()`
  always returns a Result, with the fallback logic invisible.
- **Cost telemetry.** With every agent invocation flowing through
  `provider.Provider`, a future arc can wrap any Provider in a
  cost-tracking decorator. The wrapped provider records token counts
  into `internal/metrics/` from `Result.RawProviderData`. Out of
  V5 Phase 1 scope; the seam supports it cleanly.
