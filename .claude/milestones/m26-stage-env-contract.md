<!-- milestone-meta
id: "26"
status: "done"
-->

# m26 — Stage and Finalize Env Contract

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — sequencing gate ahead of m23–m25. The V4 Go runner owns flag parsing and stage orchestration, but does not propagate the bash globals the legacy pipeline relied on. `tekhton-legacy.sh` set `MILESTONE_MODE`, `TASK`, `_CURRENT_MILESTONE`, `AUTO_ADVANCE`, plus every `pipeline.conf` key (`ANALYZE_CMD`, `TEST_CMD`, `CLAUDE_CODER_MODEL`, `CODER_MAX_TURNS`, `INTAKE_AGENT_ENABLED`, …) at flag-parse / config-source time, then exec'd stages and finalize hooks that read those globals directly. The Go runner's stagerunner/finalize bridges export a hand-curated subset (m21 added `MILESTONE_MODE` to finalize; ad-hoc fixes in [c2fc8cf](../../) added `TASK`/`ANALYZE_CMD` defaults), leaving every `--milestone` invocation against a real project at risk of an unbound-variable crash inside an unguarded `set -u` bash script. m26 closes that gap by establishing a single typed contract for stage/finalize subprocess env, populated from the m16 config-loader output plus the run request flags. |
| **Gap** | Two distinct sources of truth for the bash env exist today and neither is wired into the Go subprocess builder: (1) `lib/config.sh` (m16 wedge shim) execs `tekhton config load --emit shell` and `eval`s its output — invoked only when the **legacy** bash entry point runs, never by `tekhton run`. (2) `tekhton-legacy.sh` lines 240-260 set runtime globals (`AUTO_ADVANCE`, `MILESTONE_MODE`, `HUMAN_MODE`, `_CURRENT_MILESTONE`, `TASK_SLUG`, `LOG_FILE`) from flag parsing — these globals never appear in `internal/runner/single.go:buildPipelineRequest` or `internal/finalize/shim.go:buildEnv`. Result: when a `tekhton run --milestone m23` invocation hits any bash script that reads one of these globals (e.g. `lib/intake_helpers.sh:191` reading `$MILESTONE_MODE`, `lib/intake_helpers.sh:224` reading `$TASK`, `lib/hooks_final_checks.sh:23` reading `$ANALYZE_CMD`), `set -u` trips and the stage subprocess exits non-zero. The runner records this as a stage failure with `agent_calls=0`, dispatches `save_exit` recovery, and the user sees a cascade of "unbound variable" lines with no functional pipeline run. The damage is broad: every bash file under `lib/` and `stages/` is a potential trip site, and the only defensive coverage we have is per-call `${VAR:-default}` patches applied reactively after each crash. |
| **m26 fills** | (1) New `internal/runner/env.go` package builds a typed `StageEnvBuilder` that composes three layers: project config (from `config.Load` — the in-process m16 surface), run-request flags (`MILESTONE_MODE`, `TASK`, `_CURRENT_MILESTONE`, `AUTO_ADVANCE`, `AUTO_ADVANCE_LIMIT`, `HUMAN_MODE`, `HUMAN_NOTES_TAG`, `LOG_FILE`, `LOG_DIR`, `TIMESTAMP`), and explicit caller overrides (test seams). (2) `Runner.New` caches a single `*config.Config` per run, loaded from `${ProjectDir}/.claude/pipeline.conf` via `config.Load`. (3) `buildPipelineRequest` and `BashShimHook.buildEnv` consume the cached config + run-request flags and emit the same env to every subprocess, so any new bash hook automatically inherits the full set. (4) The runtime-flag set the builder exports is named on `internal/proto/stage_env.go` as `StageEnvV1` — a versioned contract that tracks future additions. (5) Existing per-stage `EnvOverrides` still wins (test seams + advanced stage configs). (6) `LOG_FILE` is constructed once at the runner level (`${LogDir}/${Timestamp}_${task_slug}.log`) and passed through the contract instead of being hand-synthesized inside `finalize/shim.go`. (7) Adapter tests assert the contract: every stage in `defaultStageOrder()` sees the full set; every finalize hook sees the same set plus disposition; a missing `pipeline.conf` produces an env with defaults + run-request flags only (no crash). (8) `VERSION` bumps to `4.26.0` on close. m27 follows immediately to harden the bash side against any remaining unguarded reads + add the audit/parity gates. |
| **Depends on** | m22 |
| **Files changed** | `internal/runner/env.go`, `internal/runner/env_test.go`, `internal/runner/runner.go`, `internal/runner/single.go`, `internal/finalize/shim.go`, `internal/proto/stage_env.go`, `internal/proto/stage_env_test.go`, `cmd/tekhton/run.go`, `cmd/tekhton/run_test.go`, `docs/v4-env-contract.md`. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m16 | `internal/config/` Go package + `tekhton config load --emit shell` subcommand. Reads `pipeline.conf`, applies defaults, emits shell K=V. The runtime that *creates* the bash env exists; the runner that *consumes* it does not. |
| m21 | Finalize orchestrator port. Introduced `internal/finalize/shim.go:buildEnv` with a hand-curated env (`MILESTONE_MODE`, `_CURRENT_MILESTONE`, `LOG_DIR`, `TIMESTAMP`). First place outside legacy bash to assemble bash globals from Go. |
| m22 | Preflight port. Preflight is the only Phase 5 subsystem whose bash bodies fully ported, so it does not exercise the env contract — but it sets the pattern for "subsystem ports cleanly when the contract surface is small." Phase 5 ports after m22 (m23–m25) all run bash, so they need a working env contract before they can dogfood. |
| **m26** | **Single typed env contract spanning config + runtime flags; consumed identically by stagerunner and finalize.** |
| m27 | Bash defensive sweep + audit/parity gates that prevent regression of the contract. m26 is the producer side; m27 is the consumer-side hardening. |

