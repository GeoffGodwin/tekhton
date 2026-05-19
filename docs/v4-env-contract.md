# V4 Stage / Finalize Env Contract

`StageEnvV1` (m26) is the typed Go-side view of the bash subprocess
environment every Tekhton pipeline stage and every finalize hook
receives. One contract, one producer, two consumer surfaces — so the
bash side can stop guessing which globals reached it.

## Why this exists

Before m26, the bash subprocess env was assembled inline at two
different points:

- `internal/runner/single.go:buildStageEnv` — per stage, hand-curated
  in commit `85b00ac` as a reactive patch.
- `internal/finalize/shim.go:buildEnv` — per finalize hook, also
  hand-curated.

Each surface named its own subset of the bash globals the V3 pipeline
set at flag-parse / config-source time. The subsets drifted. Every
bash file under `lib/` and `stages/` that read a runtime global the
curated subset hadn't named tripped `set -u` and the subprocess
exited 1 inside the runner. The m20–m22 retrospective in
`.claude/milestones/m26-stage-env-contract.md` documents the gap:
**no V4 milestone-mode pipeline pass had ever completed end-to-end**.

m26 closes it with a single typed contract composed once per run and
consumed identically by every stage and every finalize hook.

## The contract

`StageEnvV1` lives in `internal/proto/stage_env.go`. Three field
groups:

| Group | Fields | Source |
|---|---|---|
| Runtime flags | `MilestoneMode`, `CurrentMilestone`, `Task`, `AutoAdvance`, `AutoAdvanceLimit`, `HumanMode`, `HumanNotesTag` | The `RunRequestV1` envelope built from CLI flags. |
| Log channel | `LogDir`, `LogFile`, `Timestamp` | Synthesized once per run by `runner.LogContext`. Mirrors the bash `LOG_FILE` shape (`${LogDir}/${Timestamp}_${task_slug}.log`) for parity with log scrapers. |
| `ConfigKeys` | Every resolved key from `pipeline.conf` | `internal/config.Config.Values`. Passed through verbatim — NOT shell-quoted. |

`StageEnvProtoV1 = "tekhton.stage_env.v1"`. New fields within v1 are
additive; a change to an existing field's meaning bumps the proto tag.

## Producer

`runner.EnvBuilder` (in `internal/runner/env.go`) composes
`StageEnvV1` from three layers, each beating the one before it:

1. **Project config** — `pipeline.conf` values via `config.Load`.
   Cached once per `Runner`.
2. **Run-request flags** — fields on `RunRequestV1` that the legacy
   pipeline set at flag-parse time.
3. **Caller overrides** — per-stage maps or test seams.

```go
b := runner.NewEnvBuilder(cfg, runner.LogContext{
    Dir:       filepath.Join(projectDir, ".claude", "logs"),
    Timestamp: time.Now().UTC().Format("20060102_150405"),
})
env := b.Compose(req, nil)        // *proto.StageEnvV1
kv  := b.AsKV(env)                // []string of "KEY=value" lines
```

`Compose` is pure (no I/O). `AsKV` flattens to a deterministic,
sorted slice ready for `exec.Cmd.Env`. **`AsKV` does not shell-quote**
because `exec.Cmd.Env` is passed directly to `execve`, not interpreted
by a shell.

## Consumers

| Surface | How it consumes |
|---|---|
| Stage dispatcher | `internal/runner/single.go:buildPipelineRequest` calls `r.envBuilder().Compose(req, nil)` once per attempt and applies the result uniformly to every stage in `defaultStageOrder()`. The `PipelineAttemptRequestV1.StageEnv` map carries it. |
| Finalize chain | `runner.BashHookRunner.Finalize` composes the env once and assigns it to `finalize.Input.EnvKV`. `BashShimHook.buildEnv` appends per-hook keys (`PIPELINE_EXIT_CODE`, `TEKHTON_RUN_DISPOSITION`, `_CACHED_DISPOSITION`) on top before exec. |

Every stage and every finalize hook sees the same composed env, plus
the disposition keys finalize layers on top. Adding a new bash file
that reads `MILESTONE_MODE` or `TASK` requires no changes to the
dispatcher — the contract already covers it.

## Defaults-only path

`config.Load` may fail (missing `pipeline.conf`, parse error). The
runner does NOT panic — it warns to stderr and constructs the builder
with `cfg = nil`. `Compose` then produces only the runtime-flag
fields and a nil `ConfigKeys` map. Preflight is the layer responsible
for flagging the bare-directory case as a `Fail`; the runner refuses
to silently mask that diagnostic by refusing to start.

The warning line:

```
env: pipeline.conf not loadable, running with defaults — preflight should fail: ...
```

## How to add a new bash global

Adding a new bash global the stage / finalize subprocess should see:

1. **Add the field to `StageEnvV1`** in
   `internal/proto/stage_env.go` with the right JSON tag.
2. **Populate it in `EnvBuilder.Compose`** in
   `internal/runner/env.go`. Pull from `req` or `b.cfg` depending on
   the source.
3. **Emit it in `EnvBuilder.AsKV`** in the same file — the runtime-flag
   block if it's always present, or the conditional block if optional.
4. **Add a test in `env_test.go`** asserting the new field appears in
   the AsKV output for the relevant request shape. Pattern-match on
   the existing `TestAsKV_RuntimeFlagsAlwaysExported` for required
   flags or `TestCompose_LayeringOverridesBeatConfig` for config keys.

No other surface needs editing — `single.go:buildPipelineRequest` and
`finalize/shim.go:buildEnv` already feed every stage and every hook
from the same builder.

## Boundaries

- **`StageEnvV1` is not an inter-process wire format.** It's the Go
  typed view of the env. The bash subprocess only sees flat
  `KEY=value` strings via `execve`. A future milestone that needs
  inter-process env serialization (remote sandbox, parallel
  execution) is a separate `stage_env.v2` design conversation.
- **Per-stage advanced overrides** still ride on
  `PipelineAttemptRequestV1.StageEnv[stage]`. The contract guarantees
  every stage sees the *base* composed env; a stage-specific
  override layers on top.
- **Finalize-only keys** (`PIPELINE_EXIT_CODE`, `_CACHED_DISPOSITION`)
  stay in `finalize/shim.go`. They're disposition-shaped, not run-
  request-shaped, so they don't belong on `StageEnvV1`.
