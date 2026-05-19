<!-- milestone-meta
id: "23"
status: "todo"
-->

# m23 — TUI Ops Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — third dogfooded V4 milestone. M22 ported preflight; the TUI ops layer is the next-highest-leverage Phase 5 port because it sits on the writer side of the longest-lived cross-language seam in the codebase. Every stage transition, every agent call, every quota pause, and every substage open/close currently passes through bash to write `tui_status.json`, which the Python sidecar (`tools/tui.py`) polls. The Go side already owns the *spawn* (m19 — `internal/tui/sidecar.go`) but not the *writers*, so the supervisor still hands control to bash dozens of times per run for the most-touched real-time state in the system. Until the writers port, the contract between Go and the Python sidecar runs through bash. |
| **Gap** | `lib/tui.sh` (281) + `lib/tui_helpers.sh` (274) + `lib/tui_liveness.sh` (73) + `lib/tui_ops.sh` (305) + `lib/tui_ops_pause.sh` (111) + `lib/tui_ops_substage.sh` (73) total 1117 lines of bash and 60+ `_TUI_*` globals. The writer side is split across five files because of the 300-line bash ceiling, not domain boundaries — `tui_helpers.sh` and `tui_liveness.sh` exist only because `tui.sh` would otherwise exceed the ceiling. `tui_status.v1` is named in `DESIGN_v4.md` §JSON Protocol Versioning as a day-one contract but the proto file does not yet exist in `internal/proto/`. `BashHookRunner.runStage` and finalize hooks `_hook_tui_complete` + the TUI side of `_hook_final_dashboard_status` (see `lib/finalize_shim.sh:143-147`) still source `lib/tui.sh` to call `tui_complete`. The Python sidecar is not in scope (`DESIGN_v4.md` Decision §6: preserve Python `tools/` indefinitely) but its contract is the load-bearing artifact this milestone formalises. |
| **m23 fills** | (1) `internal/proto/tui.go` formalises `tui.status.v1` with full field definitions matching the current `_tui_json_build_status` output. (2) `internal/tui/` expands beyond the spawn-only m19 surface: `ops.go` (stage begin/end, update agent, update stage, append event), `pause.go` (enter/update/exit pause), `substage.go` (begin/end + auto-close), `builder.go` (status JSON construction, ports `_tui_json_build_status` + helpers), `liveness.go` (atomic-rename writer + sampled liveness probe). (3) `tekhton tui {start,stop,complete,stage-begin,stage-end,update-stage,update-agent,append-event,substage-begin,substage-end,pause-enter,pause-update,pause-exit}` Cobra subcommand tree (Hidden) becomes the standalone bash-caller seam — same pattern as m22 `tekhton preflight`. (4) The six `lib/tui*.sh` files delete; bash callers (`lib/agent.sh`, `lib/agent_spinner.sh`, `lib/quota.sh`, `lib/quota_sleep.sh`, `stages/coder.sh`, `stages/architect.sh`, `stages/review.sh`, `tekhton-legacy.sh`) route through `tekhton tui ...` directly. (5) `_hook_tui_complete` ports to a pure-Go hook in `internal/finalize/hooks/tui_complete.go`; the `lib/finalize_shim.sh:143` case arm for `_hook_tui_complete` removes (the `_hook_final_dashboard_status` arm stays — it ports with dashboard in m26). (6) The atomic-rename writer + sampled liveness probe semantics (`lib/tui_liveness.sh:31-79`) preserve byte-for-byte: same temp-file dance, same 20-write sampling interval, same `kill -0` probe shape. (7) A parity gate diffs `tui_status.json` across three captured-run scenarios (green-path, pause/resume cycle, sidecar-death-mid-run) between a captured bash baseline and the m23 Go writer. (8) `VERSION` bumps to `4.23.0` on close. |
| **Depends on** | m22 |
| **Files changed** | `internal/proto/tui.go`, `internal/tui/ops.go`, `internal/tui/pause.go`, `internal/tui/substage.go`, `internal/tui/builder.go`, `internal/tui/liveness.go`, `cmd/tekhton/tui.go`, `internal/finalize/hooks/tui_complete.go`, `internal/finalize/orchestrator.go`, `lib/finalize_shim.sh`, `lib/agent.sh`, `lib/agent_spinner.sh`, `lib/quota.sh`, `lib/quota_sleep.sh`, `stages/coder.sh`, `stages/architect.sh`, `stages/review.sh`, `tekhton-legacy.sh`, `tests/test_tui_parity.sh`, `docs/v4-phase5-stub.md`, six deletions under `lib/tui*.sh`. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m19 | `internal/tui/sidecar.go` lands — spawn + stop logic moves to Go; writers stay bash. |
| m21 | Finalize orchestrator in Go; `_hook_tui_complete` routed through bash-shim dispatcher. |
| m22 | Preflight subsystem ported in full; sets the "one subsystem, one milestone" precedent m23 follows. |
| **m23** | **TUI writers port; `tui.status.v1` proto formalised; six bash files delete; one finalize-shim case arm removes.** |