---

## Design

### Sequencing note

m26 must land before m23 / m24 / m25. Those Phase 5 ports each touch bash code paths that read pipeline.conf globals; landing them before m26 means each dogfood run risks the same unbound-variable cascade we already paid down once in `85b00ac`. Adjust MANIFEST.cfg's `depends_on` columns for m23–m25 as part of m26 closeout so the dependency is enforced by the manifest, not just narrative.

m26 must land *after* m22 because the env contract has to compose preflight env too, and m22 settled preflight's surface area (the `internal/preflight/` package now has stable inputs + a Cobra subcommand that may itself consume the env contract via `tekhton preflight --project-dir`). Landing the contract before m22 would have meant porting it twice.

### Discovery from the m20–m22 dogfood retrospective

During the m26 drafting pass we verified — by direct inspection of the repository at `1fb446e` (m22 close) — that **no V4 milestone-mode pipeline pass has ever actually completed end-to-end**. The relevant evidence:

- `scripts/self-host-check.sh` at m22-close contains 15 scenarios, all of which call `_assert_routes_to_run` — a helper that asserts the bash dispatcher *forwards* an invocation to `tekhton run`, with a fake binary in `FAKE_BIN_DIR`. It does **not** execute the pipeline. Routing parity is verified; pipeline parity is not.
- `internal/runner/single.go:buildPipelineRequest` at m22-close has no `StageEnv` population — every stage subprocess launched by the Go runner inherits parent env only, with no `MILESTONE_MODE`, no `_CURRENT_MILESTONE`, no `TASK`, and none of `pipeline.conf`'s globals.
- `lib/intake_helpers.sh:191` at m22-close reads `"$MILESTONE_MODE"` with no default, under `set -euo pipefail`. Any milestone-mode run that reaches `_intake_get_milestone_content` crashes immediately on the unbound variable.
- A real user invocation — `tekhton --milestone M26` from `/home/geoff/workspace/geoffgodwin/tekhton-stable` at `1fb446e` — reproduces the crash cascade (intake → `MILESTONE_MODE`; finalize → `LOG_FILE`; metrics hook → missing `_collect_extended_stage_vars` / `_sanitize_numeric`). The pipeline records `disposition=failure attempts=1 agent_calls=0 elapsed=0s recovery=save_exit` — no agent ever ran.

