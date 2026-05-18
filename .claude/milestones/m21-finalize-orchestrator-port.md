<!-- milestone-meta
id: "21"
status: "done"
-->

# m21 — Finalize Orchestrator Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — first dogfooded V4 milestone. M20 made `tekhton run` (Go) the entry point for every pipeline run but left the post-pipeline finalize chain in bash: when the runner finishes, `BashAdapter.Finalize` execs `lib/finalize.sh`, which iterates 26 bash hooks. Every run, success or failure, touches it. That makes finalize the highest-leverage Phase 5 port: until it's Go, every run still hands control back to bash for the most-touched stage of the pipeline, and the artifacts users see most (RUN_SUMMARY.json, MILESTONE_ARCHIVE.md, git commit, dashboard status) are bash-emitted. |
| **Gap** | `lib/finalize.sh` + its seven satellites (`finalize_aux.sh`, `finalize_commit.sh`, `finalize_dashboard_hooks.sh`, `finalize_display.sh`, `finalize_summary.sh`, `finalize_summary_collectors.sh`, `finalize_version.sh`) total 1465 lines of bash. The orchestrator (`register_finalize_hook` + `finalize_run`) lives at `lib/finalize.sh:38-280`; 26 hooks are registered at `lib/finalize.sh:218-243`. The Go runner has no awareness of which hook is running — it just execs bash and waits. There is no per-hook timing, structured failure capture, or way to substitute a Go implementation for one hook while leaving the rest as bash. |
| **m21 fills** | (1) `internal/finalize/` becomes the Go-side orchestrator. The hook registry, sequence, and per-hook error handling move from bash to Go. (2) Eight pure-Go hooks land natively, picked because they have no remaining bash subsystem dependency: `clear_state`, `causal_log_finalize`, `emit_run_summary`, `emit_run_memory`, `emit_timing_report`, `archive_reports`, `mark_done`, `archive_milestone`. (3) The remaining 18 hooks stay in bash for now, but are invoked one-at-a-time via a new `lib/finalize_shim.sh` dispatcher — each follow-up milestone (m22 TUI/preflight, m23 dashboard, m24 notes/drift, m25 health/metrics) replaces its hooks' bash bodies with Go bodies in `internal/finalize/hooks/`. (4) `BashAdapter.Finalize` becomes `FinalizeRunner.Run` — no longer execs bash for the chain; only execs bash for individual unmigrated hooks. (5) A parity gate diffs `RUN_SUMMARY.json`, `MILESTONE_ARCHIVE.md` deltas, and `PIPELINE_STATE.json` between a known-good bash baseline and the m21 Go orchestrator. (6) `VERSION` bumps to `4.21.0` on close. |
| **Depends on** | m20 |
| **Files changed** | `internal/finalize/orchestrator.go` (create), `internal/finalize/hooks/*.go` (create — 8 hook impls), `internal/finalize/shim.go` (create — bash-shim invoker), `internal/runner/runner.go` (modify — `Finalize` calls `FinalizeRunner.Run`), `lib/finalize.sh` (modify — collapse to a one-line note pointing at the Go orchestrator; preserve only what the shim dispatcher needs), `lib/finalize_shim.sh` (create — single-hook dispatch entry for unmigrated hooks), `cmd/tekhton/finalize.go` (create — `tekhton finalize` CLI for standalone testing), `tests/test_finalize_parity.sh` (create — parity gate), `VERSION` (bump on close) |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m19 | `tekhton run` top-level command — runner owns the outer retry loop. |
| m20 | `tekhton.sh` becomes a dispatcher; Go owns every pipeline run, but hands control back to bash for finalize via `BashAdapter.Finalize`. |
| **m21** | **Go also owns finalize. Bash still implements 18 of 26 hooks behind a dispatcher; subsequent milestones replace them one subsystem at a time.** |

---

## Design

### Sequencing note

m21 is the first milestone authored *after* M20's cutover and is the first that should be implemented end-to-end via `tekhton run --milestone m21 --complete`. That itself is the dogfooding signal — if the m21 implementation run doesn't successfully reach finalize, we've found a bug worth fixing before m21 merges (which is the entire point of dogfooding).

This milestone touches the Go↔bash bridge at the most-exercised seam. Two non-obvious sequencing constraints:

