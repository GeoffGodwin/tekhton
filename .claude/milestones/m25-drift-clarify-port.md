<!-- milestone-meta
id: "25"
status: "todo"
-->

# m25 — Drift + Clarify Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — fifth dogfooded V4 milestone. Drift and clarify are the last two bash subsystems in the "human-loop" cluster that m22 Seeds Forward grouped with notes. m24 split notes off; m25 finishes the cluster. Drift owns three artifact streams (`DRIFT_LOG.md` for observation logs, `ARCHITECTURE_DECISION_LOG.md` for ADRs, `HUMAN_ACTION_REQUIRED.md` for blocking asks); clarify owns the in-pipeline pause that lets agents request human input via `CLARIFICATIONS.md`. Both are reached from every pipeline run — drift observations get appended during reviewer rework, clarify pauses gate the coder. Until they port, four finalize-shim case arms still source bash, the m21 closeout "non-blocking router misclassified a CI-failing test as non-blocking" drift entry stays open (the fix belongs in this milestone's Go port, not as a bash patch on the dying subsystem), and `lib/failure_context.sh` — half-touched by both notes and drift — cannot delete. |
| **Gap** | Five bash files total 1281 lines: `drift.sh` (349, the orchestrator + observation lifecycle), `drift_artifacts.sh` (297, ADR + HUMAN_ACTION_REQUIRED + non-blocking router with the m21-flagged misclassification bug), `drift_cleanup.sh` (342, non-blocking-log management), `drift_prune.sh` (105, log pruning helper), `clarify.sh` (188, in-pipeline pause + CLARIFICATIONS.md detection/handling). Plus `lib/failure_context.sh` (~200 lines) which is half-owned: notes-side ported in m24, drift-side still bash. The finalize-shim case arm at `lib/finalize_shim.sh:88-96` sources all three drift files for `_hook_drift_artifacts`. The clarification protocol is bash-only: `detect_clarifications` at the start of every stage execution, `handle_clarifications` if any are found, both invoked from `tekhton-legacy.sh` outside the Go runner's awareness. The router bug at `lib/drift_artifacts.sh:177-205::process_drift_artifacts` misclassifies test-failing CI artifacts as non-blocking — a Go-port fix is correct; a bash hotfix on code that's deleting next month is wrong. |
| **m25 fills** | (1) `internal/drift/` becomes the Go-side drift subsystem with five files: `observe.go` (append/count/resolve observations + audit cadence — ports `drift.sh`), `artifacts.go` (ADR + HUMAN_ACTION_REQUIRED writers + the corrected non-blocking router — ports `drift_artifacts.sh`), `nonblocking.go` (non-blocking log lifecycle — ports `drift_cleanup.sh`), `prune.go` (log pruning — ports `drift_prune.sh`), `router.go` (the corrected blocking/non-blocking classifier — fixes the m21 closeout drift entry). (2) `internal/clarify/` becomes the Go-side clarify subsystem with two files: `detect.go` (CLARIFICATIONS.md parser + pause detection — ports `clarify.sh::detect_clarifications` + `load_clarifications_content`), `handle.go` (pause-and-resume integration — ports `clarify.sh::handle_clarifications`). (3) `internal/failure_context/` is created and consumes the full `lib/failure_context.sh` (drift-side reset + the JSON cause-object emitter); the bash file deletes. (4) Three pure-Go finalize hooks land in `internal/finalize/hooks/`: `drift_artifacts`, plus the drift-side half of `failure_context_reset` (the notes-side body from m24 calls into `internal/notes` and now also calls `internal/failure_context.ResetDriftSide`), plus a new `clarify_finalize` hook that clears stale `CLARIFICATIONS.md` entries on success. (5) `tekhton drift {observe,resolve,list,prune,audit-status}` and `tekhton clarify {detect,handle,clear}` Cobra subcommands (Hidden — both are internal seams during transition). (6) The five `lib/drift*.sh` + `lib/clarify.sh` + `lib/failure_context.sh` files delete (seven bash files total). (7) The m21 closeout router-misclassification drift entry resolves: `internal/drift/router.go` correctly routes test-failing CI artifacts as blocking (not non-blocking); a test in `internal/drift/router_test.go` exercises the specific captured case from m21 closeout. (8) A parity gate diffs three artifact files (`DRIFT_LOG.md`, `ARCHITECTURE_DECISION_LOG.md`, `HUMAN_ACTION_REQUIRED.md`) and one clarification round-trip across three scenarios: clean-run (no drift), reviewer-flags-three-observations, clarify-mid-coder-pause. (9) `VERSION` bumps to `4.25.0` on close. |
| **Depends on** | m24 |
| **Files changed** | `internal/drift/`, `internal/clarify/`, `internal/failure_context/`, `internal/finalize/hooks/drift_artifacts.go`, `internal/finalize/hooks/clarify_finalize.go`, `internal/finalize/hooks/failure_context_reset.go`, `internal/finalize/orchestrator.go`, `cmd/tekhton/drift.go`, `cmd/tekhton/clarify.go`, `lib/finalize_shim.sh`, `tekhton-legacy.sh`, `tests/test_drift_parity.sh`, `docs/v4-phase5-stub.md`, `docs/go-migration.md`, seven deletions under `lib/drift*.sh`, `lib/clarify.sh`, `lib/failure_context.sh`. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m21 | Finalize orchestrator in Go; `_hook_drift_artifacts` routed through bash-shim dispatcher; closeout flagged a non-blocking-router misclassification bug to be fixed in the eventual Go port. |
| m23 | TUI writers ported; `internal/atomicfile/` candidate seeded for shared use. |
| m24 | Notes subsystem ported; notes-side half of `failure_context_reset` ported but `lib/failure_context.sh` retained because drift still depended on it. |
| **m25** | **Drift + clarify + failure_context port; the m21 router misclassification fix lands as part of the Go body; seven bash files delete; the human-loop cluster (notes + drift + clarify) is fully Go.** |

