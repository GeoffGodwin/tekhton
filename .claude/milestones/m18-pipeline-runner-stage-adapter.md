<!-- milestone-meta
id: "18"
status: "done"
-->

# m18 — Pipeline Runner + Stage Adapter

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 4 — first wedge of the second batch (m18→m20), the cut that flips "who runs the pipeline." After m12 the *recovery classifier* moved to Go but `_run_pipeline_stages` (the per-attempt scheduler in `lib/orchestrate_iteration.sh`) and `lib/gates.sh` (build gate + completion gate) still drive the actual pipeline in bash. Until those flip, `tekhton.sh` is the orchestrator and the Go binary is a library it calls. m18 inverts that relationship for one pipeline attempt. |
| **Gap** | Today the per-attempt loop lives in `lib/orchestrate_iteration.sh::_run_pipeline_stages` (~286 LOC), which sources `stages/intake.sh`, `stages/coder.sh`, `stages/security.sh`, `stages/review.sh`, `stages/tester.sh` and calls `run_stage_<name>` directly with shared bash globals. Build gate and completion gate (`lib/gates.sh`, 217 LOC) are sourced by stages and orchestrate alike. There is no envelope contract between Go and a stage — a Go runner cannot invoke a stage without re-doing all the bash sourcing. |
| **m18 fills** | (1) `internal/stagerunner/` package with a `BashAdapter` that exec's `bash -c "source lib/common.sh; source stages/<name>.sh; run_stage_<name>"` with a JSON request envelope and parses a `stage.result.v1` envelope from a results file. (2) Each `stages/*.sh` gets a ~30-line tail that, when `TEKHTON_STAGE_RESULT_FILE` is set, emits its disposition (verdict, exit reason, agent calls, files touched, next-action hint) as JSON. Existing `run_stage_*` bodies untouched. (3) `internal/pipeline/` package with `RunAttempt(ctx, req) (*AttemptResult, error)` — the per-attempt scheduler that calls stages in `PIPELINE_ORDER` and applies build/completion gates. (4) `internal/pipeline/gates.go` — port of `lib/gates.sh`. (5) `cmd/tekhton/run_stage.go` and `cmd/tekhton/pipeline.go` expose the new entry points. (6) `lib/gates.sh` and `lib/orchestrate_iteration.sh` are deleted; their callers (still bash for now: `lib/orchestrate_main.sh`, finalize hooks) call `tekhton pipeline …` instead. |
| **Depends on** | m12, m13, m14, m17 |
| **Files changed** | `internal/stagerunner/` (new), `internal/pipeline/` (new), `internal/proto/stage_v1.go` (new), `internal/proto/pipeline_v1.go` (new — extends m12's `attempt.request.v1`), `cmd/tekhton/run_stage.go` (new), `cmd/tekhton/pipeline.go` (new), `stages/intake.sh` / `coder.sh` / `security.sh` / `review.sh` / `tester.sh` / `cleanup.sh` / `docs.sh` (modify — envelope tail), `lib/gates.sh` (delete), `lib/orchestrate_iteration.sh` (delete), `lib/orchestrate_main.sh` (modify — call `tekhton pipeline run-attempt` instead of `_run_pipeline_stages`), `scripts/pipeline-parity-check.sh` (new), `scripts/wedge-audit.sh` (modify — add Phase 4 batch 2 patterns) |
| **Stability after this milestone** | Stable. The per-attempt scheduler runs in Go; the outer `--complete` loop is still bash but only because m19 hasn't landed yet. Stages run as bash subprocesses with explicit envelopes — a clean seam. |
| **Dogfooding stance** | Cutover within the milestone. The bash callers of `_run_pipeline_stages` and `run_build_gate` / `run_completion_gate` migrate to `tekhton pipeline run-attempt` in this same milestone — no parallel paths. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m12 | Recovery classifier moved to Go; `run_complete_loop` still bash. |
| m17 | Common error sentinels (`ErrTransient`, `ErrFatal`, …) for cross-package use. |
| **m18** | **Per-attempt scheduler + gates move to Go; stages stay bash with envelope contract.** |

---

## Design

### Sequencing note

m18 is the first milestone where Go drives bash via subprocess at the *stage* boundary (m02/m03/m13/m15/m16/m17 drove bash via subprocess at the *function-call* boundary). The `BashAdapter` pattern established here is the template m19 reuses for finalize and m20 reuses for the TUI bridge. Get the envelope schema right — it's load-bearing for the rest of Phase 4.

The stage envelope is intentionally narrower than the agent envelope (`agent.response.v1` from m05). Stages are coarse-grained: one stage = many agent calls + many bash actions. The envelope captures *outcomes*, not the per-agent trace (that's already in `CAUSAL_LOG.jsonl`).

### Goal 1 — Stage envelope contract

`internal/proto/stage_v1.go`:

```go
package proto

type StageRequestV1 struct {
    Proto         string            `json:"proto"`           // "stage.request.v1"
    Stage         string            `json:"stage"`           // "intake" | "coder" | "security" | "review" | "tester" | "cleanup" | "docs"
    Task          string            `json:"task"`
    Milestone     string            `json:"milestone,omitempty"`
    ReviewCycle   int               `json:"review_cycle"`
    BuildAttempt  int               `json:"build_attempt"`   // for coder reruns under build-gate retry
    EnvOverrides  map[string]string `json:"env_overrides"`   // EFFECTIVE_*_MAX_TURNS, etc.
    ResultFile    string            `json:"result_file"`     // path the stage writes to
    LogFile       string            `json:"log_file"`        // tee target
}

type StageResultV1 struct {
    Proto         string   `json:"proto"`           // "stage.result.v1"
    Stage         string   `json:"stage"`
    Verdict       string   `json:"verdict"`         // "pass" | "fail" | "rework" | "block" | "skip"
    ExitReason    string   `json:"exit_reason"`
    AgentCalls    int      `json:"agent_calls"`
    FilesTouched  []string `json:"files_touched"`
    NextAction    string   `json:"next_action,omitempty"`  // for review: "rework" | "approve"; for tester: "fix" | "pass"
    DurationSec   int      `json:"duration_sec"`
    HumanAction   bool     `json:"human_action_required"`
    Error         string   `json:"error,omitempty"`
}
```

Each `stages/*.sh` gets a small tail block (extracted into a shared helper in `lib/stage_envelope.sh` to avoid duplication):

```bash
# stages/<name>.sh — appended at file bottom
emit_stage_envelope() {
    local result_file="${TEKHTON_STAGE_RESULT_FILE:-}"
    [[ -z "$result_file" ]] && return 0
    "${TEKHTON_BIN:-tekhton}" stage emit \
        --stage "$1" \
        --verdict "$2" \
        --exit-reason "$3" \
        --agent-calls "${4:-0}" \
        --duration "${5:-0}" \
        --next-action "${6:-}" \
        > "$result_file"
}
```

`tekhton stage emit` is a tiny new subcommand (in `cmd/tekhton/stage.go`) that constructs the JSON. This avoids hand-rolling JSON in bash and avoids depending on `jq` being present.

`run_stage_<name>` callers set `verdict`/`exit_reason` near their existing return paths, then call `emit_stage_envelope` once at the end. The diff per stage is small (~20 lines).

### Goal 2 — `internal/stagerunner` package

```go
package stagerunner

type Adapter interface {
    Run(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error)
}

type BashAdapter struct {
    TekhtonHome string
    ProjectDir  string
    StageScript map[string]string  // "intake" -> "stages/intake.sh", etc.
}

func (a *BashAdapter) Run(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
    // 1. Write request to a temp file the stage can read.
    // 2. exec.CommandContext("bash", "-c", "source lib/common.sh; source stages/<name>.sh; run_stage_<name>")
    //    with TEKHTON_STAGE_REQUEST_FILE / TEKHTON_STAGE_RESULT_FILE env, plus EnvOverrides.
    // 3. Stream stdout/stderr to the log file.
    // 4. Read and decode the result file.
    // 5. Translate non-zero exit + missing envelope into a stage.result.v1 with verdict="fail".
}
```

The adapter uses `os/exec` directly (not the `internal/supervisor` retry wrapper — stages are heavier-weight than agent calls and don't share the same retry semantics; a stage that crashes is a pipeline failure, not a transient).

SIGINT and parent-context cancellation propagate via `exec.CommandContext` — same pattern as m06.

### Goal 3 — `internal/pipeline` package

```go
package pipeline

type Runner struct {
    Stages    stagerunner.Adapter
    State     *state.Store
    Causal    *causal.Log
    Cfg       config.Resolved
    Order     []string  // from PIPELINE_ORDER
}

func (r *Runner) RunAttempt(ctx context.Context, req *proto.AttemptRequestV1) (*proto.AttemptResultV1, error) {
    // For each stage in r.Order:
    //   - If stage == "coder": invoke build-gate retry loop (gates.go)
    //   - If stage == "review": invoke review rework cycle (loops on stage.NextAction == "rework")
    //   - If stage == "tester": invoke completion gate after success
    //   - Otherwise: single invocation
    //   - On fail/block: short-circuit, return AttemptResult
    // Apply rework routing per CAUSAL_LOG.
    // Emit causal events at stage boundaries.
}
```

The review rework cycle (loop while `verdict == "rework" && cycle < MAX_REVIEW_CYCLES`) is the trickiest piece. Today it's interleaved with `run_stage_review` in bash. m18 moves the *cycle counter* to Go and re-invokes the review stage with `ReviewCycle: n+1`; the stage itself stays bash and its internal rework prompt logic stays bash.

The coder build-gate retry loop is in `gates.go` (next goal).

### Goal 4 — `internal/pipeline/gates.go`

Port of `lib/gates.sh`:

```go
type BuildGate struct {
    AnalyzeCmd      string
    MaxRetries      int
    RemediationFn   func(ctx, attempt int) error  // hook for the M127/M128 build-fix loop
}

func (g *BuildGate) Run(ctx context.Context, attempt int) (verdict string, err error)

type CompletionGate struct {
    TestCmd    string
    Strict     bool   // TEST_BASELINE_PASS_ON_PREEXISTING semantics
}

func (g *CompletionGate) Run(ctx context.Context) (verdict string, err error)
```

The build-fix continuation loop (M128, currently in `stages/coder_buildfix.sh`) stays as bash — it's a sub-stage of coder, lives inside `run_stage_coder`, and is invoked by the coder stage itself. The build *gate* (does the build pass? if not, route to coder rework) is what moves to Go.

`EFFECTIVE_CODER_MAX_TURNS` resets and the M91 escalation logic stay coordinated through `proto.AttemptRequestV1.EnvOverrides` — Go writes them, the bash stage reads them via the env-overrides envelope.

### Goal 5 — Bash deletions and shim points

| Bash file | Disposition |
|-----------|-------------|
| `lib/gates.sh` | Delete. Single bash caller (`lib/orchestrate_main.sh`) migrates to `tekhton pipeline run-attempt`. |
| `lib/orchestrate_iteration.sh` | Delete. `_handle_pipeline_success` and `_handle_pipeline_failure` move to `internal/pipeline/handlers.go`; `_run_pipeline_stages` is replaced by `RunAttempt`. |
| `lib/orchestrate_main.sh` | Modify. `run_complete_loop` continues to exist (m19 ports it) but its inner `_run_pipeline_stages` call becomes `tekhton pipeline run-attempt --request-file …`. |
| `lib/orchestrate.sh` | No change — it sources `orchestrate_main.sh`, which still exists. |

### Goal 6 — Parity gate

`scripts/pipeline-parity-check.sh` runs six scenarios against fixtures in `testdata/pipeline-parity/`:

1. Happy path (intake → coder → security → review → tester → completion gate, no retries).
2. Build gate retries once then succeeds.
3. Review returns `rework`, coder reruns, review approves second cycle.
4. Security blocks (HIGH severity finding).
5. Tester fails with pre-existing baseline failure (auto-pass per `TEST_BASELINE_PASS_ON_PREEXISTING`).
6. Completion gate skipped because `PIPELINE_ORDER=test_first`.

Each scenario runs once with the legacy bash path (recorded under `testdata/pipeline-parity/expected/`) and once with `tekhton pipeline run-attempt`. The parity gate diffs the resulting `RUN_SUMMARY.json` and `CAUSAL_LOG.jsonl` (after sort + timestamp normalization).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/stagerunner/adapter.go` | Create | `Adapter` interface, `BashAdapter` implementation, request/result file plumbing. |
| `internal/stagerunner/adapter_test.go` | Create | Unit tests for envelope round-trip, missing-result-file handling, SIGINT propagation. |
| `internal/pipeline/runner.go` | Create | `Runner.RunAttempt`, stage scheduling, review rework cycle, causal-event emission. |
| `internal/pipeline/gates.go` | Create | Build gate + completion gate ports of `lib/gates.sh`. |
| `internal/pipeline/handlers.go` | Create | `_handle_pipeline_success` / `_handle_pipeline_failure` ports. |
| `internal/pipeline/runner_test.go` | Create | Unit tests against a fake `stagerunner.Adapter`; exercises rework loop, build-gate retry, short-circuit on block. |
| `internal/pipeline/gates_test.go` | Create | Build/completion gate edge cases incl. baseline-failure passthrough. |
| `internal/proto/stage_v1.go` | Create | `StageRequestV1` / `StageResultV1`. |
| `internal/proto/pipeline_v1.go` | Modify | Extend m12's `AttemptRequestV1` / `AttemptResultV1` with stage breakdown. |
| `cmd/tekhton/run_stage.go` | Create | `tekhton run-stage <name>` for parity testing. |
| `cmd/tekhton/pipeline.go` | Create | `tekhton pipeline run-attempt` / `tekhton pipeline emit-stage`. |
| `cmd/tekhton/stage.go` | Create | `tekhton stage emit` envelope writer. |
| `lib/stage_envelope.sh` | Create | Shared `emit_stage_envelope` helper sourced by all stages. |
| `stages/intake.sh` | Modify | Set verdict/exit_reason at return paths; tail-call `emit_stage_envelope`. |
| `stages/coder.sh` | Modify | Same; verdict reflects build-fix continuation outcome. |
| `stages/security.sh` | Modify | Same; verdict carries severity-block disposition. |
| `stages/review.sh` | Modify | Same; `next_action="rework"` when reviewer requests rework. |
| `stages/tester.sh` | Modify | Same; verdict reflects baseline-pass logic. |
| `stages/cleanup.sh` | Modify | Same. |
| `stages/docs.sh` | Modify | Same. |
| `lib/gates.sh` | Delete | Logic in `internal/pipeline/gates.go`. |
| `lib/orchestrate_iteration.sh` | Delete | Logic in `internal/pipeline/{runner,handlers}.go`. |
| `lib/orchestrate_main.sh` | Modify | `_run_pipeline_stages` call replaced with `tekhton pipeline run-attempt`. |
| `scripts/pipeline-parity-check.sh` | Create | 6-scenario parity gate. |
| `scripts/wedge-audit.sh` | Modify | Add patterns banning re-introduction of `run_build_gate`, `_run_pipeline_stages` outside the shim. |
| `tests/test_pipeline_runner.sh` | Create | Smoke test for `tekhton pipeline run-attempt` against a small fixture. |
| `DESIGN_v4.md` | Modify | Replace "M139+" placeholders with V4 m01–m20 numbering; add Phase 4 batch-2 section. |

---

## Acceptance Criteria

- [ ] `tekhton run-stage intake --request-file testdata/stage-fixtures/intake.json` produces a `stage.result.v1` envelope with `verdict in {pass, fail, rework}` and exits 0.
- [ ] `tekhton pipeline run-attempt --request-file testdata/pipeline-parity/01-happy/request.json` produces an `attempt.result.v1` envelope whose stage breakdown matches `testdata/pipeline-parity/01-happy/expected.json` (after timestamp normalization).
- [ ] `git ls-files lib/gates.sh lib/orchestrate_iteration.sh` returns no files.
- [ ] `grep -rn '_run_pipeline_stages\|run_build_gate\|run_completion_gate' lib/ stages/ tekhton.sh` returns matches only in `lib/orchestrate_main.sh` (the migrated call site) and stage files that read result-of, not invoke.
- [ ] Each `stages/*.sh` (intake, coder, security, review, tester, cleanup, docs) emits a `stage.result.v1` envelope when `TEKHTON_STAGE_RESULT_FILE` is set, validated by `tests/test_stage_envelope.sh`.
- [ ] `scripts/pipeline-parity-check.sh` exits 0 on all six scenarios on `linux/amd64` and `darwin/amd64`.
- [ ] `internal/stagerunner` line coverage ≥ 80%.
- [ ] `internal/pipeline` line coverage ≥ 80%.
- [ ] `bash tests/run_tests.sh` passes; `go test ./...` passes.
- [ ] `bash scripts/wedge-audit.sh` exits 0.
- [ ] All new tests pass: `internal/stagerunner/adapter_test.go`, `internal/pipeline/runner_test.go`, `internal/pipeline/gates_test.go`, `tests/test_pipeline_runner.sh`, `tests/test_stage_envelope.sh`.
- [ ] No regression in `tests/test_orchestrate_*.sh`, `tests/test_supervisor_*.sh`, `tests/test_milestone_*.sh`.
- [ ] `DESIGN_v4.md` Phase 4 section replaces "M139+" placeholders with V4 m01–m20 numbering and adds a "Phase 4 batch 2 (m18–m20) — pipeline runner + dogfooding cutover" subsection.

## Watch For

- **Stage globals.** `run_stage_coder` and friends rely on a *lot* of bash globals (`_RWR_*` are gone after m12, but `EFFECTIVE_*_MAX_TURNS`, `_ORCH_*`, review-cycle counters, etc. remain). Audit each stage's `set | grep -E '^_?[A-Z]'` baseline before/after the milestone — anything the Go runner needs to set must travel via `EnvOverrides`. Anything the stage *exports* for the next stage must land in `stage.result.v1` or in a state file already written by Go.
- **Review rework cycle counter.** The bash version increments `REVIEW_CYCLE` inside the loop and the stage reads it. m18's Go runner owns the counter and passes it via `req.ReviewCycle`. The stage's existing read path (`REVIEW_CYCLE=${REVIEW_CYCLE:-1}`) keeps working because the env-override populates it.
- **Don't port the build-fix continuation loop (M128).** It's *inside* coder. m18 ports the *gate*, not the *fix loop*. Conflating them was the original sin of an earlier draft of this milestone.
- **`PIPELINE_ORDER`.** Two values today: `standard` and `test_first`. The `test_first` flow runs tester before coder, which interacts with the completion gate. Both modes must work; the parity gate covers `test_first` in scenario 6.
- **Stage logs.** Today each stage tees stdout to a stage-named log file (`LOG_DIR/coder_<timestamp>.log`). `BashAdapter` keeps that pattern via the `LogFile` field — don't break log filename conventions, finalize hooks read them.
- **Cleanup and docs are optional stages.** They run only when `CLEANUP_ENABLED=true` or `DOCS_AGENT_ENABLED=true`. The runner must consult config before scheduling them.

## Seeds Forward

- **m19 — `tekhton run` top-level command:** Reuses `internal/pipeline.Runner` for single-attempt runs and wraps it with `RunCompleteLoop` for `--complete` mode. The stage-adapter envelope is the contract `tekhton run` invokes the bash side through.
- **m20 — Dogfooding cutover:** Once `tekhton pipeline run-attempt` is the per-attempt scheduler, `tekhton.sh` can become a thin dispatcher. m20 flips the entry point.
- **Phase 5 finalize port:** `internal/pipeline.Runner` already emits stage envelopes; finalize hooks consume them. When finalize ports to Go, the envelope schema is reused for hook input.
- **V5 multi-provider hooks:** `internal/pipeline.Runner` is the natural place to wire provider-aware policies (per-provider stage allowlists, parallel stage execution). `Runner.RunAttempt`'s sequential schedule is the V4 baseline V5 will fan out from.
- **Stage-level metrics:** `stage.result.v1.DurationSec` + `AgentCalls` give the Watchtower dashboard a per-stage row without parsing CAUSAL_LOG.jsonl. m20's dashboard parity scenarios lean on this.
