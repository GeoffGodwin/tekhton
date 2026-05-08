<!-- milestone-meta
id: "19"
status: "done"
-->

# m19 — `tekhton run` Top-Level Command

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 4 — second wedge of the m18→m20 dogfooding-cutover batch. m18 puts the per-attempt scheduler in Go but `run_complete_loop` (the outer retry loop in `lib/orchestrate_main.sh`) and the top-of-`tekhton.sh` argument parsing / pre-flight / milestone selection are still bash. m19 ports both. After m19, every flag that runs the pipeline (`--task`, `--complete`, `--resume`, `--human`, `--milestone`, `--auto-advance`, `--dry-run`) goes through `tekhton run`. |
| **Gap** | `tekhton.sh` is a 1000+ line bash script that argument-parses, sources config, runs pre-flight, picks the active milestone, and either calls `run_complete_loop` (autonomous) or directly invokes the pipeline (`--task`). `run_complete_loop` itself (`lib/orchestrate_main.sh`, ~248 LOC) is the outer retry loop with autonomous-timeout / max-attempts / agent-call counting / no-progress detection. Together that's the run-level logic Go doesn't own yet. |
| **m19 fills** | (1) `cmd/tekhton/run.go` — `tekhton run` Cobra subcommand with run-flags only (other tekhton.sh flags keep going to bash dispatching from m20's tekhton.sh shim). (2) `internal/runner/` package with `RunSingle(ctx, req)` for `--task` and `RunCompleteLoop(ctx, req)` for `--complete`. (3) Pre-flight bridge: Go runner `exec.CommandContext("bash", "lib/preflight.sh")` and parses the report file (no preflight port — Phase 5). (4) Finalize bridge: Go runner exec's `bash lib/finalize.sh` at end of run with disposition env vars (no finalize port — Phase 5). (5) TUI sidecar bridge: Go runner spawns `python3 tools/tui.py` directly (the bash `start_tui_sidecar` logic ports to ~50 LOC of Go; status writers stay bash and are still called by stages and finalize). (6) `lib/orchestrate_main.sh` is deleted; `lib/orchestrate.sh` shrinks to the source-block needed by `lib/finalize.sh` (still bash). |
| **Depends on** | m17, m18 |
| **Files changed** | `cmd/tekhton/run.go` (new), `internal/runner/` (new), `internal/proto/run_v1.go` (new), `lib/orchestrate_main.sh` (delete), `lib/orchestrate.sh` (modify — slim source set), `lib/orchestrate_aux.sh` (modify — `_save_orchestration_state` + smart-resume helpers move to Go; auto-advance helpers stay bash for now), `tekhton.sh` (no change yet — m20 owns the entry-point flip), `scripts/run-parity-check.sh` (new), `docs/go-migration.md` (modify) |
| **Stability after this milestone** | Stable. `tekhton run` works end-to-end for the run-flags subset. `tekhton.sh` continues to be the entry point users invoke (it dispatches to `tekhton run` internally for run-flags via a small bridge); m20 flips that. |
| **Dogfooding stance** | **Bridge mode.** m19 lands `tekhton run` and proves it works via parity gate. Users still invoke `tekhton.sh`. m20 flips the entry point. This sequencing keeps m19 focused on the runner port and m20 focused on the cutover. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m17 | Common error sentinels for cross-package `errors.Is` lookups. |
| m18 | Per-attempt scheduler + gates moved to Go; stage envelope established. |
| **m19** | **Outer retry loop + run-level CLI move to Go; finalize/preflight/TUI status still bash.** |

---

## Design

### Sequencing note

m19's complete-loop port (`run_complete_loop` → `internal/runner/complete.go`) reads exactly the orchestration globals m12 left in bash (`_ORCH_ATTEMPT`, `_ORCH_AGENT_CALLS`, `_ORCH_LAST_DIFF_HASH`, `_ORCH_NO_PROGRESS_COUNT`, `_ORCH_LAST_ACCEPTANCE_HASH`, `_ORCH_IDENTICAL_ACCEPTANCE_COUNT`, `_ORCH_CONSECUTIVE_MAX_TURNS`, `_ORCH_MAX_TURNS_STAGE`). Those become Go fields on a `Loop` struct. The bash side stops referring to them because `lib/orchestrate_main.sh` is deleted; any bash callers downstream (finalize hooks) read derived values from `PIPELINE_STATE.json` (already Go-written via m03) or from `RUN_SUMMARY.json` collectors.

m19 deliberately does *not* port:
- `lib/orchestrate_aux.sh::_check_auto_advance` and friends — auto-advance is a milestone-mode UI affordance, called from `run_complete_loop`, but the *prompting* logic shells to `read` and the user. Keep that bash for m19; port in Phase 5.
- Smart-resume escalation logic (`_orch_smart_resume_*`) — same reasoning; lives in the same file.
- Pre-flight (`lib/preflight.sh`, `lib/preflight_checks_ui.sh`) — Phase 5.
- Finalize chain (26 hooks) — Phase 5.
- TUI status writers (`lib/tui_ops.sh` and friends) — they're called from stages (still bash) and from finalize (still bash). Keep them bash; m19 only adds Go-side sidecar spawn.

### Goal 1 — `tekhton run` Cobra subcommand

```go
// cmd/tekhton/run.go
var runCmd = &cobra.Command{
    Use:   "run",
    Short: "Run the Tekhton pipeline",
    RunE:  runE,
}

func init() {
    runCmd.Flags().String("task", "", "Free-form task description")
    runCmd.Flags().Bool("complete", false, "Run in autonomous --complete mode")
    runCmd.Flags().Bool("resume", false, "Resume from PIPELINE_STATE.json")
    runCmd.Flags().Bool("human", false, "Run in --human mode (HUMAN_NOTES.md driven)")
    runCmd.Flags().String("human-tag", "", "Optional tag filter for --human")
    runCmd.Flags().String("milestone", "", "Specific milestone id to run")
    runCmd.Flags().Bool("auto-advance", false, "Advance to next milestone on success")
    runCmd.Flags().Int("auto-advance-limit", 0, "Override AUTO_ADVANCE_LIMIT")
    runCmd.Flags().Bool("dry-run", false, "Preview run without invoking agents")
    runCmd.Flags().Bool("no-tui", false, "Disable TUI sidecar")
}
```

Flag validation: exactly one of `--task` / `--human` / `--milestone` (or `--resume` which infers from PIPELINE_STATE.json). `--complete` is independent. `--auto-advance` requires milestone-mode.

### Goal 2 — `internal/runner` package

```go
package runner

type Runner struct {
    Cfg       config.Resolved
    State     *state.Store
    Causal    *causal.Log
    Pipeline  *pipeline.Runner   // from m18
    Stages    stagerunner.Adapter
    TUI       *TUISidecar        // optional
}

func New(...) *Runner

// One-shot pipeline attempt (--task non-complete mode).
func (r *Runner) RunSingle(ctx context.Context, req *proto.RunRequestV1) (*proto.RunResultV1, error)

// Outer retry loop (--complete mode).
func (r *Runner) RunCompleteLoop(ctx context.Context, req *proto.RunRequestV1) (*proto.RunResultV1, error)

// Resume from PIPELINE_STATE.json. Reads exit_reason, attempt count, etc.
func (r *Runner) Resume(ctx context.Context) (*proto.RunResultV1, error)
```

`RunCompleteLoop` is the meat. Direct port of `run_complete_loop` from `orchestrate_main.sh`:

- Initialize loop state (attempt counter, agent-call counter, start time).
- Capture diff hash for no-progress detection.
- Reset `EFFECTIVE_*_MAX_TURNS` env overrides for first attempt.
- For up to `MAX_PIPELINE_ATTEMPTS` iterations:
  - Check autonomous-timeout (`AUTONOMOUS_TIMEOUT` seconds elapsed).
  - Check `MAX_AUTONOMOUS_AGENT_CALLS` budget.
  - Call `r.Pipeline.RunAttempt(...)` (m18).
  - On success: invoke milestone-acceptance check (still bash via shell-out to `bash -c "source lib/milestone_acceptance.sh; check_milestone_acceptance"` for m19; ports to Go in a Phase 4 follow-up).
  - On failure: classify error (`tekhton orchestrate classify` from m12), apply recovery dispatch, decide retry vs terminate.
  - Update no-progress counter (`_ORCH_NO_PROGRESS_COUNT` → Go field).
  - Update consecutive-max-turns counter (m91 escalation).
  - Persist orchestration state to `PIPELINE_STATE.json` (Go writer from m03).
- After the loop: shell out to `bash lib/finalize.sh` with disposition (`SUCCESS` / `FAILURE` / `STUCK` / `TIMEOUT`).

Resume support: `Resume(ctx)` reads `PIPELINE_STATE.json`, restores loop state, and continues. The bash version's heredoc + awk parser is gone; m03 already writes JSON.

### Goal 3 — Pre-flight bridge

Pre-flight stays bash. The Go runner invokes it as a subprocess at the start of `RunSingle` / `RunCompleteLoop`:

```go
func (r *Runner) preflight(ctx context.Context) error {
    cmd := exec.CommandContext(ctx, "bash", filepath.Join(r.Cfg.TekhtonHome, "lib", "preflight.sh"))
    cmd.Env = append(os.Environ(), r.envOverrides()...)
    cmd.Stdout = os.Stdout  // existing bash already manages PREFLIGHT_REPORT.md
    cmd.Stderr = os.Stderr
    if err := cmd.Run(); err != nil {
        return fmt.Errorf("preflight: %w", err)
    }
    return r.readPreflightReport()
}
```

The pre-flight script is not modified. Its output (`PREFLIGHT_REPORT.md`) is parsed for blocking issues. If `PREFLIGHT_FAIL_ON_WARN=true` and the report has warnings, the runner aborts.

### Goal 4 — Finalize bridge

Finalize stays bash. The Go runner exec's `bash lib/finalize.sh` at the very end with disposition env vars:

```go
func (r *Runner) finalize(ctx context.Context, disposition string, result *proto.RunResultV1) error {
    cmd := exec.CommandContext(ctx, "bash", filepath.Join(r.Cfg.TekhtonHome, "lib", "finalize.sh"))
    cmd.Env = append(os.Environ(),
        "TEKHTON_RUN_DISPOSITION="+disposition,
        "TEKHTON_RUN_RESULT_FILE="+r.runResultPath(result),
    )
    cmd.Stdout = os.Stdout
    cmd.Stderr = os.Stderr
    return cmd.Run()
}
```

`lib/finalize.sh` already reads `PIPELINE_STATE.json` and `RUN_SUMMARY.json`-fragment files. The two new env vars are the only contract additions: disposition and a path to the structured `RunResultV1` envelope that newer hooks can read.

`lib/finalize.sh` itself is unmodified. The 26-hook chain runs as it does today. Phase 5 ports the hooks one-by-one.

### Goal 5 — TUI sidecar bridge

The Python TUI sidecar (`tools/tui.py`) is invoked once per run. The bash `lib/tui.sh::start_tui_sidecar` does this today by spawning the Python process and wiring `tui_status.json` for IPC.

Move *only* the spawn-and-monitor logic to Go (~50 LOC):

```go
type TUISidecar struct {
    StatusFile string
    EventsFile string
    venvPython string
    cmd        *exec.Cmd
    holdTimeout time.Duration
}

func (t *TUISidecar) Start(ctx context.Context) error
func (t *TUISidecar) Stop(ctx context.Context, holdEnter bool) error
```

`internal/tui/sidecar.go` owns the lifecycle; `internal/tui/status.go` writes the initial status file and a final completion entry. Mid-run status updates *continue* to come from bash (`stages/*.sh` and `lib/finalize.sh` source `lib/tui_ops.sh` and call its functions). Those bash writers stay; the Python sidecar reads from `tui_status.json` regardless of who wrote it. No double-write because each writer has well-known call sites.

`--no-tui` skips the sidecar entirely. Auto-detection (TTY + venv) lives on the Go side.

### Goal 6 — Bash deletions

| Bash file | Disposition |
|-----------|-------------|
| `lib/orchestrate_main.sh` | Delete. Logic in `internal/runner/complete.go`. |
| `lib/orchestrate.sh` | Modify. Was a source-only shim for the deleted helpers; shrinks to source whatever finalize hooks still need (`lib/orchestrate_aux.sh` survives for auto-advance prompts). |
| `lib/orchestrate_aux.sh` | Modify. `_save_orchestration_state` deletes (Go writes `PIPELINE_STATE.json` directly via m03). Auto-advance prompt helpers and smart-resume escalation stay. |
| `lib/orchestrate_state.sh` | Delete. State save/load all goes through `internal/state` (m03). |

### Goal 7 — Parity gate

`scripts/run-parity-check.sh` runs ten scenarios:

1. `--task "..."` happy path.
2. `--task "..."` with build-gate retry.
3. `--task "..."` with review rework.
4. `--complete --task "..."` succeeding on attempt 1.
5. `--complete --task "..."` succeeding on attempt 3 (transient retries).
6. `--complete --task "..."` hitting `MAX_PIPELINE_ATTEMPTS` and exiting STUCK.
7. `--complete --task "..."` hitting `AUTONOMOUS_TIMEOUT`.
8. `--milestone m99 --complete` with auto-advance off.
9. `--resume` after SIGINT mid-attempt.
10. `--human` driving a run from `HUMAN_NOTES.md`.

Each scenario records the bash baseline once, then the parity gate diffs `RUN_SUMMARY.json`, `PIPELINE_STATE.json`, and `CAUSAL_LOG.jsonl` event types (after timestamp/PID normalization).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `cmd/tekhton/run.go` | Create | `tekhton run` Cobra command, flag validation, dispatch to runner. |
| `cmd/tekhton/run_test.go` | Create | Flag validation tests, sub-command dispatch. |
| `internal/runner/runner.go` | Create | `Runner` struct, constructor, env-override builder. |
| `internal/runner/single.go` | Create | `RunSingle` for `--task` non-complete mode. |
| `internal/runner/complete.go` | Create | `RunCompleteLoop` port of `run_complete_loop`. |
| `internal/runner/resume.go` | Create | `Resume` reads `PIPELINE_STATE.json` and continues. |
| `internal/runner/preflight.go` | Create | Bash bridge to `lib/preflight.sh`. |
| `internal/runner/finalize.go` | Create | Bash bridge to `lib/finalize.sh`. |
| `internal/runner/runner_test.go` | Create | Unit tests against fake `pipeline.Runner` and fake stage adapter. |
| `internal/runner/complete_test.go` | Create | Outer-loop scenarios (timeout, max-attempts, no-progress). |
| `internal/tui/sidecar.go` | Create | TUI sidecar spawn/monitor. |
| `internal/tui/status.go` | Create | Initial + final status-file writers (mid-run writers stay bash). |
| `internal/tui/sidecar_test.go` | Create | Sidecar lifecycle tests with a fake Python process. |
| `internal/proto/run_v1.go` | Create | `RunRequestV1` / `RunResultV1`. |
| `lib/orchestrate_main.sh` | Delete | Logic in `internal/runner/complete.go`. |
| `lib/orchestrate.sh` | Modify | Shrink to source set still needed by finalize hooks. |
| `lib/orchestrate_aux.sh` | Modify | Drop `_save_orchestration_state`; keep auto-advance + smart-resume helpers. |
| `lib/orchestrate_state.sh` | Delete | State all in `internal/state`. |
| `scripts/run-parity-check.sh` | Create | 10-scenario run-level parity gate. |
| `scripts/wedge-audit.sh` | Modify | Add patterns banning `run_complete_loop`, `_save_orchestration_state` outside the (now deleted) shim. |
| `docs/go-migration.md` | Modify | Phase 4 batch-2 progress: m18 + m19 retro. |
| `tests/test_run_command.sh` | Create | Integration smoke for `tekhton run --task` against a small fixture. |

---

## Acceptance Criteria

- [ ] `tekhton run --task "echo hello"` exits 0 against a fixture project, producing `RUN_SUMMARY.json` and a git commit identical (modulo timestamps + commit hash) to `bash tekhton.sh "echo hello"`.
- [ ] `tekhton run --complete --task "..."` runs the full retry loop, respects `MAX_PIPELINE_ATTEMPTS`, `AUTONOMOUS_TIMEOUT`, and `MAX_AUTONOMOUS_AGENT_CALLS`.
- [ ] `tekhton run --resume` against an interrupted `PIPELINE_STATE.json` continues from the recorded attempt count and exit reason; `tests/test_run_command.sh::test_resume_after_sigint` passes.
- [ ] `tekhton run --human --human-tag BUG` filters `HUMAN_NOTES.md` to the BUG tag and runs against the first unchecked item.
- [ ] `tekhton run --milestone m99 --complete --auto-advance` advances on success (auto-advance prompt logic stays bash; Go runner shells out to it).
- [ ] `tekhton run --no-tui` skips the TUI sidecar; `pgrep -f tools/tui.py` returns empty after the run.
- [ ] `tekhton run --dry-run --task "..."` invokes the dry-run preview path (shells to `lib/dry_run.sh` for now) without invoking any agents.
- [ ] `git ls-files lib/orchestrate_main.sh lib/orchestrate_state.sh` returns no files.
- [ ] `grep -rn 'run_complete_loop\|_save_orchestration_state' lib/ stages/ tekhton.sh` returns no matches.
- [ ] `internal/runner` line coverage ≥ 80%.
- [ ] `internal/tui` line coverage ≥ 75% (sidecar lifecycle is harder to unit-test; integration covers the gap).
- [ ] `scripts/run-parity-check.sh` exits 0 on all ten scenarios on `linux/amd64` and `darwin/amd64`.
- [ ] `bash tests/run_tests.sh` passes; `go test ./...` passes.
- [ ] `bash scripts/wedge-audit.sh` exits 0.
- [ ] `docs/go-migration.md` Phase 4 batch-2 section records what shipped in m18+m19 and what's left for m20.

## Watch For

- **Don't merge m19 with m20.** m19 makes `tekhton run` work and proves it via parity gate. m20 flips `tekhton.sh` to dispatch through it. Splitting these de-risks the cutover: if parity reveals a regression, m20 is the rollback point.
- **Bash-side orchestration state references.** Anything still bash that *reads* `_ORCH_*` globals after m19 will break. Audit `lib/finalize_*.sh`, `lib/hooks.sh`, `lib/dashboard*.sh`, `lib/tui_ops.sh` for `_ORCH_` references; route them through `PIPELINE_STATE.json` instead. Likely 5–10 read sites.
- **Auto-advance prompt is interactive.** When `AUTO_ADVANCE_CONFIRM=true` (default), the bash function reads from stdin. Go runner's `exec.CommandContext` to the bash subprocess must inherit stdin; don't redirect it.
- **`HUMAN_NOTES.md` parsing stays bash.** The `--human` flag's note-extraction logic lives in `lib/notes.sh` and is called from inside stages (intake reads HUMAN_NOTES_BLOCK during prompt rendering). Don't try to parse it from Go in m19; just pass `HUMAN_MODE=true` and `HUMAN_NOTES_TAG=...` env-overrides to the pipeline runner.
- **Resume routing semantics.** The legacy bash resume path infers exit reason from a heredoc-formatted state file. m03 already writes JSON; m19's resume reads the JSON. The legacy markdown reader in `lib/state.sh::load_pipeline_state_legacy` (if it still exists) is now unreachable from `tekhton run` — but `bash tekhton.sh --resume` still works and uses the bash path until m20.
- **TUI status file race.** The Go sidecar spawn + the bash mid-run writers + the bash finalize-time writer all touch `tui_status.json`. The atomic-write pattern in `lib/tui_liveness.sh` (write to `.tmp`, rename) must be preserved. Add a Go-side lock-free write that uses the same `.tmp` + rename. Verify with `tests/test_tui_lifecycle_invariants.sh`.

## Seeds Forward

- **m20 — Dogfooding cutover:** `tekhton.sh` becomes a dispatcher: run-flags route to `tekhton run`; legacy flags (`--init`, `--rescan`, `--draft-milestones`, `--report`, `--status`, `--metrics`, `--migrate`, `--health`, `--rollback`) keep going to the existing bash code paths until Phase 5.
- **Phase 5 finalize port:** Each of the 26 hooks in `lib/finalize.sh` becomes a Go function or a bash subprocess, registered with a Go hook-chain runner. m19's bash bridge is the placeholder. The disposition env-var contract m19 establishes is the input.
- **Phase 5 preflight port:** `lib/preflight.sh` and `lib/preflight_checks_ui.sh` (M131 UI test framework audit) port to `internal/preflight`. m19's bash bridge is the placeholder.
- **Phase 5 milestone-acceptance port:** `lib/milestone_acceptance.sh` ports to `internal/milestone/acceptance`. m19's `RunCompleteLoop` shells out to it; the future port replaces the shell-out with an in-process call.
- **V5 multi-provider:** `internal/runner.Runner` is the natural place for provider-aware policy (per-provider stage allowlists, parallel execution mode flags). The flag plumbing in `cmd/tekhton/run.go` extends naturally.