---

## Design

### Sequencing note

m25 must land after m24 and before m26. After m24: `lib/failure_context.sh` is half-stranded — m24 ported the notes-side reset to Go but left the bash file intact because drift still called it; m25 finishes the port and deletes the file. Before m26 (dashboard): the dashboard reads `DRIFT_LOG.md` and `HUMAN_ACTION_REQUIRED.md` directly via `lib/dashboard_emitters.sh::emit_dashboard_action_items` (line 465). The m26 author can choose between parsing those files (cheap, file-shape-stable) or calling into `internal/drift` directly; the second option is unblocked by this milestone.

The m21 closeout router-misclassification fix is **part of the deliverable**, not a side note. m24 explicitly deferred it on the rule "do not hotfix bash code that's deleting next month." This is next month. If m25 ships without resolving the drift entry, the rationale for splitting m24→m25 (drift inherits the fix) collapses.

### Goal 1 — `internal/drift/` package layout

Five Go files map onto the five bash files:

| Go file | Ports bash | Key concerns |
|---------|------------|--------------|
| `internal/drift/observe.go` | `lib/drift.sh:22-355` | `AppendObservations`, `CountObservations`, `ResolveObservations`, `ResolveAllObservations`, `AppendEntries`, audit-cadence counters (`runs_since_audit` reset/increment/threshold check). The audit cadence is a `RunsSinceAudit int` field on `*Log` — no more bash global. |
| `internal/drift/artifacts.go` | `lib/drift_artifacts.sh:21-180` | ADR + HUMAN_ACTION_REQUIRED writers. The ADR `_ensure_adl` + `get_next_adl_number` becomes a `*ADR.NextNumber(ctx)` method that scans `ARCHITECTURE_DECISION_LOG.md` for the highest `ADR-NNNN` and returns NNNN+1. Atomic file writes via the same temp-file + os.Rename pattern m23 / m24 established. |
| `internal/drift/nonblocking.go` | `lib/drift_cleanup.sh:19-295` | Non-blocking-log lifecycle: append, count, resolve-addressed, clear-completed. The "addressed" detection is heuristic — matches reviewer-resolved patterns against open entries. Heuristic is preserved verbatim. |
| `internal/drift/prune.go` | `lib/drift_prune.sh:21-105` | Log-pruning helper. Reads pruning thresholds from `internal/config`. |
| `internal/drift/router.go` | `lib/drift_artifacts.sh:177-205::process_drift_artifacts` | **The corrected blocking/non-blocking classifier.** The m21 closeout drift entry described a CI-failing test that the bash router classified as non-blocking. The Go port adds an explicit `[fail|FAIL]` sentinel check on test artifacts before the heuristic regex chain. Tested by `router_test.go::TestRouter_CIFailingTest_IsBlocking` against the captured case. |

