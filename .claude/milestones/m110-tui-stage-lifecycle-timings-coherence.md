# M110 - TUI Stage Lifecycle Semantics and Timings Coherence
<!-- milestone-meta
id: "110"
status: "done"
-->

## Overview

M106 and M107 introduced a stage protocol (`tui_stage_begin`/`tui_stage_end`) and
M108 introduced the stage timings column. Live runs now show a deeper mismatch:

- Completed stages can become active again (intake turned yellow during architect work).
- Intake ordering can drift in the pill row (observed rendering with intake at end
   instead of the front of pre-stages).
- Pre-stage and sub-stage work is not modeled consistently (architect and architect
  remediation activity has no coherent stage ownership).
- Scout-to-coder handoff can briefly regress the coder pill to pending (grey)
  between `tui_stage_end("scout")` and coder begin.
- Completed-row timing output is inconsistent and can regress to zero for some
   stages (observed review/tester resetting to `0s` after counting up).
- Completed-row duration string format can drift across states (live vs completed
   rows show different notations for equivalent elapsed values).
- Completion recap lines are injected into the event stream with new timestamps,
   making historical metadata (for example `Started: coder`) appear after
   `Pipeline Complete` as if it were a new runtime event.
- Action-item payload in hold view can become stale across multi-pass runs
   (for example fix-nonblockers), showing observations that were already
   resolved in the same invocation.
- After hold-on-complete Enter in multi-pass modes, control-flow can look like
   an unintended rerun (new pass starts without clear boundary and sometimes
   without expected TUI re-arm visibility).
- The active bar, stage pills, and timings rows do not share a single lifecycle
  contract, so they can drift apart.

This milestone defines and implements one canonical lifecycle model that all TUI
surfaces follow, while minimizing debt by centralizing behavior in protocol
helpers instead of adding stage-specific patches at call sites.

## Design

### 1) Canonical Stage Taxonomy

Define five activity classes and keep them explicit in protocol state:

1. Pipeline stage: top-level ordered work unit shown in pill row and timings
   (scout/coder/security/review/docs/test_verify/test_write).
2. Pre-stage: run-level gate before the pipeline loop; visible in active bar and
   timings, optional in pills by configuration. `preflight`, `intake`, and
   conditional `architect` audit are separate pre-stages and must never be
   conflated with each other or with pipeline stages.
3. Post-stage: run-level gate after the pipeline loop (currently `wrap-up`),
   which activates during `finalize_run()` and must own the active bar and a
   timings row until the run terminates.
4. Sub-stage: child phase owned by a parent stage (for example scout under coder,
   rework under review, architect-remediation under architect); visibility is
   policy-driven, not ad-hoc.
5. Operation: long shell operation (`run_op`) shown only as active-bar work.
   Operations never produce pill-row state and never add timings rows.

Scope rule:
- Every active status update must belong to exactly one declared class.
- Spinner updates must target the currently declared lifecycle owner, never the
  previously completed stage or the stage that just ended.
- A class change requires a new lifecycle entry; you cannot mutate a pipeline
  stage into a sub-stage or vice versa.

### 2) Stage Ownership Policy (single source of truth)

Add a central policy lookup in `lib/pipeline_order.sh`, co-located with
`get_stage_display_label`, that returns rendering rules per stage name. Encoding
rule (keep the shell footprint small to minimize rewrite cost): one function
`get_stage_policy NAME` implemented as a single `case` statement that echoes a
fixed-shape record `"class|pill|timings|active|parent"` where:

- `class`    ∈ `pipeline | pre | post | sub`
- `pill`     ∈ `yes | no | conditional`
- `timings`  ∈ `yes | no`
- `active`   ∈ `yes | no`
- `parent`   ∈ stage name or `-`

One function, one record shape, no associative arrays, no registry layer.
Call sites never read fields directly; they call protocol helpers which call
the policy lookup. This keeps the portable surface to ~25 lines of shell.

Initial policy (authoritative — any disagreement elsewhere in the doc defers
to this table):