**Implication for m26's scope.** The acceptance criteria below now require a *real* pipeline parity test that runs `tekhton run --milestone <fixture> --no-tui` against a fixture project and asserts intake/coder/security/review/tester subprocesses all execute without `unbound variable` or `command not found` stderr. The bar moves from "the env builder compiles and round-trips its struct" to "a milestone pipeline run reaches the finalize stage on a fixture project." This is the verification step m20/m21/m22 should have done and didn't.

**Implication for prior-milestone status.** m20/m21/m22 remain `done` in the manifest — their narrow acceptance criteria (dispatcher routing, finalize hook orchestration, preflight check ports) were met. But the "implementation run is itself driven by `tekhton run --milestone mXX --complete`" criterion on those milestones was never honoured in practice; it was satisfied by routing verification rather than pipeline execution. m26 closes that gap retroactively. Future Phase 5 milestones must include the same pipeline parity test in their acceptance criteria — see m27's Watch For section for the codified rule.

### Goal 1 — `StageEnvV1` proto

`internal/proto/stage_env.go` declares the versioned env contract:

```go
package proto

// StageEnvProtoV1 is the wire identifier for the v1 stage/finalize env
// contract. Bumped whenever a field's meaning changes; new fields are
// additive within v1.
const StageEnvProtoV1 = "stage_env.v1"

// StageEnvV1 is the typed view of the bash subprocess env that
// internal/runner/env.go composes from config + run-request flags.
// The serialised form is a flat string→string map (the underlying bash
// subprocess only sees env strings); StageEnvV1 exists so the producer
// and consumer agree on field names and zero values.
type StageEnvV1 struct {
    Proto string `json:"proto"`

    // Runtime flag globals — sourced from the run request, not pipeline.conf.
    MilestoneMode    bool   `json:"milestone_mode"`
    CurrentMilestone string `json:"current_milestone,omitempty"`
    Task             string `json:"task,omitempty"`
    AutoAdvance      bool   `json:"auto_advance"`
    AutoAdvanceLimit int    `json:"auto_advance_limit,omitempty"`
    HumanMode        bool   `json:"human_mode"`
    HumanNotesTag    string `json:"human_notes_tag,omitempty"`

    // Log channel — synthesized once per run.
    LogDir    string `json:"log_dir,omitempty"`
    LogFile   string `json:"log_file,omitempty"`
    Timestamp string `json:"timestamp,omitempty"`

    // ConfigKeys is the K→V map emitted by config.EmitShell — every
    // pipeline.conf key the m16 loader exposes, including defaults.
    ConfigKeys map[string]string `json:"config_keys,omitempty"`
}
```

The struct is the producer/consumer contract. Both sides (`internal/runner/env.go` building, `internal/stagerunner/adapter.go` + `internal/finalize/shim.go` consuming) reference it so a new field is one obvious edit and a test failure if either side forgets.

### Goal 2 — `internal/runner/env.go` builder