The `router.go` file is intentionally small (~80 lines) and named-for-purpose. The bash `process_drift_artifacts` function conflated routing with side-effecting writes; the Go split makes the routing decision pure and testable.

### Goal 2 — `internal/clarify/` package layout

Two Go files:

| Go file | Ports bash | Key concerns |
|---------|------------|--------------|
| `internal/clarify/detect.go` | `lib/clarify.sh::detect_clarifications` + `load_clarifications_content` | Parses `CLARIFICATIONS.md` for unchecked items. Returns `*Document` with `HasUnchecked() bool` + per-item `Question`, `Asker`, `LineNum`. |
| `internal/clarify/handle.go` | `lib/clarify.sh::handle_clarifications` | Pause-and-resume integration: writes a TUI pause event via `internal/tui` (m23), waits for the file to update via fsnotify (the pause loop, polling at 5s tick), exits the pause when all items are checked. |

Clarify pauses are short (typical: the user answers questions and saves the file). The polling cadence is preserved from bash (`while ! all_checked; do sleep 5; done`) but uses `time.NewTicker` rather than `sleep` so cancellation via `ctx.Done()` is immediate.

### Goal 3 — `internal/failure_context/` package

The `lib/failure_context.sh` file is small (~200 lines) but cross-cuts notes + drift. It owns:

- Primary/secondary cause slot helpers (`set_primary_cause`, `set_secondary_cause`)
- Cause summary formatter (`format_failure_cause_summary`)
- JSON cause-object emitter (`_fc_emit_cause_object`, `emit_cause_objects_json`)
- Alias resolution (`resolve_alias_category`, `resolve_alias_subcategory`)
- The reset entry point (`reset_failure_cause_context`) called from the drift-side finalize hook

The Go port is a flat package:

```go
// internal/failure_context/context.go
package failure_context

type Context struct {
    Primary   *Cause
    Secondary *Cause
}

type Cause struct {
    Category    string
    Subcategory string
    Detail      string
}

func (c *Context) SetPrimary(cat, subcat, detail string)
func (c *Context) SetSecondary(cat, subcat, detail string)
func (c *Context) Reset()
func (c *Context) FormatSummary() string
func (c *Context) EmitJSON(w io.Writer) error
```

The alias resolution (`alias_category`, `alias_subcategory`) is data — port to a `var categoryAliases = map[string]string{...}` lookup.

m24 ported the notes-side reset by calling `notes.ClearActive`. After m25, the orchestrated finalize hook (`internal/finalize/hooks/failure_context_reset.go`) calls both `notes.ClearActive` and `failure_context.Context.Reset()`. The hook file already exists from m24 (notes-side); m25 *expands* it (drift-side) and `lib/failure_context.sh` deletes.

### Goal 4 — Finalize hook ports

Three hooks port:

| Hook | Source bash | Notes |
|------|-------------|-------|
| `drift_artifacts` | `_hook_drift_artifacts` (sources `lib/drift*.sh`) | Pure-Go body calling `internal/drift.ProcessArtifacts`. Replaces the case arm at `lib/finalize_shim.sh:88-96`. |
| `failure_context_reset` | already half-Go in m24 | m24 created the file with the notes-side body; m25 adds the `failure_context.Reset()` call and removes the explicit dependency on the bash `lib/failure_context.sh`. |
| `clarify_finalize` (new) | n/a — clarify currently runs mid-pipeline, not at finalize | A new finalize hook that clears stale `CLARIFICATIONS.md` entries on success disposition. Registered last in the hook order (just before `archive_reports`). The new hook is small (~30 lines) and exists because mid-run clarify state can leave stale entries that the next run sees; bash currently relies on `_hook_archive_reports` to move the file aside, but the Go orchestrator already had a TODO for explicit clarify cleanup. m25 fills it. |