| Stage                    | class    | pill        | timings | active | parent    |
|--------------------------|----------|-------------|---------|--------|-----------|
| preflight                | pre      | yes         | yes     | yes    | -         |
| intake                   | pre      | yes         | yes     | yes    | -         |
| architect                | pre      | conditional | yes     | yes    | -         |
| architect-remediation    | sub      | no          | yes     | yes    | architect |
| scout                    | sub      | no          | yes     | yes    | coder     |
| coder                    | pipeline | yes         | yes     | yes    | -         |
| security                 | pipeline | yes         | yes     | yes    | -         |
| review                   | pipeline | yes         | yes     | yes    | -         |
| docs                     | pipeline | yes         | yes     | yes    | -         |
| test_write / tester-write| pipeline | yes         | yes     | yes    | -         |
| test_verify / tester     | pipeline | yes         | yes     | yes    | -         |
| rework                   | sub      | no          | yes     | yes    | review    |
| wrap-up                  | post     | yes         | yes     | yes    | -         |
| run_op operations        | op       | no          | no      | yes    | -         |

`conditional` pills are rendered by the planner (§3), not by live protocol
traffic. Call sites pass only the stage name; the helper resolves the class
and visibility rules. Test coverage for this lookup is mandatory (§10).

### 3) Deterministic Run Stage Plan (precomputed pills)

Before the run starts, compute a deterministic stage plan for this invocation and
use it to seed the pill row. This prevents both ghost pills (stages that never
run) and missing pills (conditional stages that do run).

Inputs to the planner:

- run mode and entrypoint (`--milestone`, bare task, `--fix-nonblockers`,
   `--fix-drift`, `--start-at`)
- stage toggles (`SKIP_SECURITY`, `SKIP_DOCS`, agent-enabled flags)
- pipeline order mode (standard vs test_first)
- deterministic pre-stage conditions (for example intake enabled)
- gated/conditional stages represented as `possible` at plan-time and upgraded to
   `scheduled` only when predicates resolve true (for example architect audit)

Planner output:

- `planned_pills`: ordered list shown in grey at run start
- `possible_pills`: conditional placeholders (optional style) for gates that may run
- `lifecycle_policy`: resolved visibility rules consumed by protocol helpers

Ordering guarantees:

- Pre-stage order is deterministic and stable: `preflight` -> `intake` -> optional
   `architect` (when scheduled/possible).
- A stage cannot move later in the row due to late protocol registration.
- Dynamic insertion is allowed only for policy-approved conditional placeholders,
   preserving deterministic relative order.

Architect handling (binds §2 and §3):

- Architect's policy is `pill=conditional`. The planner decides at startup
  whether to promote the placeholder to `scheduled` based on:
  `FORCE_AUDIT=true`, pending drift observations above
  `DRIFT_OBSERVATION_THRESHOLD`, or `runs_since_audit >= DRIFT_RUNS_SINCE_AUDIT_THRESHOLD`.
- When promoted to `scheduled`, architect appears in the pill row in the
  pre-stage slot (after intake, before pipeline stages) and owns the active bar
  and a timings row during execution.
- When not promoted, architect is suppressed from the pill row entirely for
  this run — no placeholder is shown. Timings/active ownership are still
  reserved so any late activation is well-formed rather than stale-label.
- Rationale: rendering a persistent grey "maybe architect" pill on every run
  was rejected; it adds visual noise for the common case where audit does not
  run. Defer any distinctive rendering for possible-but-not-scheduled
  placeholders until a concrete need arises.

This planner lives in one shell-layer function (`get_run_stage_plan()` in
`lib/pipeline_order.sh`) and feeds both `_OUT_CTX[stage_order]` and the TUI
bootstrap. No per-stage caller is permitted to manually patch stage order.

### 4) Atomic Transition API (remove grey-gap regressions)

Introduce a transition helper in `lib/tui_ops.sh` for immediate handoffs:

- `tui_stage_transition FROM TO [MODEL]`