---

## Design

### Sequencing note

m23 must land before m26 (dashboard emitters port). Reason: `_hook_final_dashboard_status` in `lib/finalize_shim.sh:143-147` currently sources both `lib/tui.sh` and dashboard bash. After m23 deletes the TUI files, that hook still works because the case arm in finalize_shim.sh sources dashboard bash directly and the TUI calls inside the hook now route through `tekhton tui ...`. If the order flipped (dashboard before TUI), the shim arm would lose its anchor file mid-flight.

m23 must land *after* m22. Reason: m22 established the "port a subsystem, delete the bash files, add a Cobra subcommand, route bash callers through the subcommand" pattern. m23 is a direct clone of that pattern; deviating from it before m22 has shipped one full dogfood cycle costs the parity test framework reuse.

### Goal 1 — Formalise `tui.status.v1` proto

The current `_tui_json_build_status` (`lib/tui_helpers.sh:188`) emits a JSON object with the following fields, read by `tools/tui.py:status_loop()`:

```go
// internal/proto/tui.go
package proto

const TUIStatusV1 = "tekhton.tui.status.v1"

type TUIStatusV1Envelope struct {
    Proto   string            `json:"proto"`     // = TUIStatusV1
    RunID   string            `json:"run_id"`
    Payload TUIStatusV1Payload `json:"payload"`
}

type TUIStatusV1Payload struct {
    Milestone        string            `json:"milestone"`
    MilestoneTitle   string            `json:"milestone_title"`
    Task             string            `json:"task"`
    Attempt          int               `json:"attempt"`
    MaxAttempts      int               `json:"max_attempts"`
    ElapsedSecs      int               `json:"elapsed_secs"`
    Stage            TUIStageBlock     `json:"stage"`
    Agent            TUIAgentBlock     `json:"agent"`
    StagePills       []TUIStagePill    `json:"stage_pills"`
    Events           []TUIEventEntry   `json:"events"`
    ActionItems      []TUIActionItem   `json:"action_items"`
    Complete         bool              `json:"complete"`
    Verdict          *string           `json:"verdict"`
    Pause            *TUIPauseBlock    `json:"pause,omitempty"`
    Substage         *TUISubstageBlock `json:"substage,omitempty"`
}
```

The Python sidecar reads this file; bumping to `v2` requires a coordinated Python release. v1 must lock the field set before m23 ships its first dogfood pass.

The `proto` envelope is new — the bash writer emits a bare payload, no `proto` field. The Python sidecar must continue accepting both shapes during the transition. Two acceptable strategies:

- **Strategy A (recommended).** Python sidecar tolerates missing `proto` field, treats it as v1 implicitly. Go writer always stamps the `proto` field. One Python-side patch (~5 lines) ships in `tools/tui.py` as part of m23.
- **Strategy B.** Go writer omits the `proto` envelope until m24+ when bash callers are gone. Defers the contract but loses skew-detection at the most-touched seam.

Default: Strategy A. The Python patch is trivial and the skew-loud-not-silent invariant from `DESIGN_v4.md` Risk §7 is worth the small Python diff.