```go
package runner

import (
    "github.com/geoffgodwin/tekhton/internal/config"
    "github.com/geoffgodwin/tekhton/internal/proto"
)

// EnvBuilder composes the stage/finalize subprocess env from three layers:
//   1. ProjectConfig — pipeline.conf values via internal/config.
//   2. Request flags  — fields on RunRequestV1 that bash globals shadow.
//   3. Overrides       — explicit caller overrides (test seams, advanced
//                        per-stage configs from PipelineAttemptRequestV1).
//
// Builders are cheap; the Runner holds one per active run so the config
// load happens exactly once.
type EnvBuilder struct {
    cfg     *config.Config // nil ⇒ defaults-only path
    log     LogContext
}

// LogContext is the single authoritative spot for log path synthesis.
// Replaces the ad-hoc string-join in internal/finalize/shim.go.
type LogContext struct {
    Dir       string
    File      string // LogDir / TimestampTaskSlug.log
    Timestamp string
}

func NewEnvBuilder(cfg *config.Config, log LogContext) *EnvBuilder { ... }

// Compose returns the env contract for a single subprocess. Stage and
// finalize call this with their respective overlay.
func (b *EnvBuilder) Compose(req *proto.RunRequestV1, overrides map[string]string) *proto.StageEnvV1 { ... }

// AsKV flattens StageEnvV1 to bash-style "KEY=value" lines, ready to
// hand to exec.Cmd.Env. ConfigKeys are passed through verbatim (already
// shell-quoted by config.EmitShell on the producer side).
func (b *EnvBuilder) AsKV(env *proto.StageEnvV1) []string { ... }
```

`Compose` is pure (no I/O); `Runner.New` does the one-time `config.Load` and caches the result on the receiver.

### Goal 3 — Wire builder into stagerunner

`internal/runner/single.go:buildPipelineRequest` and `internal/pipeline/runner.go:runStage` cooperate today to populate `StageRequestV1.EnvOverrides`. After m26 the chain becomes:

```go
// internal/runner/single.go
func (r *Runner) buildPipelineRequest(req *proto.RunRequestV1) *proto.PipelineAttemptRequestV1 {
    base := r.env.Compose(req, nil)
    return &proto.PipelineAttemptRequestV1{
        Proto:      proto.PipelineAttemptRequestProtoV1,
        Task:       req.Task,
        Milestone:  req.Milestone,
        Order:      defaultStageOrder(),
        ProjectDir: req.ProjectDir,
        StageEnv:   stageEnvMap(base, defaultStageOrder()), // maps every stage to the same composed env
    }
}
```

`stageEnvMap` keeps the per-stage map shape `PipelineAttemptRequestV1.StageEnv` expects today, but every stage gets the full composed env — no more curated subsets. `internal/stagerunner/adapter.go:buildEnv` continues to layer parent env, then overrides; the contract changes are upstream of the adapter.

The hand-coded `buildStageEnv` from `85b00ac` deletes — it is folded into `EnvBuilder.Compose`.

### Goal 4 — Wire builder into finalize/shim

`internal/finalize/shim.go:buildEnv` today hand-rolls `MILESTONE_MODE`, `_CURRENT_MILESTONE`, `LOG_DIR`, `TIMESTAMP`, and the `LOG_FILE` synthesis from `85b00ac`. After m26:

```go
// internal/finalize/shim.go
func (b *BashShimHook) buildEnv(in *Input) []string {
    base := b.envBuilder.Compose(in.RunRequest, map[string]string{
        "PIPELINE_EXIT_CODE":      strconv.Itoa(in.ExitCode),
        "TEKHTON_RUN_DISPOSITION": in.Disposition,
        "_CACHED_DISPOSITION":     in.MilestoneDisposition,
    })
    return b.envBuilder.AsKV(base)
}
```

`Input` grows a `RunRequest *proto.RunRequestV1` field so finalize hooks see the same contract stage hooks did. The orchestrator (`internal/finalize/orchestrator.go`) plumbs the run request through `runner.New` → `finalize.NewOrchestrator` → per-hook `Input`.