Behavior:
- Ends `FROM` and begins `TO` in one status-file transaction (single write).
- Prevents brief idle/pending gaps that currently appear between scout and coder.
- Preserves elapsed freeze for `FROM` and immediate running status for `TO`.

Any same-owner handoff path (scout -> coder, coder -> completion gate phase,
rework cycle transitions) should use transition instead of separate end/begin calls.

### 5) Lifecycle Invariants Enforced in Protocol Layer

Lifecycle identity contract:

- Every `tui_stage_begin` allocates a lifecycle id of the form
  `"<stage>#<cycle>"` where `<cycle>` is a per-stage monotonic counter
  maintained in a shell associative array `_TUI_STAGE_CYCLE` (e.g. first
  rework is `rework#1`, second is `rework#2`).
- The current owner is tracked as two fields in the status file:
  `current_lifecycle_id` and `current_stage_label`.
- Every `tui_update_agent` / spinner call resolves to `current_lifecycle_id`
  and is silently dropped if the id has changed since the call was queued
  (guards against late updates leaking into the next stage).
- Completed stage records in `stages_complete[]` carry their lifecycle id
  verbatim. Timings rows key off lifecycle id, not label.
- Lifecycle ids are strings, not structs; the shell surface stays portable.

Invariants enforced in the protocol layer (single code path — `lib/tui_ops.sh`):

1. No stale reactivation: once a lifecycle id is marked complete, no further
   updates to that id are accepted. Reusing a label requires allocating a new
   id (`rework#2`, not `rework#1` again).
2. Parent consistency: a sub-stage begin must resolve to an open parent
   lifecycle id per the policy table (§2). If the parent is not open, fail
   closed to a neutral active label (never the last completed stage).
3. Monotonic pill state: `pending → running → complete|fail`. Any transition
   from `complete` back to `running` for the same label is only legal when a
   new lifecycle id has been allocated for that label.
4. Timings ownership: each timings row has a stable lifecycle id; elapsed and
   turns attach to that id, not to mutable current-label globals.

### 6) Timings Column Compatibility

Stage timings must remain compatible with M108 behavior while reflecting the new
ownership model:

- Rows remain append-only for completed lifecycle ids.
- Child rows include a deterministic display label (for example `coder/scout` or
  `architect/sr-remediation`) derived from policy.
- Live row always reflects the current lifecycle owner selected by protocol,
  including architect and sub-stage phases.
- No duplicate rows for the same lifecycle id; repeated labels are allowed only
  when they represent separate cycles.

Timing integrity rules:

- Completed rows must never reset elapsed to `0s` unless true elapsed is zero.
- Stage-duration lookup must use a canonical key resolver, not raw loop labels
  where aliases differ. The resolver lives next to `get_stage_display_label`
  and must normalize all known aliases to their display key before any metric
  lookup. Known alias pairs that must be covered (verified against call sites
  in `stages/*.sh` and `lib/metrics*.sh`):

  | Internal / metric key | Display label (canonical) |
  |-----------------------|---------------------------|
  | `reviewer`            | `review`                  |
  | `test_verify`         | `tester`                  |
  | `test_write`          | `tester-write`            |
  | `wrap_up`             | `wrap-up`                 |
  | `jr_coder`            | `rework` (sub-stage)      |

  The resolver must be a single function `get_stage_metrics_key NAME` that
  accepts either side and returns the canonical display label. Any new stage
  or alias added in future work must extend this one function.

- Completed and live rows must use the same formatter contract (`_fmt_duration`
  in `tools/tui_render_common.py`) for human-readable consistency. No ad-hoc
  duration formatting is permitted elsewhere in the render tree.
- Raw seconds may be stored in status payload, but rendering must normalize via
  the one formatter path. The status-file schema should store both raw seconds
  (`elapsed_secs`) and the canonical lifecycle id so the renderer can recompute
  if needed without trusting mutable label globals.