The case arm `_hook_drift_artifacts` removes from `lib/finalize_shim.sh`. The order-mismatch test in `internal/finalize/orchestrator_test.go` updates to expect the new Go bodies.

### Goal 5 — `tekhton drift` and `tekhton clarify` Cobra subcommands

Both Hidden — these are internal seams during the migration, not user-facing utilities like `tekhton note`.

```
tekhton drift observe   --tag TAG --detail TEXT
tekhton drift resolve   <ID> [--all]
tekhton drift list      [--state open|resolved] [--format md|json]
tekhton drift prune     [--max-resolved N]
tekhton drift audit-status                       # report runs_since_audit + threshold

tekhton clarify detect                           # exit 0 if no unchecked, exit 1 if any
tekhton clarify handle  [--timeout SECS]         # block until all checked, or timeout
tekhton clarify clear                            # finalize-time cleanup of stale entries
```

The mid-pipeline clarify pause currently runs from `tekhton-legacy.sh:~1800` between stages. After m25, the Go runner (`internal/runner/runner.go`) calls `clarify.Detect` + `clarify.Handle` directly between stages — no bash subshell, no `tekhton clarify` invocation needed in the production path. The CLI subcommand exists for standalone testing.

### Goal 6 — The m21 router-misclassification fix

The captured case from m21 closeout (paraphrased): a CI run failed a specific test; the run artifact landed in `.tekhton/` with a header that the bash regex chain in `process_drift_artifacts` matched against the "non-blocking observation" pattern instead of the "blocking action required" pattern. The user reported it as a drift entry; the m21 author deferred the fix.

The fix in `internal/drift/router.go`:

```go
func Route(artifact *Artifact) Disposition {
    // Explicit CI-failure sentinel takes precedence over heuristics.
    if hasCIFailureSentinel(artifact) {
        return Blocking
    }
    // Existing heuristic chain (preserved from bash).
    if matchesNonBlockingPattern(artifact) {
        return NonBlocking
    }
    return Blocking // safe default
}

func hasCIFailureSentinel(a *Artifact) bool {
    // matches "[FAIL]" or "[fail]" in the artifact header — explicit signal
    // that a CI test failed, which the bash heuristic missed when the artifact
    // also contained reviewer-style language elsewhere.
    return ciFailureRegex.MatchString(a.Header())
}
```

`internal/drift/router_test.go::TestRouter_CIFailingTest_IsBlocking` exercises the captured case. The fixture lives at `internal/drift/testdata/m21_router_misclassification/`. A second test `TestRouter_PureReviewerObservation_IsNonBlocking` ensures the fix does not over-correct (i.e., a pure reviewer observation without CI failure remains non-blocking).

### Goal 7 — Parity gate

`tests/test_drift_parity.sh` runs three scenarios:

1. **Clean-run (no drift):** fixture project with empty `DRIFT_LOG.md`, no `CLARIFICATIONS.md`, finalize runs. Expected: all three artifact files end empty (or with only the header), `_hook_drift_artifacts` is a no-op, `_hook_clarify_finalize` is a no-op.
2. **Reviewer-flags-three-observations:** synthetic reviewer output that produces three observations (one ADR, one HUMAN_ACTION, one non-blocking note). Expected: `ARCHITECTURE_DECISION_LOG.md` gains one ADR with correct `ADR-NNNN` numbering; `HUMAN_ACTION_REQUIRED.md` gains one item; `DRIFT_LOG.md` gains one non-blocking observation. All three files byte-identical to bash baseline.
3. **Clarify-mid-coder-pause:** coder stage asks one clarification question; the pause writes `CLARIFICATIONS.md`. The test simulates the user checking the box. The pipeline resumes. Finalize runs and `_hook_clarify_finalize` archives the resolved file. Expected: the clarify pause is detected within one polling tick, the resume is detected within one polling tick after the box is checked, and the archived file matches bash baseline.