`LOG_FILE` synthesis moves out of `shim.go` into `LogContext.synthesize(req)` in `env.go`, so a future direct caller (e.g. m27's parity test) gets the same path the live pipeline does. The path format stays `${LogDir}/${Timestamp}_${task_slug}.log` to keep bytewise compatibility with grep-based log scrapers.

### Goal 5 — Defaults-only fallback

`config.Load` returns an error when `pipeline.conf` is missing or unparseable. The runner must not crash on a half-configured project — preflight handles that as a `Fail` finding, and the user expects to see the preflight banner, not a Go panic.

```go
// internal/runner/runner.go
func New(pipe *pipeline.Runner) *Runner {
    r := &Runner{pipe: pipe}
    cfg, err := config.Load(filepath.Join(r.ProjectDir, ".claude", "pipeline.conf"),
        config.LoadOptions{DefaultsOnly: errors.Is(err, fs.ErrNotExist)})
    if err != nil && !errors.Is(err, fs.ErrNotExist) {
        // Surface as a structured error the dispatcher converts to a clean
        // banner; do not panic.
        r.configErr = err
    }
    r.env = NewEnvBuilder(cfg, LogContext{...})
    return r
}
```

If `cfg` is nil (load failure), `EnvBuilder.Compose` populates only the run-request fields and a `ConfigKeys` map sized to the defaults set (`config.Config.LoadDefaultsOnly`). This is the "bare directory" path my `/tmp/tekhton-test` runs hit today — it should warn-and-continue, not crash.

### Goal 6 — Cobra wiring

`cmd/tekhton/run.go:buildRunner` already constructs `*runner.Runner`. Add the env builder construction inline:

```go
r := runner.New(pipe)
r.Env = runner.NewEnvBuilder(cfg, runner.LogContext{
    Dir:       pipeOpts.LogDir,
    Timestamp: ts.Format("20060102_150405"),
})
```

No new flags exposed at the CLI surface — the env contract is internal plumbing.

### Goal 7 — Documentation

`docs/v4-env-contract.md` (new) documents the contract for future port milestones:

- The `StageEnvV1` field list (table form).
- The producer/consumer split.
- The "every stage in `defaultStageOrder()` sees the full env" rule.
- A "How to add a new bash global" recipe: add field to `StageEnvV1`, populate in `EnvBuilder.Compose`, add a test in `env_test.go` asserting the new field appears in every consumer's env.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/proto/stage_env.go` | Create | `StageEnvV1` typed contract. |
| `internal/proto/stage_env_test.go` | Create | Round-trip tests (struct → KV → struct) and proto-version constant. |
| `internal/runner/env.go` | Create | `EnvBuilder` + `LogContext` + `Compose` + `AsKV`. |
| `internal/runner/env_test.go` | Create | Layered-merge tests: config-only, request-only, override-only, all three combined. Defaults-only path covered. |
| `internal/runner/runner.go` | Modify | `Runner` gains `Env *EnvBuilder` and a one-time `config.Load` in `New`. |
| `internal/runner/single.go` | Modify | `buildPipelineRequest` calls `r.Env.Compose`; the `buildStageEnv` helper from `85b00ac` deletes. |
| `internal/finalize/shim.go` | Modify | `BashShimHook` gains `envBuilder *runner.EnvBuilder` (or an interface); `buildEnv` swaps to `Compose + AsKV`. `LOG_FILE` synthesis deletes here. |
| `internal/finalize/hook.go` | Modify | `Input` gains `RunRequest *proto.RunRequestV1`. |
| `internal/finalize/orchestrator.go` | Modify | Plumbs the run request through to each hook `Input`. |
| `cmd/tekhton/run.go` | Modify | `buildRunner` wires the env builder onto the runner. |
| `cmd/tekhton/run_test.go` | Modify | Add a smoke test that asserts the env builder is non-nil after `buildRunner`. |
| `docs/v4-env-contract.md` | Create | Producer/consumer contract reference + "how to add a global" recipe. |
| `.claude/milestones/MANIFEST.cfg` | Modify | Add `m26|Stage and Finalize Env Contract|todo|m22|m26-stage-env-contract.md|phase5`; update `m23`/`m24`/`m25` `depends_on` to include `m26`. |

---

## Acceptance Criteria

- [ ] `internal/proto/stage_env.go` declares `StageEnvV1` with the field set listed in Goal 1; `StageEnvProtoV1 = "stage_env.v1"`.
- [ ] `internal/runner/env.go` exposes `NewEnvBuilder`, `(*EnvBuilder).Compose`, `(*EnvBuilder).AsKV`. Each function has at least one `_test.go` covering the happy path.
- [ ] `internal/runner/env_test.go:TestComposeLayering` asserts the three-layer precedence: overrides beat request flags beat config keys.
- [ ] `internal/runner/env_test.go:TestComposeDefaultsOnly` asserts `Compose` returns a populated `StageEnvV1` (run-request fields + `config.DefaultsOnly` ConfigKeys) when `pipeline.conf` is absent — no panic, no nil deref.
- [ ] `internal/runner/single.go:buildPipelineRequest` no longer contains a `buildStageEnv` helper or inline `MILESTONE_MODE`/`TASK` assignments — grep for those literals returns zero matches in `single.go`.
- [ ] `internal/finalize/shim.go:buildEnv` no longer hand-rolls `MILESTONE_MODE` / `_CURRENT_MILESTONE` / `LOG_FILE` — grep for those literals returns zero matches in `shim.go`. They appear once each in `env.go`.
- [ ] Every stage returned by `defaultStageOrder()` receives the same composed env: a new test `TestStageEnvUniformity` constructs a `PipelineAttemptRequestV1` via `buildPipelineRequest` and asserts the set of keys is identical across all stages.
- [ ] Every finalize hook receives the same env: extend `internal/finalize/shim_test.go` with a `TestShimEnvHasContract` that asserts every key in `StageEnvV1.ConfigKeys` plus the runtime-flag set is present.
- [ ] **End-to-end pipeline parity test.** `tests/test_v4_pipeline_e2e.sh` runs `tekhton run --milestone fixturems --no-tui --dry-run` against a fixture project (`tests/testdata/env_contract/`) and asserts: (a) every stage in `defaultStageOrder()` produces a `stage.result.v1` envelope on disk — verified by `find tests/testdata/env_contract/.tekhton/stage_results -name '*.json' | wc -l` ≥ 5; (b) stderr contains zero `unbound variable` lines (`grep -c 'unbound variable' stderr.log` returns 0); (c) stderr contains zero `command not found` lines for any function defined in `lib/*.sh`; (d) the run reaches finalize (verified by RUN_RESULT.json having `Disposition != "save_exit"` or the equivalent on the new path). This is the test m20/m21/m22 lacked. The fixture's `pipeline.conf` populates every key from `internal/config/defaults.go` so a `set -u` crash in any stage surfaces here.
- [ ] **Pipeline parity, not just routing.** `scripts/self-host-check.sh` gains a sixteenth scenario that does **not** use `_assert_routes_to_run` — it execs the real `bin/tekhton` against the env-contract fixture and asserts pipeline completion. Routing-only verification was the m20–m22 gap; we close it here.
- [ ] `make dogfood` exits 0 (self-host parity matrix still green).
- [ ] `go test ./internal/runner/... ./internal/finalize/... ./internal/proto/... ./cmd/tekhton/...` passes.
- [ ] `bash tests/run_tests.sh` reports zero new failures vs the m22-close baseline.
- [ ] `docs/v4-env-contract.md` exists and lists every field in `StageEnvV1` plus a "How to add a new bash global" recipe.
- [ ] `VERSION` reads `4.26.0` on milestone close.
- [ ] `.claude/milestones/MANIFEST.cfg` contains the row `m26|Stage and Finalize Env Contract|done|m22|m26-stage-env-contract.md|phase5` and `m23`/`m24`/`m25` `depends_on` columns include `m26`.
- [ ] The implementation run is itself driven by `tekhton run --milestone m26 --complete` — m26 is the fourth dogfooded V4 milestone, continuing the m21/m22 precedent.

## Watch For

- **Config load is a one-shot, not a hot path.** `config.Load` reads the file, applies defaults, and returns. Calling it per-stage would multiply file I/O by N stages and risk stale cache on long-running `--complete` loops. Cache on `Runner` and re-read only on explicit invalidation (none today — defer until a milestone needs it).
- **`AsKV` must shell-quote config values.** `config.EmitShell` already shell-quotes when it emits to stdout (`internal/config/emit.go:shellQuote`). When `AsKV` flattens `ConfigKeys` to a `KEY=value` slice for `exec.Cmd.Env`, **do not re-quote** — `exec.Cmd.Env` is not a shell; it's a `[]string` of `KEY=value` pairs passed directly to `execve`. Re-quoting will double-quote and break stage subprocess reads. Test fixture must include a config value with a literal apostrophe to catch this.
- **Defaults-only path is not a happy path.** It runs only when `pipeline.conf` is missing or unparseable; preflight should be flagging this as a `Fail`. Don't silently mask preflight by gracefully running with defaults — surface a warning to stderr ("env: pipeline.conf not found, running with defaults — preflight should fail") so operators see what's happening.
- **`finalize.Input.RunRequest` is a forward-leaning addition.** Today most hooks ignore it. m27 will lean on it for the parity test (replay a known request and assert env shape). Don't optimize it away as "unused" before m27 lands.
- **`StageEnvV1` is not a serialization contract for inter-process communication.** It's the Go-side typed view of the env. The bash subprocess only sees flat `KEY=value` env vars. If a future milestone wants to JSON-serialise the env for, e.g., a remote sandbox, that's a separate `stage_env.v2` design conversation.
- **Do not pre-port m23 / m24 / m25 work into m26.** Those milestones each have their own ports — m26's job is the contract, not the consumers. If during implementation you discover a TUI / notes / drift hook that needs a new field, add the field to `StageEnvV1` and stop; do not port the hook.
- **"Dogfooded" must mean the pipeline executed, not that dispatch routed.** m20–m22 each claimed dogfooding via `tekhton run --milestone mXX --complete` while their self-host gates only verified routing. m26's parity test is the new floor: every Phase 5+ port milestone must include a fixture-based pipeline-completion test before close. Routing tests are still valuable (they catch dispatcher regressions cheaply) but they are no longer sufficient.
- **The fixture project must populate `pipeline.conf` from `internal/config/defaults.go`, not from defaults baked into the test.** If the fixture's `pipeline.conf` drifts from the loader's known keys, a future config-key addition silently bypasses the parity test. Generate the fixture's `pipeline.conf` from `tekhton config defaults --emit shell` in a one-time bootstrap script (`tests/testdata/env_contract/bootstrap.sh`) so regenerating it is one command, and add an audit-time check that the fixture matches what the loader would emit today.

## Seeds Forward

- **m27 — Bash subprocess hardening + audit:** Lands the consumer-side defensive `${VAR:-default}` sweep and the audit/parity gates that lock the contract. m26 produces the env; m27 ensures every bash file consumes it safely and CI catches future regressions.
- **m23 / m24 / m25:** Inherit the env contract as the foundation for their dogfooded ports. Each can add fields to `StageEnvV1` if they need a new global — the recipe in `docs/v4-env-contract.md` is the entry point. Acceptance criteria for those milestones should include "no unbound-variable cascade" once m27's parity test exists.
- **`tekhton config validate` extension:** m16's `config validate` subcommand checks for missing keys. After m26, it can additionally check that every key the bash side reads (per m27's audit grep) appears in the loader's known-keys set. That closes the loop between producer (env builder) and consumer (bash scripts) at validate time, not just at run time.
- **Remote / parallel execution (V5 stub):** `DESIGN_v5.md` Risk §3 calls out env propagation across machine boundaries. m26's `StageEnvV1` is the in-process shape; V5 will need a wire-format extension that survives serialization. Worth shaping the JSON tags now so V5 doesn't fork the struct.