- On `tui_stage_end`, duration and turns must be resolved via the canonical
  key resolver *before* the status record is written. Missing metric lookups
  must not silently default to `0s` — they must log a warning and inherit the
  last observed elapsed for the open lifecycle id.

### 7) Integration Plan (minimal churn)

Implement in this order to reduce risk. The whole M110 implementation must be
gated by a `TUI_LIFECYCLE_V2` config flag (default `true` once merged, with a
documented fallback to the pre-M110 path for one release cycle). This
preserves a cheap rollback if a field regression surfaces post-merge.

1. Add canonical stage-metrics key resolver (`get_stage_metrics_key`) in
   `lib/pipeline_order.sh` alongside `get_stage_display_label`. This is
   foundational — every subsequent step relies on it.
2. Add stage policy lookup (`get_stage_policy`) in `lib/pipeline_order.sh`.
   Pure function, no side effects, tested in isolation.
3. Add lifecycle-id allocation and `current_lifecycle_id` tracking in
   `lib/tui_ops.sh` and `lib/tui_helpers.sh`. Extend status-file JSON schema
   to include `lifecycle_id` on `current` and `stages_complete[]` entries.
4. Add deterministic stage planner (`get_run_stage_plan`) in
   `lib/pipeline_order.sh` and feed it into `_OUT_CTX[stage_order]` and the
   TUI bootstrap (replacing the direct `get_display_stage_order` call at run
   start).
5. Update `tools/tui_render.py` and `tools/tui_render_timings.py` to render
   policy-driven labels and lifecycle-id-keyed current row selection. Keep
   `_fmt_duration` as the single formatter entry point.
6. Add `tui_stage_transition FROM TO [MODEL]` to `lib/tui_ops.sh`. Single
   status-file write (end `FROM`, begin `TO`, one atomic swap).
7. Wire architect and architect-remediation call sites in `stages/architect.sh`
   to explicit protocol stages.
8. Replace the scout→coder end/begin pair in `stages/coder.sh` with
   `tui_stage_transition`.
9. Add event-stream phase typing (`runtime` vs `summary`) in
   `lib/tui_helpers.sh` (event record) and route recap fields through
   `lib/output_format.sh` as `summary` events. Update `tools/tui_hold.py` to
   render a separate summary block.
10. Add per-pass output-bus/TUI state reset helper (`out_reset_pass`) in
    `lib/output.sh` and invoke it from the `_run_fix_nonblockers_loop` and
    `_run_fix_drift_loop` functions in `tekhton.sh` before each iteration.
11. Emit explicit `pass_boundary` events before each pass ≥ 2 and a terminal
    `loop_terminal` event when remaining work is zero.
12. Keep pre-M110 code paths alive behind the `TUI_LIFECYCLE_V2` flag during
    migration; remove the legacy paths only after a full release cycle with
    the flag defaulting to on.

### 8) Event Stream Chronology and Completion Summary Boundaries

The TUI currently uses a single recent-events ring where both runtime events and
finalize recap output are appended. Because recap fields are emitted late, they
receive late timestamps and can appear semantically out of order (for example a
"Started" field after "Pipeline Complete").

Required model:

- Runtime events: chronological activity records (stage start/end, warnings,
   gate transitions).
- Summary metadata: immutable run facts (task, started-at stage, verdict, log,
   version, timing breakdown).

Rules:

- Summary metadata must be rendered in a dedicated summary block in hold view,
   not inserted into runtime `recent_events`.
- `Pipeline Complete` is terminal for runtime event chronology in that run.
- Any post-complete output must be typed as summary/epilogue and visually
   separated from runtime events.
- Existing output helpers may still be reused, but routing must preserve event
   type so hold rendering cannot interleave recap facts with runtime chronology.

### 9) Multi-Pass State Isolation (fix-nb / fix-drift)

Multi-pass modes re-enter pipeline/finalize loops within a single process. TUI
state and output-bus payloads must be reset at pass boundaries to avoid stale UI
artifacts.

Required reset boundaries:

- Clear `_OUT_CTX[action_items]` at start of each pass before new action-item
   collection.
- Reset per-pass summary metadata (task/log/version/time-breakdown payload) before
   finalize emits recap fields.
- Reset/rehydrate TUI run context before each pass (`attempt`, `task`, stage plan,
   and active lifecycle owner).

Control-flow clarity rules:

- After hold-on-complete Enter, the decision whether to start another pass
  must live in the parent shell loop (`_run_fix_nonblockers_loop` /
  `_run_fix_drift_loop` in `tekhton.sh`), not in `tools/tui_hold.py`. The
  sidecar's only responsibility is to unblock on Enter; the shell then
  evaluates remaining-work count and either terminates or continues.
- If another pass is required, the shell must emit an explicit
  `Starting pass N+1` boundary event (typed as `runtime`) before any stage
  events and re-arm the TUI sidecar for the new pass.
- If no work remains (for example non-blocking count is 0), no new pipeline
  pass may start; the loop must emit a terminal event and exit cleanly.
- TUI re-arm on subsequent passes must be deterministic and observable:
  either the sidecar starts (visible in logs), or an explicit reason event is
  emitted when disabled (`TUI_ENABLED=false` or missing venv).

### 10) Testing & Rollout

Given the blast radius (15 files, 17 acceptance items), the test matrix must
cover each new contract explicitly, not merely the end-to-end behavior:

Unit tests (`tools/tests/test_tui.py`, shell-side via bats or fixture scripts):

- `get_stage_policy` returns correct record shape for every stage in the §2
  table; unknown stages fall back to a defined `op` record.
- `get_stage_metrics_key` normalizes every alias pair listed in §6 and is
  idempotent when called on a canonical key.
- `get_run_stage_plan` output for each run mode:
  - bare task (`INTAKE_AGENT_ENABLED=true`, no flags)
  - bare task with `SKIP_SECURITY=true`
  - bare task with `DOCS_AGENT_ENABLED=true`
  - `--milestone` mode
  - `--fix nb` mode
  - `--fix drift` mode (architect promoted to `scheduled`)
  - `--start-at review`
- Lifecycle-id monotonicity: repeated `tui_stage_begin "rework"` calls
  allocate `rework#1`, `rework#2`, ... never reuse a completed id.
- Spinner updates against a closed lifecycle id are dropped.
- `tui_stage_transition` produces exactly one status-file write.
- Event type routing: `out_kv "Task" ...` produces a `summary` event, not
  `runtime`.
- `out_reset_pass` clears `_OUT_CTX[action_items]` and per-pass summary keys
  but preserves run-invariant keys (`mode`, `task`, `cli_flags`).

Integration tests (`tests/test_tui_stage_wiring.sh`):

- Scout → coder transition: zero grey-gap frames in captured status-file
  sequence (no status frame has `current_stage_label=""` between the two).
- Rework cycle: two successive rework entries both appear in timings with
  distinct lifecycle ids, no pill regression.
- Architect promotion: with drift observations seeded above threshold,
  architect pill appears and owns active bar during execution; with no
  drift, no architect pill is rendered.
- Multi-pass reset: `_run_fix_nonblockers_loop` with 2 passes shows cleared
  action items between passes; pass-boundary event is emitted between them.
- Hold → no-work Enter: synthetic hold view Enter with remaining-work=0
  exits cleanly without starting a new pass.

Rollout:

- Merge with `TUI_LIFECYCLE_V2=true` as default. Document the flag in
  `CLAUDE.md` template-variables table and `pipeline.conf.example`.
- Keep the legacy code path reachable for one release cycle (one completed
  post-V3 initiative milestone). Remove only after a clean field report.
- Post-merge: run the full self-test suite (`bash tests/run_tests.sh`) plus
  a manual smoke test against a small target project covering bare task,
  `--fix nb`, and `--fix drift`.

## Files Modified