The parity gate uses the shared `tests/lib/parity.sh` driver established in m23.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/drift/observe.go` | Create | Observation lifecycle (ports `drift.sh`). |
| `internal/drift/artifacts.go` | Create | ADR + HUMAN_ACTION writers (ports `drift_artifacts.sh:21-180`). |
| `internal/drift/nonblocking.go` | Create | Non-blocking-log lifecycle (ports `drift_cleanup.sh`). |
| `internal/drift/prune.go` | Create | Log pruning (ports `drift_prune.sh`). |
| `internal/drift/router.go` | Create | Corrected blocking/non-blocking router; fixes m21 closeout drift entry. |
| `internal/drift/*_test.go` | Create | Per-file unit tests + the captured-misclassification regression test. |
| `internal/drift/testdata/` | Create | Fixtures including `m21_router_misclassification/`. |
| `internal/clarify/detect.go` | Create | `CLARIFICATIONS.md` parser + pause detection. |
| `internal/clarify/handle.go` | Create | Pause-and-resume integration; calls `internal/tui` for the pause event. |
| `internal/clarify/*_test.go` | Create | Detect + handle unit tests with a synthetic polling clock. |
| `internal/failure_context/context.go` | Create | Primary/secondary cause slots, format, JSON emitter, alias resolution. |
| `internal/failure_context/context_test.go` | Create | Round-trip + alias-resolution tests. |
| `internal/finalize/hooks/drift_artifacts.go` | Create | `_hook_drift_artifacts` Go body. |
| `internal/finalize/hooks/failure_context_reset.go` | Modify | Expand m24's notes-only body to also call `failure_context.Reset()`. |
| `internal/finalize/hooks/clarify_finalize.go` | Create | New finalize hook clearing stale `CLARIFICATIONS.md` on success. |
| `internal/finalize/orchestrator.go` | Modify | Wire the three hook updates; remove `_hook_drift_artifacts` from `shim.go` dispatch. |
| `internal/finalize/orchestrator_test.go` | Modify | Update expected hook-order list. |
| `internal/runner/runner.go` | Modify | Replace mid-pipeline bash clarify call with `clarify.Detect` + `clarify.Handle`. |
| `cmd/tekhton/drift.go` | Create | `tekhton drift` Cobra subcommand tree (Hidden). |
| `cmd/tekhton/clarify.go` | Create | `tekhton clarify` Cobra subcommand tree (Hidden). |
| `lib/finalize_shim.sh` | Modify | Remove the `_hook_drift_artifacts` case arm. |
| `tekhton-legacy.sh` | Modify | Replace inline clarify calls with `tekhton clarify ...`; remove `source lib/clarify.sh`. |
| `tests/test_drift_parity.sh` | Create | Three-scenario byte-identical parity gate. |
| `lib/drift.sh` | Delete | Ported to `internal/drift/observe.go`. |
| `lib/drift_artifacts.sh` | Delete | Ported to `internal/drift/artifacts.go` + `router.go` (with the m21 fix). |
| `lib/drift_cleanup.sh` | Delete | Ported to `internal/drift/nonblocking.go`. |
| `lib/drift_prune.sh` | Delete | Ported to `internal/drift/prune.go`. |
| `lib/clarify.sh` | Delete | Ported to `internal/clarify/`. |
| `lib/failure_context.sh` | Delete | Ported to `internal/failure_context/`. |
| `docs/v4-phase5-stub.md` | Modify | Update rows 6 + 7 status to "done (m25)"; update LOC budget table. |
| `docs/go-migration.md` | Modify | Record the m21 router-misclassification fix with a one-paragraph postmortem (root cause, the Go fix, the regression test). |

---

## Acceptance Criteria

- [ ] `internal/drift/router.go::Route` returns `Blocking` for the captured m21 misclassification fixture in `internal/drift/testdata/m21_router_misclassification/`; verified by `internal/drift/router_test.go::TestRouter_CIFailingTest_IsBlocking`.
- [ ] A second test `TestRouter_PureReviewerObservation_IsNonBlocking` exercises a fixture without the `[FAIL]` sentinel and asserts `NonBlocking` — ensures the fix is not an over-correction.
- [ ] `internal/drift/artifacts.go::NextADRNumber` returns the correct next number against a fixture `ARCHITECTURE_DECISION_LOG.md` containing `ADR-0007` as the highest; result is `8`.
- [ ] All five `lib/drift*.sh` files are deleted; `find lib -name 'drift*.sh'` returns nothing.
- [ ] `lib/clarify.sh` and `lib/failure_context.sh` are deleted; `find lib -name 'clarify.sh' -o -name 'failure_context.sh'` returns nothing.
- [ ] No remaining bash file sources any drift/clarify/failure_context bash — `grep -rn 'source.*\(lib/drift\|lib/clarify\|lib/failure_context\)' lib stages tekhton-legacy.sh` returns zero matches.
- [ ] No remaining bash file calls drift functions directly — `grep -rnE '(append_drift_observations|process_drift_artifacts|append_architecture_decision|append_human_action|detect_clarifications|handle_clarifications|reset_failure_cause_context)\b' lib stages tekhton-legacy.sh` returns zero matches (occurrences inside Cobra subcommand files and docs are fine).
- [ ] Three Go finalize hook files exist (`drift_artifacts.go`, `clarify_finalize.go`, plus the expanded `failure_context_reset.go`); all three are registered in `internal/finalize/orchestrator.go`'s hook list as pure-Go (not shim) entries.
- [ ] `lib/finalize_shim.sh` no longer matches `_hook_drift_artifacts` in any case arm — `grep -n '_hook_drift_artifacts' lib/finalize_shim.sh` returns zero matches inside case statements.
- [ ] `tekhton drift --help` lists `observe`, `resolve`, `list`, `prune`, `audit-status`; each subcommand `--help` exits 0.
- [ ] `tekhton clarify --help` lists `detect`, `handle`, `clear`; each subcommand `--help` exits 0.
- [ ] `tekhton clarify detect` exits 0 when no unchecked items in `CLARIFICATIONS.md`, exits 1 when any are present — verified by two fixtures.
- [ ] `internal/runner/runner.go` no longer execs `lib/clarify.sh` mid-pipeline; calls `clarify.Detect` + `clarify.Handle` directly. Verified by `grep -n 'lib/clarify\|detect_clarifications' internal/runner/runner.go` returning zero matches.
- [ ] `tests/test_drift_parity.sh` exits 0 across all three documented scenarios (clean-run, reviewer-flags-three, clarify-mid-coder-pause).
- [ ] `make dogfood` exits 0 (self-host parity matrix still green).
- [ ] `bash scripts/wedge-audit.sh` exits 0 (audit extended to forbid re-introduction of drift/clarify/failure_context functions as bash definitions).
- [ ] `go test ./internal/drift/... ./internal/clarify/... ./internal/failure_context/... ./internal/finalize/... ./cmd/tekhton/...` passes.
- [ ] `bash tests/run_tests.sh` reports zero new failures vs the m24 close baseline. Existing `test_drift_*.sh` and `test_clarify*.sh` tests are either updated to drive the Cobra subcommands or skip-stubbed with pointers to their Go replacements. Updating is preferred.
- [ ] The m21 closeout drift entry is marked **resolved** in `DRIFT_LOG.md` with a reference to this milestone (`m25 router fix`); the resolution is visible in `tekhton drift list --state resolved`.
- [ ] `docs/v4-phase5-stub.md` LOC budget table shows the new post-m25 count; rows 6 and 7 marked "done (m25 — drift subsystem + clarify ported; seven bash files deleted; m21 router fix landed)".
- [ ] `docs/go-migration.md` contains a `## m25 router fix` postmortem section with root cause, the Go fix, and the regression test name.
- [ ] `VERSION` reads `4.25.0` on milestone close.
- [ ] `.claude/milestones/MANIFEST.cfg` has the row `m25|Drift and Clarify Port|done|m24|m25-drift-clarify-port.md|phase5`.
- [ ] The implementation run is itself driven by `tekhton run --milestone m25 --complete`.

## Watch For

- **The m21 router fix is mandatory, not optional.** If implementation pressure tempts deferring it to a patch milestone, refuse — the fix being landed in the Go port is the entire reason the m24/m25 split exists. m24 explicitly cited "the fix belongs in the m25 Go port" as the rationale; reneging on that breaks the seed-forward contract. Adding the regression test before the router code is written (TDD style) is the right way to lock the fix in.
- **`lib/failure_context.sh` deletion is the synchronization point.** m24 set it up to die here. If `internal/failure_context/` doesn't fully cover the bash surface (primary/secondary slots, format, JSON emitter, alias resolution, reset), the bash file can't delete — and m24's "notes-side ported, drift-side waits" rationale was a lie. Audit every function in `lib/failure_context.sh` against the Go package surface before deleting.
- **The new `clarify_finalize` hook is the only behavior addition in m25.** Everything else is a port. The new hook fills a TODO in the existing finalize chain (clear stale CLARIFICATIONS.md on success) — it's a small, justified addition. Do not add other behavior changes during the port; if a bug surfaces in drift_cleanup that wasn't in the m21 closeout report, file a follow-up drift entry rather than fixing it in this milestone (m26+ owns dashboard, which is the next reasonable home for non-port-essential drift fixes).
- **Clarify pause polling cadence must survive the port.** Bash polled CLARIFICATIONS.md every 5 seconds via `sleep 5`. The Go port uses `time.NewTicker(5 * time.Second)` so context cancellation is responsive. Do not make the cadence configurable in this milestone — that's a feature, not a port. If users complain about the 5s latency, file a feature ticket against m26+.
- **The mid-pipeline clarify integration is the only Go-runner code change.** Today's bash dispatch sits in `tekhton-legacy.sh` between stages. The Go runner ports this into `internal/runner/runner.go` as a call between `runStage(stageN)` and `runStage(stageN+1)`. Be careful: the legacy bash also dispatched clarify at the very start of the pipeline (pre-intake). Preserve that — it's how seed clarifications carry over from a prior interrupted run.
- **Don't expand to dashboard in this milestone.** The dashboard reads drift and human-action files directly. Tempting to port the dashboard emitter for those two files at the same time as their producers. Resist — m26 is dashboard, and the dashboard subsystem has its own shape (683 LOC in `dashboard_emitters.sh` alone) that wants its own milestone.

## Seeds Forward

- **m26 — Dashboard emitters port:** Dashboard reads `DRIFT_LOG.md`, `HUMAN_ACTION_REQUIRED.md`, `ARCHITECTURE_DECISION_LOG.md` directly via `lib/dashboard_emitters.sh:465-680`. After m25, the Go dashboard port has two options: parse the files (cheap, file-shape is stable, no cross-package dependency) or import `internal/drift` and call `Drift.List()` directly. Prefer the second — fewer parsers, type-safe, one-shot.
- **Failure-context emitter as a structured event source:** `failure_context.Context.EmitJSON` is the same shape the causal log consumes. m26 should consider routing failure-context emissions through the causal log directly rather than maintaining a separate JSON-on-stderr channel. Not a port change — a follow-up idea.
- **`internal/atomicfile/` extraction trigger:** If m25's drift artifact writers and m23's TUI status writer and m24's notes writer all reach for the same temp-file + os.Rename pattern (three real users now), promote it to `internal/atomicfile/` here. The extraction is mechanical: take m23's existing implementation, generalise it, update three callers, delete duplicates.
- **Polling-with-cancellation pattern:** `internal/clarify/handle.go` is the first polling-with-cancellation site in the Go codebase. Future milestones (m26 dashboard live refresh, m27 plan-interview wait-for-user) will reach for the same shape. Consider extracting a small `internal/poll/Until(ctx, interval, predicate)` helper — not necessary in m25, but a candidate for promotion in m26.
- **Phase 5 LOC trajectory:** Post-m25 the bash count drops by ~1500 LOC (drift + clarify + failure_context + the case-arm cleanup). Combined with m22 (~1500), m23 (~1117), m24 (~2188), the total Phase 5 reduction is ~6300 LOC across four milestones. The remaining bash surface is ~3300 LOC: dashboard (1542) + init/plan family (~1500) + the long-tail crumbs (~300). Dashboard alone is a milestone (m26); init/plan/draft-milestones is a single bigger milestone (m27 — comparable to m24 in size). Long-tail is m28; legacy.sh deletion is m29. The Phase Plan's "8 milestones for Phase 5" arc tracks.
- **Dogfooding feedback loop:** Continue patch-bump tracking. m25 is mid-sized (~1281 LOC + a behavior-changing router fix); expect 12-20 patch bumps. The router fix specifically increases dogfooding risk because the fix could surface latent bugs in callers that relied on the misclassification — track those especially carefully.