### Goal 2 — Port the writers under `internal/tui/`

Six files, mapped one-to-one onto existing bash files:

| Go file | Ports bash | Key concerns |
|---------|------------|--------------|
| `internal/tui/ops.go` | `lib/tui_ops.sh:26-300` | `StageBegin`, `StageEnd`, `UpdateStage`, `UpdateAgent`, `AppendEvent`, `AppendSummaryEvent`, `FinishStage`, `ResetForNextMilestone`. Stage lifecycle owns the pill row and timing column. |
| `internal/tui/pause.go` | `lib/tui_ops_pause.sh` | `EnterPause`, `UpdatePause`, `ExitPause`. Drives the quota-pause active-bar render in the sidecar. Used by M124's chunked sleep — pause state must survive the writer transition unchanged. |
| `internal/tui/substage.go` | `lib/tui_ops_substage.sh` | `SubstageBegin`, `SubstageEnd`, `autoCloseSubstageIfOpen`. The auto-close-and-warn rule from `docs/tui-lifecycle-model.md` is preserved — substage that's still open when its parent stage ends emits a warning event and auto-closes. |
| `internal/tui/builder.go` | `lib/tui_helpers.sh:22-280` | Build `TUIStatusV1Payload` from internal state. Includes the seven `_tui_json_*` builders. |
| `internal/tui/liveness.go` | `lib/tui_liveness.sh` | `WriteStatus(atomic)` + `checkSidecarLiveness(sampled)`. Same temp-file dance, same 20-write sampling cadence, same `kill -0` probe. |
| `internal/tui/state.go` | The 60+ `_TUI_*` globals in `lib/tui.sh` + `lib/tui_ops.sh` | Single `State` struct held by the supervisor. Mutators are methods. No globals. |

The 60+ bash globals (`_TUI_ACTIVE`, `_TUI_PID`, `_TUI_STATUS_FILE`, `_TUI_CURRENT_STAGE_LABEL`, `_TUI_CURRENT_STAGE_NUM`, …) collapse into one `*State` value that the supervisor passes to mid-run callers. Bash callers don't see the struct — they see the `tekhton tui ...` CLI surface.

State persistence between subprocess invocations: the bash callers each issue one `tekhton tui ...` call per state mutation. To make this work without an IPC layer, the Go side reads `tui_status.json` on every CLI invocation, mutates the in-memory payload, and writes the file back atomically. The cost is one read + one atomic-write per mutation; the bash version already pays the cost of one write per mutation. The added read cost is a `stat + open + decode` on a typically <8KB file — negligible compared to the agent calls and stage transitions that gate each mutation.

### Goal 3 — `tekhton tui` Cobra subcommand tree

```
tekhton tui start         # spawn the sidecar (already exists from m19)
tekhton tui stop          # stop the sidecar (already exists from m19)
tekhton tui complete      # graceful complete-and-hold-on-enter
tekhton tui stage-begin   --label "Coder" --num 3 --total 7 --model claude-opus
tekhton tui stage-end     --verdict pass --duration 42
tekhton tui update-stage  --label "Coder" --duration 12
tekhton tui update-agent  --turns-used 4 --turns-max 100 --status active
tekhton tui append-event  --kind info --message "build passed"
tekhton tui substage-begin --label "Build fix attempt 2" --parent coder
tekhton tui substage-end  --verdict pass
tekhton tui pause-enter   --reason "quota exhausted" --resumes-at "2026-05-18T16:30Z"
tekhton tui pause-update  --remaining-secs 240
tekhton tui pause-exit
```