1. **The Go orchestrator must call hooks in the same order bash does today.** Several hooks have implicit ordering dependencies (e.g., `_hook_resolve_notes` must run before `_hook_archive_reports` because archive moves the notes file; `_hook_emit_run_summary` reads state that `_hook_clear_state` would erase if run earlier). The registration order in `lib/finalize.sh:218-243` is authoritative — copy it byte-for-byte into the Go registration list.
2. **`BashAdapter.Finalize` keeps its signature.** The runner already passes disposition + result file via `TEKHTON_RUN_RESULT_FILE`; m21 must not change that contract because m20's parity matrix relies on it. The change is purely behind the adapter — the runner doesn't know whether the chain ran in Go or bash.

### Goal 1 — Hook registry + sequence in Go

`internal/finalize/orchestrator.go` owns the hook list and the run loop:

```go
package finalize

type Hook interface {
    Name() string                          // matches bash hook name (e.g. "_hook_emit_run_summary")
    Run(ctx context.Context, in *Input) error
}

type Input struct {
    ExitCode      int
    Disposition   proto.Disposition         // success | partial | failure
    Result        *proto.RunResultV1        // already in Go from m19
    TekhtonHome   string
    ProjectDir    string
    LogDir        string
    Env           []string                  // pre-filtered env passed to bash-shim hooks
}

type Orchestrator struct {
    hooks []Hook
    log   io.Writer
}

func NewOrchestrator(home, projectDir string) *Orchestrator { /* registers all 26 in bash order */ }

func (o *Orchestrator) Run(ctx context.Context, in *Input) Summary {
    var sum Summary
    for _, h := range o.hooks {
        start := time.Now()
        err := h.Run(ctx, in)
        sum.Hooks = append(sum.Hooks, HookResult{
            Name: h.Name(), Duration: time.Since(start), Err: err,
        })
        // continue-on-error matches bash semantics: each hook is responsible
        // for its own warnings/skips; the chain never aborts midway.
    }
    return sum
}
```

The chain **never aborts mid-run**, mirroring bash semantics. A hook that fails logs a warning and the chain continues — the parity gate verifies this matches bash.

### Goal 2 — Eight pure-Go hook implementations

These hooks have no remaining bash subsystem dependency. Each lives at `internal/finalize/hooks/<name>.go` and implements the `Hook` interface:

| Hook | Source bash | Pure-Go because |
|------|-------------|----------------|
| `clear_state` | `lib/finalize.sh:_hook_clear_state` | Pipeline state is already Go-owned (m03 — `pkg/state`). |
| `causal_log_finalize` | `lib/finalize.sh:_hook_causal_log_finalize` | Causal log writer is already Go-owned (m02 — `pkg/causal`). |
| `emit_run_summary` | `lib/finalize_summary.sh` (~290 lines) | Reads `RunResultV1` + collectors that read JSON artifacts; no bash deps once the collectors port. Inline the four `finalize_summary_collectors.sh` collectors as Go funcs. |
| `emit_run_memory` | `lib/run_memory.sh` (called from hook) | JSONL append-only. Tiny. |
| `emit_timing_report` | `lib/timing.sh` (called from hook) | Reads `PIPELINE_STATE.json` timing, writes a markdown report. No external deps. |
| `archive_reports` | `lib/finalize.sh:_hook_archive_reports` | File moves: `BUILD_FIX_REPORT.md`, `SECURITY_REPORT.md`, etc. into `.tekhton/archive/<timestamp>/`. Pure stdlib. |
| `mark_done` | `lib/milestone_ops.sh` (called from hook) | Milestone DAG state is already Go-owned (m14 — `pkg/dag`). |
| `archive_milestone` | `lib/milestone_archival.sh` (~280 lines incl helpers) | Appends a completed milestone body to `MILESTONE_ARCHIVE.md`. File-only operation; no subsystem dependency. |

Each hook gets a focused unit test in `internal/finalize/hooks/<name>_test.go` plus an integration test in `internal/finalize/orchestrator_test.go` that runs the full chain against a synthetic `RunResultV1`.

### Goal 3 — Bash shim for the remaining 18 hooks

The 18 hooks that stay in bash for now (notes/drift/clarify/dashboard/TUI/metrics/health/project_version/changelog/commit/update_check/express_persist/failure_context/baseline_cleanup/note_acceptance/final_checks/cleanup_resolved/final_dashboard_status/tui_complete/failure_context_reset) are invoked one-at-a-time via a new dispatcher:

```bash
# lib/finalize_shim.sh — minimal: source what the named hook needs, call it.
#!/usr/bin/env bash
set -euo pipefail

HOOK_NAME="$1"   # e.g. _hook_resolve_notes
TEKHTON_HOME="${TEKHTON_HOME:?}"
# Env vars passed by the Go orchestrator via Env field on the Hook Input.

# Source the file owning this hook (table generated at port time).
case "$HOOK_NAME" in
    _hook_resolve_notes|_hook_cleanup_resolved|_hook_note_acceptance)
        source "$TEKHTON_HOME/lib/notes.sh"
        source "$TEKHTON_HOME/lib/notes_cleanup.sh"
        source "$TEKHTON_HOME/lib/finalize.sh"  # transitional — hook body still lives here
        ;;
    _hook_drift_artifacts)
        source "$TEKHTON_HOME/lib/drift_artifacts.sh"
        source "$TEKHTON_HOME/lib/finalize.sh"
        ;;
    _hook_final_dashboard_status|_hook_tui_complete)
        source "$TEKHTON_HOME/lib/dashboard.sh"
        source "$TEKHTON_HOME/lib/tui.sh"
        source "$TEKHTON_HOME/lib/finalize_dashboard_hooks.sh"
        ;;
    # …one entry per remaining hook
esac

"$HOOK_NAME" "${PIPELINE_EXIT_CODE:-0}"
```

The Go side calls it like this (`internal/finalize/shim.go`):

```go
type BashShimHook struct {
    HookName    string
    TekhtonHome string
    Env         []string
}

func (h *BashShimHook) Name() string { return h.HookName }
func (h *BashShimHook) Run(ctx context.Context, in *Input) error {
    cmd := exec.CommandContext(ctx, "bash",
        filepath.Join(h.TekhtonHome, "lib", "finalize_shim.sh"), h.HookName)
    cmd.Env = append(h.Env,
        "PIPELINE_EXIT_CODE="+strconv.Itoa(in.ExitCode),
        "TEKHTON_RUN_RESULT_FILE="+in.ResultPath)
    cmd.Stdout, cmd.Stderr = h.Log, h.Log
    return cmd.Run()
}
```

The dispatcher is intentionally one-process-per-hook (not one-process-for-the-chain) so that follow-up milestones can swap a `BashShimHook` for a Go hook *one entry at a time*, without orchestrator changes. m22 deletes the dashboard/TUI cases from `finalize_shim.sh`; m23 deletes the notes cases; etc. When the dispatcher's `case` is empty, `lib/finalize_shim.sh` deletes.

### Goal 4 — `BashAdapter.Finalize` rewires

`internal/runner/runner.go:Finalize` becomes a thin shim that constructs the orchestrator and runs it:

```go
func (b *BashAdapter) Finalize(ctx context.Context, in FinalizeInput) error {
    orch := finalize.NewOrchestrator(b.TekhtonHome, b.ProjectDir)
    sum := orch.Run(ctx, &finalize.Input{
        ExitCode:    in.ExitCode,
        Disposition: in.Disposition,
        Result:      in.Result,
        TekhtonHome: b.TekhtonHome,
        ProjectDir:  b.ProjectDir,
        LogDir:      in.LogDir,
        Env:         b.finalizeEnv(),
    })
    // Per-hook timing surfaces in causal log; chain itself never errors.
    return nil
}
```

The runner does not change. The CLI does not change. Only the internals of `BashAdapter.Finalize` change.

### Goal 5 — `tekhton finalize` standalone CLI

`cmd/tekhton/finalize.go` adds a Cobra subcommand that runs the chain against a saved `RunResultV1` envelope:

```
tekhton finalize --result .tekhton/state/RUN_RESULT.json --home . --project-dir .
```

This is the parity gate's lever — it can replay a captured run-result through both the Go orchestrator and bash and diff the side effects without re-running the whole pipeline.

### Goal 6 — Parity gate (`tests/test_finalize_parity.sh`)

Strategy: capture a known-good run via `tekhton run --task "parity-fixture" --complete` against a frozen fixture project on the `v4.20.0-dogfood` tag, snapshot the post-run files (`RUN_SUMMARY.json`, `MILESTONE_ARCHIVE.md` delta, `PIPELINE_STATE.json`, `CAUSAL_LOG.jsonl` tail, git log tail), then on the m21 implementation:

1. Restore the fixture project to pre-finalize state.
2. Run `tekhton finalize --result <captured-envelope>` (Go orchestrator).
3. Diff every artifact against the captured baseline after timestamp/PID normalization.
4. Repeat for two more scenarios: success+milestone-complete, failure+milestone-incomplete.

CI matrix: `linux/amd64`, `darwin/amd64` (Windows added in m22 along with the TUI port — finalize itself has no Windows-specific behavior).

### Goal 7 — Docs + bash LOC accounting

`docs/v4-phase5-stub.md` updates:

- Mark hook 1 (finalize.sh) as "in progress (m21 — orchestrator + 8 hooks Go; 18 hooks behind shim)".
- Update the Bash LOC budget table with the post-m21 count. Expected: ~9500 → ~8500 (one-fifth of the 1465-line finalize subsystem ported; the rest stays bash behind the shim).

`docs/go-migration.md` gets a Phase 5 retro stub at the top of the doc (filled in when m21 closes).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/finalize/orchestrator.go` | Create | Hook registry + run loop. Mirrors `lib/finalize.sh` registration order at `lib/finalize.sh:218-243`. |
| `internal/finalize/hook.go` | Create | `Hook` interface + `Input` / `Summary` / `HookResult` types. |
| `internal/finalize/hooks/clear_state.go` | Create | Pure-Go: wraps `pkg/state.Clear`. |
| `internal/finalize/hooks/causal_log_finalize.go` | Create | Pure-Go: wraps `pkg/causal.Finalize`. |
| `internal/finalize/hooks/emit_run_summary.go` | Create | Pure-Go: replaces `lib/finalize_summary.sh` + `lib/finalize_summary_collectors.sh`. |
| `internal/finalize/hooks/emit_run_memory.go` | Create | Pure-Go: JSONL append. |
| `internal/finalize/hooks/emit_timing_report.go` | Create | Pure-Go: reads `PIPELINE_STATE.json` timing block. |
| `internal/finalize/hooks/archive_reports.go` | Create | Pure-Go: file moves into `.tekhton/archive/<ts>/`. |
| `internal/finalize/hooks/mark_done.go` | Create | Pure-Go: wraps `pkg/dag.MarkDone`. |
| `internal/finalize/hooks/archive_milestone.go` | Create | Pure-Go: replaces `lib/milestone_archival.sh`. |
| `internal/finalize/shim.go` | Create | `BashShimHook` — execs `lib/finalize_shim.sh <hook_name>` per hook. |
| `internal/finalize/*_test.go` | Create | Hook unit tests + orchestrator integration test. |
| `internal/runner/runner.go` | Modify | `BashAdapter.Finalize` builds an `Orchestrator` and runs it instead of `exec("bash lib/finalize.sh")`. |
| `cmd/tekhton/finalize.go` | Create | `tekhton finalize` subcommand for standalone testing + parity replay. |
| `cmd/tekhton/finalize_test.go` | Create | CLI smoke test. |
| `lib/finalize.sh` | Modify | Shrink to ~30 lines — keep only the 18 remaining hook function bodies (which `finalize_shim.sh` sources transitionally). Delete the orchestrator + registry. |
| `lib/finalize_summary.sh` | Delete | Ported to Go. |
| `lib/finalize_summary_collectors.sh` | Delete | Ported to Go. |
| `lib/milestone_archival.sh` | Delete | Ported to Go. |
| `lib/milestone_archival_helpers.sh` | Delete | Ported to Go alongside its parent. |
| `lib/run_memory.sh` | Delete | Ported to Go. |
| `lib/finalize_shim.sh` | Create | Single-hook bash dispatcher invoked by `BashShimHook`. |
| `tests/test_finalize_parity.sh` | Create | Three-scenario parity gate. |
| `docs/v4-phase5-stub.md` | Modify | Update inventory (hook 1 in progress) + LOC budget table. |
| `docs/go-migration.md` | Modify | Phase 5 retro stub at top. |
| `VERSION` | Modify | Bump to `4.21.0` on close. |

---

## Acceptance Criteria

- [ ] `internal/finalize/orchestrator.go` registers exactly 26 hooks in the same order as `lib/finalize.sh:218-243`; an order-mismatch test in `internal/finalize/orchestrator_test.go` fails red if the order drifts.
- [ ] All 8 pure-Go hooks (`clear_state`, `causal_log_finalize`, `emit_run_summary`, `emit_run_memory`, `emit_timing_report`, `archive_reports`, `mark_done`, `archive_milestone`) have a passing unit test in `internal/finalize/hooks/<name>_test.go`.
- [ ] `internal/finalize/orchestrator_test.go` runs the full 26-hook chain against a synthetic `RunResultV1` and verifies every hook executed exactly once, in order, with timing recorded.
- [ ] `BashAdapter.Finalize` no longer calls `exec("bash lib/finalize.sh")` directly — verified by grepping `internal/runner/runner.go` for `"finalize.sh"` and asserting zero matches in non-shim contexts.
- [ ] `lib/finalize.sh` is ≤50 lines after the port (down from 280) and contains no `register_finalize_hook` calls — verified by `wc -l lib/finalize.sh` and `! grep -q register_finalize_hook lib/finalize.sh`.
- [ ] `lib/finalize_summary.sh`, `lib/finalize_summary_collectors.sh`, `lib/run_memory.sh` are deleted (their Go ports — `emit_run_summary`, `emit_run_memory` — fully cover the bodies). `lib/milestone_archival.sh` and `lib/milestone_archival_helpers.sh` are *retained* as transition artifacts because `lib/milestone_split.sh` still imports `_extract_milestone_block` / `_replace_milestone_block` and `tekhton-legacy.sh:2208` still calls `archive_all_completed_milestones` for the V2→V3 migration path; both retire in future milestones (split port in m25-ish, legacy retirement in m28). Net: `lib/` has 3 fewer `.sh` files, not 5. (Acceptance criterion revised post-cycle from "5 deleted" — see Closeout Notes.)
- [ ] `lib/finalize_shim.sh` exists and dispatches all 18 remaining bash-implemented hooks; a unit test in `tests/test_finalize_shim.sh` invokes each hook name and asserts the correct sourcing happens.
- [ ] `tests/test_finalize_parity.sh` exits 0 across three scenarios (success+milestone-complete, success+task-only, failure+milestone-incomplete) on `linux/amd64` and `darwin/amd64`.
- [ ] `tekhton finalize --result <fixture>` exits 0 and produces a byte-identical `RUN_SUMMARY.json` to the captured baseline after timestamp/PID normalization.
- [ ] `make dogfood` exits 0 (self-host matrix still green; new parity gate green).
- [ ] `bash scripts/wedge-audit.sh` exits 0 (audit extended to ban re-introduction of `register_finalize_hook` in bash).
- [ ] `go test ./internal/finalize/... ./cmd/tekhton/...` passes.
- [ ] `bash tests/run_tests.sh` passes; no existing test files break.
- [ ] `docs/v4-phase5-stub.md` LOC budget table shows the new post-m21 count and hook 1 marked "in progress (orchestrator + 8 Go hooks; 18 behind shim)".
- [ ] `VERSION` reads `4.21.0` on milestone close.
- [ ] The implementation run is itself driven by `tekhton run --milestone m21 --complete` — i.e. m21 is the first dogfooded V4 milestone, as predicted by the M20 design doc.

## Watch For

- **Hook order is load-bearing.** Several hooks have implicit ordering dependencies that aren't obvious from names. `_hook_resolve_notes` must run before `_hook_archive_reports` (archive moves the notes file out of the working dir). `_hook_emit_run_summary` reads pipeline state that `_hook_clear_state` would erase if reordered. Treat `lib/finalize.sh:218-243` as authoritative — do not "optimize" the order. The order-mismatch test exists to catch accidental reordering.
- **The parity gate is the dogfooding contract.** The parity gate compares Go-emitted artifacts against captured bash baselines. If the gate finds a real diff (not a timestamp/PID artifact), the bug is in the Go hook — fix it before merging. Do not whitelist the diff; the whole point of m21 is byte-identical output.
- **Don't port the 18 bash hooks ahead of schedule.** The temptation will be "while I'm porting `_hook_archive_milestone`, the changelog hook is right next to it." Don't. Each remaining hook depends on a still-bash subsystem (notes, drift, dashboard, etc.); porting it before its parent ports means dragging the parent's dependencies into m21, which blows scope. The shim exists exactly so that follow-up milestones can port one hook at a time without orchestrator changes.
- **`finalize_shim.sh` is intentionally per-hook, not per-chain.** Spawning bash 18 times per finalize seems wasteful but is the right trade — it preserves the cutover ability of follow-up milestones to delete one `case` entry at a time. A per-chain shim would freeze the hook list and force a big-bang second milestone. Don't combine the shim into one bash invocation.
- **`emit_run_summary` is the most complex pure-Go port.** `lib/finalize_summary.sh` + `lib/finalize_summary_collectors.sh` total ~480 lines and assemble RUN_SUMMARY.json from causal-log/build-fix/recovery/preflight-ui collectors (M132). Most of this is JSON shuffling, but two collectors read mutable state (preflight UI patches, causal-log final-event tail) that needs careful ordering with `causal_log_finalize`. Land `emit_run_summary` last among the eight pure-Go hooks.
- **`tekhton finalize` is a debugging lever, not a user feature.** It's documented in `docs/go-migration.md` as a developer tool. Don't expose it in `tekhton --help` or the README; flag it as "internal" in the Cobra subcommand definition.

## Seeds Forward

- **m22 — Preflight + TUI port:** Replaces `_hook_tui_complete`, `_hook_final_dashboard_status` (TUI side), and the preflight bash subsystem. The `finalize_shim.sh` cases for those hooks are deleted; their Go bodies land in `internal/finalize/hooks/`.
- **m23 — Dashboard emitters port:** Replaces `_hook_final_dashboard_status` (dashboard side) and the standalone `dashboard.sh` subsystem.
- **m24 — Notes/drift/clarify port:** Replaces `_hook_note_acceptance`, `_hook_resolve_notes`, `_hook_cleanup_resolved`, `_hook_drift_artifacts`. This is the biggest remaining bash subsystem (notes alone has 9 `.sh` files); landing it after finalize means the orchestrator already owns the call order.
- **m25 — Health, metrics, project-version port:** Replaces `_hook_health_reassess`, `_hook_record_metrics`, `_hook_project_version_bump`, `_hook_project_version_tag`, `_hook_changelog_append`. Cluster of run-end reporting hooks.
- **`finalize_shim.sh` deletion (m26+):** When every hook has a Go body, the bash shim is unused. Delete the file; collapse `BashAdapter.Finalize` further if anything remains.
- **Parity-gate framework reuse:** The parity diff harness in `tests/test_finalize_parity.sh` generalizes to a shared `tests/lib/parity.sh` for m22–m25 (each adds two or three new scenarios). Build it parameterized in m21 so m22 doesn't re-implement.
- **Dogfooding feedback loop:** Track every bug surfaced during the m21 implementation run as a patch bump (`4.21.1`, `4.21.2`, …) with one-line postmortems in `docs/go-migration.md`. M20's five patch bumps are the precedent; m21 should also produce some, and the rate of bumps per milestone is the dogfooding-health signal.

## Closeout Notes

m21 is the first V4 milestone driven end-to-end by `tekhton run --milestone m21 --complete` (Go orchestrator). All 8 pure-Go hooks landed; the orchestrator, `lib/finalize_shim.sh`, the parity gate, and `tekhton finalize` Cobra subcommand are in place. Two findings from the dogfooded run:

- **Premature deletion of milestone_archival\*.sh.** The plan deleted 5 bash files; cycling agents flagged the resulting `TestDefaultLibHelpersFilesExist` failure as *non-blocking* (misclassification — a CI-failing test is by definition a blocker), so the loop never resolved it. Manual triage restored `lib/milestone_archival.sh` and `lib/milestone_archival_helpers.sh` because `lib/milestone_split.sh:138,226` and `tekhton-legacy.sh:2208` still call functions defined there. Net deletion count is 3, not 5. Drift note added for the proper retirement (m25-ish: port `milestone_split.sh`; m28: retire `tekhton-legacy.sh` V2→V3 migration path).
- **Non-blocking router misclassification.** A CI-failing test was placed in NON_BLOCKING_LOG by `lib/drift_artifacts.sh` / the test-baseline router. The router should not classify a hard test failure as non-blocking, regardless of agent verdict text. Drift entry recorded for m22+ to investigate the routing rule.

Patch bumps during the m21 dogfooded run: 17 (4.21.1 → 4.21.17), reflecting the higher rework volume of porting an orchestrator-shape subsystem vs M20's flatter dispatcher work. None of the bumps reverted earlier work; each was a forward patch.
