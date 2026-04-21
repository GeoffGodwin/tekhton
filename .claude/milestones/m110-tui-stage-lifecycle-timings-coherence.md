# M110 - TUI Stage Lifecycle Semantics and Timings Coherence
<!-- milestone-meta
id: "110"
status: "pending"
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

Define four activity classes and keep them explicit in protocol state:

1. Pipeline stage: top-level ordered work unit shown in pill row and timings.
2. Pre-stage: run-level gate before pipeline loop; visible in active bar and
   timings, optional in pills by configuration. `preflight` and `intake` are
   separate pre-stages and must never be conflated.
3. Sub-stage: child phase owned by a parent stage (for example scout under coder,
   rework under review); visibility is policy-driven, not ad-hoc.
4. Operation: long shell operation (`run_op`) shown only as active-bar work.

Scope rule:
- Every active status update must belong to one declared class.
- Spinner updates must target the currently declared lifecycle owner, never the
  previously completed stage.

### 2) Stage Ownership Policy (single source of truth)

Add a central policy map in shell (same layer as stage label mapping) that decides,
per class/stage, where it appears:

- In pill row (`pill=true/false`)
- In timings (`timings=true/false`)
- In active-bar label (`active=true/false`)
- Parent stage for sub-stages (`parent=coder`, `parent=review`, etc.)

Initial policy:
- preflight: pill yes (or configurable), timings yes, active yes
- intake: pill yes, timings yes, active yes
- architect: pill no, timings yes, active yes
- architect remediation coder/jr/review: pill no, timings yes, active yes,
  parent architect
- scout: pill no (or inherited), timings yes, active yes, parent coder
- rework: keep current behavior, but policy-defined
- run_op operations: active only

The policy is read by protocol helpers so call sites provide semantic intent, not
rendering decisions.

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

Architect handling:

- Architect should not be silently absent when drift audit is likely.
- If audit predicate is unresolved at startup, include architect as a conditional
   placeholder pill (or at minimum reserve timings/active ownership) so activation
   never looks like a stale-label bug.

This planner should live in one shell-layer function and feed both output bus
context and TUI state; no per-stage caller should manually patch stage order.

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

Enforce these invariants in one place (tui protocol code):

1. No stale reactivation: once a stage is marked complete, it cannot become active
   again unless a new lifecycle entry is explicitly opened for that same label.
2. Parent consistency: a sub-stage update must resolve to an active parent context
   or fail closed to a neutral active label (never last completed stage).
3. Monotonic pill state: pending -> running -> complete/fail, no complete -> running
   regressions without explicit new cycle semantics.
4. Timings ownership: each row has a stable lifecycle id; elapsed and turns attach
   to that id, not to mutable current-label globals.

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
- Stage-duration lookup must use a canonical key mapping, not raw loop labels
   where aliases differ (for example `review` vs `reviewer`, `test_verify` vs
   `tester`).
- Completed and live rows must use the same formatter contract (`_fmt_duration`)
   for human-readable consistency.
- Raw seconds may be stored in status payload, but rendering should normalize via
   one formatter path.

### 7) Integration Plan (minimal churn)

Implement in this order to reduce risk:

1. Add policy and lifecycle-id support in `lib/tui_ops.sh` and `lib/tui_helpers.sh`.
2. Add deterministic stage planner and feed it into output bus + TUI bootstrap.
3. Update `tools/tui_render.py` to render policy-driven labels and lifecycle-safe
   current row selection.
4. Introduce canonical stage-metrics key resolver for turns/duration lookups
   before `tui_stage_end` (prevent alias-key default-to-zero regressions).
5. Wire architect and architect-remediation call sites to explicit protocol stages.
6. Replace fragile end/begin pairs with transition helper on scout->coder path.
7. Add event-stream phase typing so completion recap fields are rendered as
    summary metadata, not chronological runtime events.
8. Add per-pass output-bus/TUI state reset hooks for multi-pass modes
   (`fix-nb`, `fix-drift`, `complete` loop variants as needed).
9. Keep existing APIs as wrappers during migration; remove old direct patterns only
   after tests pass.

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

- After hold-on-complete Enter, if another pass is required, emit an explicit
   `Starting pass N+1` boundary event before stage events.
- If no work remains (for example non-blocking count is 0), no new pipeline pass
   may start; loop must terminate with a clear terminal message.
- TUI re-arm on subsequent passes must be deterministic and observable (either
   sidecar starts or explicit reason is emitted when disabled).

## Files Modified

| File | Change |
|------|--------|
| `lib/pipeline_order.sh` | Add stage ownership policy lookup helpers |
| `lib/pipeline_order.sh` | Add deterministic run-stage planner helpers |
| `lib/tui_ops.sh` | Add lifecycle-aware begin/end and transition helper |
| `lib/tui_helpers.sh` | Emit lifecycle identifiers and policy-aware status fields |
| `tekhton.sh` | Canonical stage-metrics key mapping for duration/turns lookup |
| `tekhton.sh` | Architect/pre-stage wiring and transition usage |
| `stages/coder.sh` | Scout->coder transition handoff |
| `stages/review.sh` | Policy-driven rework lifecycle wiring |
| `stages/architect.sh` | Explicit architect and remediation lifecycle ownership |
| `tools/tui_render.py` | Policy-aware live row and timings rendering |
| `tools/tui_hold.py` | Separate runtime event log from completion summary metadata |
| `lib/output_format.sh` | Route recap fields with explicit summary event type |
| `lib/output.sh` | Add per-pass action-item reset helper for Output Bus context |
| `tekhton.sh` | Enforce multi-pass boundary events and no-work terminal break |
| `tools/tests/test_tui.py` | Unit tests for lifecycle invariants and rendering |
| `tests/test_tui_stage_wiring.sh` | Integration tests for transitions and no-regression behavior |

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