All Hidden. Per-subcommand handlers live in `cmd/tekhton/tui.go` (one file is fine — it'll land at ~250-350 lines, well under the 600-line Go soft target). Each handler builds an `Input`, calls the corresponding method on the `internal/tui.State` it reconstructs from disk, writes the file back.

### Goal 4 — Bash caller migration

Eight bash callers stop sourcing TUI files. Each callsite migrates the same way:

```bash
# Before (lib/agent.sh)
tui_update_agent "active" "$turns_used" "$turns_max"

# After
"$tekhton_bin" tui update-agent \
    --status active \
    --turns-used "$turns_used" \
    --turns-max "$turns_max"
```

The `tekhton_bin` resolution uses the same shape as m22's `run_preflight_checks` — `${TEKHTON_BIN:-${TEKHTON_HOME:-.}/bin/tekhton}` with a warn-and-no-op fallback if the binary isn't built.

Callers by file:

| Caller | Callsites | TUI APIs used |
|--------|-----------|---------------|
| `lib/agent.sh` | ~6 | `tui_update_agent`, `tui_append_event`, `run_op` |
| `lib/agent_spinner.sh` | ~3 | `tui_update_agent`, `tui_append_event` |
| `lib/quota.sh` | ~4 | `tui_enter_pause`, `tui_exit_pause`, `tui_append_event` |
| `lib/quota_sleep.sh` | ~2 | `tui_update_pause` (every 5s tick) |
| `stages/coder.sh` | ~5 | `tui_substage_begin`, `tui_substage_end`, `run_op` |
| `stages/architect.sh` | ~3 | `run_op` |
| `stages/review.sh` | ~3 | `run_op` |
| `tekhton-legacy.sh` | ~2 | `tui_start`, `tui_stop`, `tui_complete` |

Total: ~28 callsites. Each is a mechanical substitution. The substitution count is the parity-risk surface — get one wrong and the sidecar shows stale state.

### Goal 5 — `_hook_tui_complete` ports to Go

The hook in `lib/tui.sh:240-270` becomes `internal/finalize/hooks/tui_complete.go`. It calls the same state machine the new `internal/tui` package owns: set `complete=true`, set verdict from `TEKHTON_RUN_DISPOSITION`, write status atomically, signal the sidecar to enter hold-mode.

`internal/finalize/orchestrator.go` registers the new hook in the existing 26-hook order — the registration line moves from "shim dispatcher" to "Go body". The order-mismatch test (`internal/finalize/orchestrator_test.go:TestHookOrder_MatchesBashRegistration`) requires updating the expected order list; the bash hook order in `lib/finalize.sh:218-243` does not change.

The `_hook_final_dashboard_status` arm in `finalize_shim.sh` stays — its TUI calls now route through the Go binary via `tekhton tui ...` rather than sourcing `lib/tui.sh`. That hook ports in m26 alongside the dashboard subsystem.

### Goal 6 — Parity gate

`tests/test_tui_parity.sh` runs three captured scenarios:

1. **Green-path:** full pipeline run from `tui start` through three stages (intake, coder, review) to `tui complete`. Expected: `tui_status.json` payload at every mutation point matches the bash baseline byte-for-byte after timestamp normalisation.
2. **Pause/resume cycle:** quota exhaustion mid-coder triggers `tui pause-enter`, three `pause-update` ticks, then `pause-exit`. Expected: pause block field shape unchanged; `events` ring buffer entries match.
3. **Sidecar-death-mid-run:** kill the Python sidecar at second 30, continue the run another 60 seconds, assert `_TUI_ACTIVE=false` is reached within 20 mutations (the sampling interval) and that subsequent `tekhton tui ...` calls cleanly no-op. The pidfile is removed; one warning event is logged. Matches `lib/tui_liveness.sh:55-79` semantics exactly.

The parity-gate framework should reuse the scaffolding being extracted from m22's `tests/test_preflight_parity.sh`. m22 Seeds Forward called this out — m23 is the second consumer that justifies extracting `tests/lib/parity.sh`. Do that here.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/proto/tui.go` | Create | `tui.status.v1` envelope + payload + sub-block structs. |
| `internal/tui/ops.go` | Create | Stage/agent/event mutators (ports `lib/tui_ops.sh`). |
| `internal/tui/pause.go` | Create | Pause enter/update/exit (ports `lib/tui_ops_pause.sh`). |
| `internal/tui/substage.go` | Create | Substage begin/end + auto-close (ports `lib/tui_ops_substage.sh`). |
| `internal/tui/builder.go` | Create | Status JSON builders (ports `lib/tui_helpers.sh`). |
| `internal/tui/liveness.go` | Create | Atomic-rename writer + sampled liveness probe (ports `lib/tui_liveness.sh`). |
| `internal/tui/state.go` | Create | `State` struct + load/save round-trip for cross-subprocess persistence. |
| `internal/tui/*_test.go` | Create | Per-file unit tests + state round-trip + auto-close invariants. |
| `cmd/tekhton/tui.go` | Create | Cobra subcommand tree (Hidden). |
| `cmd/tekhton/tui_test.go` | Create | CLI smoke + state round-trip via subprocess. |
| `internal/finalize/hooks/tui_complete.go` | Create | `_hook_tui_complete` Go body. |
| `internal/finalize/orchestrator.go` | Modify | Wire `tui_complete` hook in-process; remove from `shim.go` dispatch list. |
| `lib/finalize_shim.sh` | Modify | Remove the `_hook_tui_complete` arm of the case statement. |
| `lib/agent.sh` | Modify | Replace `tui_*` callsites with `tekhton tui ...` invocations. |
| `lib/agent_spinner.sh` | Modify | Same — TUI callsite substitution. |
| `lib/quota.sh` | Modify | Replace `tui_enter_pause` / `tui_exit_pause` / `tui_append_event` callsites. |
| `lib/quota_sleep.sh` | Modify | Replace `tui_update_pause` chunked-sleep callsite. |
| `stages/coder.sh` | Modify | Replace `tui_substage_*` and `run_op` callsites. |
| `stages/architect.sh` | Modify | Replace `run_op` callsites. |
| `stages/review.sh` | Modify | Replace `run_op` callsites. |
| `tekhton-legacy.sh` | Modify | Drop `source lib/tui.sh`; replace `tui_start` / `tui_stop` / `tui_complete` with `tekhton tui ...`. |
| `tools/tui.py` | Modify | Tolerate `proto` envelope field; treat missing as implicit v1 (Strategy A). |
| `tests/test_tui_parity.sh` | Create | Three-scenario byte-identical parity gate. |
| `tests/lib/parity.sh` | Create | Shared parity-gate driver extracted from m22's `test_preflight_parity.sh` and consumed by m23 + m25 + m26. |
| `lib/tui.sh` | Delete | Ported to `internal/tui/state.go` + `cmd/tekhton/tui.go` start/stop/complete handlers. |
| `lib/tui_helpers.sh` | Delete | Ported to `internal/tui/builder.go`. |
| `lib/tui_liveness.sh` | Delete | Ported to `internal/tui/liveness.go`. |
| `lib/tui_ops.sh` | Delete | Ported to `internal/tui/ops.go`. |
| `lib/tui_ops_pause.sh` | Delete | Ported to `internal/tui/pause.go`. |
| `lib/tui_ops_substage.sh` | Delete | Ported to `internal/tui/substage.go`. |
| `docs/v4-phase5-stub.md` | Modify | Update row 3 status to "done (m23)"; update LOC budget table with the post-m23 count. |

---

## Acceptance Criteria

- [ ] `internal/proto/tui.go` exists and declares `TUIStatusV1` const equal to `"tekhton.tui.status.v1"`; the envelope and payload structs round-trip through `encoding/json` with a fixture in `internal/proto/tui_test.go`.
- [ ] `internal/tui/` exports `Ops`, `Pause`, `Substage`, `Builder`, `Liveness` surfaces; each `internal/tui/<name>_test.go` covers at least one happy-path + one error path apiece.
- [ ] `internal/tui/state.go::State.SaveAtomic` writes via `os.Rename` from a tmpfile in the same directory — verified by a test that pre-populates the destination with garbage and asserts atomicity under a faulted read.
- [ ] `internal/tui/liveness.go::CheckSidecarLiveness` samples `kill -0` exactly once per 20 invocations; covered by a unit test that calls `WriteStatus` 21 times and asserts exactly one `Kill` mock invocation.
- [ ] `tekhton tui --help` lists all 13 subcommands (`start`, `stop`, `complete`, `stage-begin`, `stage-end`, `update-stage`, `update-agent`, `append-event`, `substage-begin`, `substage-end`, `pause-enter`, `pause-update`, `pause-exit`); each subcommand has `--help` text and exits 0.
- [ ] The six `lib/tui*.sh` files are deleted from the repo; `find lib -name 'tui*.sh'` returns nothing.
- [ ] No remaining bash file sources `tui.sh`, `tui_ops.sh`, `tui_helpers.sh`, `tui_liveness.sh`, `tui_ops_pause.sh`, or `tui_ops_substage.sh` — verified by `grep -rln 'source.*\(tui\.sh\|tui_helpers\|tui_liveness\|tui_ops\)' lib stages tekhton-legacy.sh` returning zero matches.
- [ ] No remaining bash file calls `tui_*` functions directly — verified by `grep -rnE 'tui_(start|stop|complete|update_stage|finish_stage|update_agent|append_event|substage_begin|substage_end|enter_pause|exit_pause|update_pause|stage_begin|stage_end|reset_for_next_milestone)\b' lib stages tekhton-legacy.sh` returning zero matches (occurrences inside `cmd/tekhton/tui.go` and docs are fine).
- [ ] `internal/finalize/hooks/tui_complete.go` exists and the `tui_complete` entry is wired into `internal/finalize/orchestrator.go`'s hook registry as a pure-Go hook (not a shim dispatch).
- [ ] `lib/finalize_shim.sh` no longer matches `_hook_tui_complete` in its case statement; `grep -n '_hook_tui_complete' lib/finalize_shim.sh` returns zero matches inside the case arms.
- [ ] `tools/tui.py` accepts both `{...payload...}` (legacy) and `{"proto":"tekhton.tui.status.v1","run_id":"...","payload":{...}}` (Go-emitted) inputs — verified by an integration test under `tools/tests/test_tui_proto_compat.py`.
- [ ] `tests/test_tui_parity.sh` exits 0 across all three documented scenarios (green-path, pause/resume cycle, sidecar-death-mid-run).
- [ ] `tests/lib/parity.sh` exists with the shared diff/normalize/compare driver and is consumed by both `test_preflight_parity.sh` (m22) and `test_tui_parity.sh` (m23) — the m22 test file refactors to use the shared driver as part of this milestone, reducing its line count.
- [ ] `make dogfood` exits 0 (self-host parity matrix still green).
- [ ] `bash scripts/wedge-audit.sh` exits 0 (audit extended to forbid re-introduction of `tui_*` as bash function definitions with bodies other than `exec tekhton tui ...`).
- [ ] `go test ./internal/tui/... ./internal/proto/... ./cmd/tekhton/...` passes.
- [ ] `bash tests/run_tests.sh` reports zero new failures vs the m22 close baseline (`test_plan_browser` may remain skip-guarded — that's m26 territory). Specifically: `test_tui_lifecycle_invariants.sh` and `test_tui.sh` continue to pass against the Go writer; if they need updating to drive `tekhton tui ...` instead of sourcing bash, update them — don't skip-guard them.
- [ ] `docs/v4-phase5-stub.md` LOC budget table shows the new post-m23 count and the row "TUI ops" marked "done (m23 — writers ported, six files deleted, finalize_shim arm removed)".
- [ ] `VERSION` reads `4.23.0` on milestone close.
- [ ] `.claude/milestones/MANIFEST.cfg` has the row `m23|TUI Ops Port|done|m22|m23-tui-ops-port.md|phase5`.
- [ ] The implementation run is itself driven by `tekhton run --milestone m23 --complete` — i.e. m23 is the third dogfooded V4 milestone, continuing the m21/m22 precedent.

## Watch For

- **The Python sidecar contract is load-bearing.** Touching `tui_status.json` field names or shapes without a coordinated `tools/tui.py` patch breaks the live TUI for every user the moment the Go binary ships. Lock the v1 field set before writing any `internal/tui/builder.go` code; the proto file is the contract, not the Go struct comments.
- **State persistence across subprocess invocations is the architecture choice with the most footguns.** Every `tekhton tui ...` invocation reads the JSON file, mutates, writes atomically. Two callsites racing (e.g., `tui_update_agent` from the supervisor + `tui_append_event` from a stage subshell) can see each other's stale state. The bash version had this same race — `_tui_write_status` is not lock-protected — and tolerated it because every mutation is a full snapshot rewrite. Preserve the snapshot-rewrite invariant exactly; do not introduce partial-update writes.
- **Auto-close-and-warn semantics from `docs/tui-lifecycle-model.md` are tested by `tests/test_tui_lifecycle_invariants.sh`.** That test will need updating to drive `tekhton tui ...` instead of sourcing bash. The lifecycle invariants themselves do not change; the test scaffolding does.
- **Don't expand to dashboard in this milestone.** `_hook_final_dashboard_status` shares finalize_shim coupling with `_hook_tui_complete` but the dashboard subsystem (`lib/dashboard*.sh` — 1542 LOC, five files) is the m26 surface. Splitting was deliberate after the m22 sizing call ("combined preflight + TUI is ~2600 LOC, too thrashy"). Adding dashboard to m23 produces ~2700 LOC, same trap.
- **`run_op` is the trickiest single API.** It wraps an arbitrary bash command, opening a substage before and closing after. The Go port (`internal/tui/substage.go`) handles begin/end as separate calls; bash callers in stages keep doing `run_op` style wrapping but the wrapper itself becomes a thin bash function that calls `tekhton tui substage-begin`, runs the inner command, then `tekhton tui substage-end`. Don't try to reproduce `run_op` in Go — the bash callers that use it are themselves going to port in later phases, and the wrapper exists for bash composition.
- **The `_hook_final_dashboard_status` arm in `lib/finalize_shim.sh:143-147` currently lists both hooks together** (`_hook_final_dashboard_status|_hook_tui_complete`). m23 splits this into two separate case arms — keep `_hook_final_dashboard_status` (it still sources `lib/dashboard.sh`) and remove `_hook_tui_complete`. Don't conflate them.

## Seeds Forward

- **m24 — Notes port:** The atomic-rename + state round-trip pattern from `internal/tui/state.go` is the same shape `internal/notes/` needs for HUMAN_NOTES.md writes. Extract a shared `internal/atomicfile/` helper as part of m23 if the API shape becomes obvious; otherwise let m24 do the extraction.
- **m25 — Drift + clarify port:** The event-append-with-ring-buffer pattern from `internal/tui/builder.go::appendEvent` is the same shape the drift artifact log needs. Don't generalise prematurely — m25 will decide whether to share or duplicate after seeing both implementations.
- **m26 — Dashboard emitters port:** The remaining finalize-shim case arm (`_hook_final_dashboard_status`) ports here. m26 deletes the arm and ports `lib/dashboard.sh` + four emitter/parser satellites in one milestone. Dashboard parsers already consume `tui_status.v1` indirectly via `RUN_SUMMARY.json` — proto skew check should pick that up.
- **Parity-gate framework reuse — landing in m23:** `tests/lib/parity.sh` extracts the diff/normalize/compare driver from m22's `test_preflight_parity.sh`. m23 is the second consumer; m25 and m26 will be the third and fourth. Doing the extraction now (rather than at the fourth consumer) keeps the framework's scope honest to "two real users, not one speculative."
- **`internal/atomicfile/` candidate:** If notes (m24), drift log (m25), and dashboard emitters (m26) all reach for the temp-file + os.Rename pattern, m26 promotes it to a shared package. m23's `internal/tui/state.go::SaveAtomic` is the prototype.
- **Dogfooding feedback loop:** Continue the m21/m22 pattern — every bug surfaced during the m23 implementation run lands as a patch bump (`4.23.1`, `4.23.2`, …) with a one-line postmortem in `docs/go-migration.md`. Expected patch count: 8-15 (m23 is smaller than m22, but the Python contract is a new failure surface).