| File | Change |
|------|--------|
| `lib/pipeline_order.sh` | Add `get_stage_policy`, `get_stage_metrics_key`, `get_run_stage_plan` (policy + canonical key resolver + planner) |
| `lib/tui_ops.sh` | Add lifecycle-id allocation, `tui_stage_transition`, `TUI_LIFECYCLE_V2` gating |
| `lib/tui_helpers.sh` | Emit `lifecycle_id` and `current_lifecycle_id` in status JSON; add `type` field to events (`runtime` / `summary`) |
| `lib/output.sh` | Add `out_reset_pass` helper (clears `_OUT_CTX[action_items]` and per-pass summary keys) |
| `lib/output_format.sh` | Route recap fields through `summary` event type; no chronological ts on summary metadata |
| `stages/coder.sh` | Replace scout end/begin pair with `tui_stage_transition "scout" "coder"` |
| `stages/review.sh` | Route rework wiring through policy (sub-stage with `parent=review`) |
| `stages/architect.sh` | Explicit architect and architect-remediation lifecycle wiring (currently has no TUI protocol calls) |
| `stages/tester.sh`, `stages/tester_tdd.sh`, `stages/tester_fix.sh` | Route through `get_stage_metrics_key` so `test_verify`/`test_write`/`tester` alias resolution is consistent with renderer |
| `tekhton.sh` | Pre-stage wiring (preflight/intake/architect), consume `get_run_stage_plan` at bootstrap, call `out_reset_pass` in `_run_fix_nonblockers_loop` + `_run_fix_drift_loop`, emit pass-boundary + loop-terminal events |
| `tools/tui_render.py`, `tools/tui_render_timings.py` | Lifecycle-id-keyed row selection; policy-driven label rendering; single `_fmt_duration` path |
| `tools/tui_hold.py` | Separate runtime event log from summary metadata block; Enter only unblocks — no pass-decision logic |
| `tools/tests/test_tui.py` | Unit tests for lifecycle invariants, policy lookup, alias resolver, planner output |
| `tests/test_tui_stage_wiring.sh` | Integration tests for transitions, multi-pass reset, repeated-cycle rework, no stale-label regression |

## Acceptance Criteria

- [ ] Intake no longer reactivates during architect or architect remediation work.
- [ ] Pre-flight and Intake are represented as distinct stages in lifecycle state,
      with deterministic pre-stage ordering.
- [ ] Intake does not appear at the end of the pill row in any run mode.
- [ ] Pill row is computed deterministically before stage execution begins and
   includes only scheduled/possible stages for this run mode.
- [ ] No pills appear for stages that cannot run in the active invocation mode.
- [ ] Conditional stages (for example architect audit) are represented without
   causing stale-label reactivation when they activate.
- [ ] Architect work is visible as an active lifecycle owner and appears in timings.
- [ ] Scout-to-coder handoff has no visible grey/pending regression gap.
- [ ] Active bar, pill row, and timings row always reference the same current
      lifecycle owner.
- [ ] Review and tester completed rows preserve real elapsed duration and do not
   reset to `0s` after completion.
- [ ] Completed-row duration notation is consistent with live-row notation for
   equivalent elapsed values.
- [ ] Completion recap fields (Task, Started, Verdict, Log, Version, breakdown)
   do not appear as late chronological runtime events in the hold event log.
- [ ] Runtime event chronology remains monotonic, and `Pipeline Complete` is
   treated as terminal for runtime-event ordering.
- [ ] Action Items in hold view reflect only the current pass/run state and do
   not persist resolved items from prior passes in the same process.
- [ ] In fix-nonblockers/fix-drift modes, pressing Enter on hold view cannot
   trigger an extra pass when remaining work count is zero.
- [ ] If another pass is required, the UI emits an explicit new-pass boundary and
   re-arms TUI context before stage events begin.
- [ ] Protocol enforces no stale-label reactivation even under spinner updates.
- [ ] Existing M108 timings column still renders completed stage rows correctly.
- [ ] New and updated tests cover architect pre-stage flow, scout->coder transition,
      and repeated-cycle behavior (rework) without false regressions.
