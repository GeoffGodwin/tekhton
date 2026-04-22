# TUI Lifecycle Model

> Single source of truth for how Tekhton stages and sub-stages flow through
> the TUI sidecar. Read this before adding a new stage, a new substage, a new
> `run_op` call site, or before debugging "why did the pill flash twice"
> kinds of issues.
>
> Established by milestones M97 (sidecar), M104–M115 (lifecycle hardening),
> M116 (rework / architect-remediation migration), M117 (Recent Events
> attribution), and M118 (deferred preflight/intake emit). The invariants
> codified here are enforced by `tests/test_tui_lifecycle_invariants.sh`
> (M119) — modify them only after updating that suite.

---

## 1. Three surfaces

The TUI exposes three independent visual surfaces. A change to one does not
cascade to the others; understanding which surface you are touching keeps
intent and ownership crisp.

### 1.1 Pill row (header)
- **What it shows.** A horizontal strip of stage pills representing the
  *plan* for this run, painted by the renderer in
  `tools/tui_render.py:_STAGE_PILL_SPEC`. Each pill is a fixed slot ordered
  by `_TUI_STAGE_ORDER`.
- **Who writes it.** Seeded at bootstrap by `get_run_stage_plan()` in
  `lib/pipeline_order_policy.sh`, then advanced as each pipeline stage
  begins. Substages and `run_op` labels never appear here.
- **Who owns updates.** `tui_stage_begin` / `tui_stage_end` are the only
  legitimate mutators. Any direct write to `_TUI_STAGE_ORDER` outside
  bootstrap is a bug — the array is single-writer (main process only).

### 1.2 Stage timings panel
- **What it shows.** A live row for the currently active pipeline stage
  (label, model, elapsed time, turns), a header summary, and one completed
  row per stage that has finished. Rendered by
  `tools/tui_render_timings.py`.
- **Who writes it.** `_TUI_STAGE_START_TS`, `_TUI_AGENT_*` and
  `_TUI_STAGES_COMPLETE` are the inputs.
- **Who owns updates.** The live row is owned by `tui_stage_begin` /
  `tui_update_agent` / `tui_stage_end`. Completed rows come from
  `tui_finish_stage`, called only from `tui_stage_end`. Substages and
  `run_op` calls are intentionally invisible here — the timeline reflects
  pipeline stages, not transient phases.

### 1.3 Recent Events
- **What it shows.** A ring-buffered list of `info | warn | error | success`
  messages, each tagged with a timestamp and (since M117) a substage-aware
  attribution prefix.
- **Who writes it.** Every emission flows through `_tui_notify` in
  `lib/common.sh`, which calls `tui_append_event` with a computed
  `source` ("stage » substage" or "stage" or empty).
- **Who owns updates.** Implicit — every `log` / `warn` / `error` /
  `success` call site contributes. The ring buffer depth is bounded by
  `TUI_EVENT_LINES`; oldest entries evict on overflow.

---

## 2. Stage classes

Every label that flows through the lifecycle has a *class* declared by
`get_stage_policy` in `lib/pipeline_order_policy.sh`. The class controls
which surfaces the label touches.

| Class      | Pill row     | Timings live row | Timings completed row | When to use |
|------------|--------------|------------------|-----------------------|-------------|
| `pipeline` | yes          | yes              | yes                   | Coder, security, review, tester, docs — the spine of a run. |
| `pre`      | yes          | yes              | yes                   | Preflight, intake — runs once before the spine, owns its own pill. |
| `post`     | yes          | yes              | yes                   | Wrap-up — runs after the spine. |
| `sub`      | no           | live only        | no                    | Scout, rework, architect-remediation — transient phase inside a parent stage. |
| `op`       | no           | no               | no                    | `run_op` labels (e.g. "Running test baseline") — long-running command wrappers. |

Architect uses `class=pre` with `pill=conditional` — included only when
promoted via `FORCE_AUDIT` or drift thresholds.

---

## 3. Lifecycle helpers

### 3.1 `tui_stage_begin DISPLAY_LABEL [MODEL]` (lib/tui_ops.sh)
Allocates a new lifecycle id `<label>#<cycle>` (cycle is per-label,
monotonic), appends to `_TUI_STAGE_ORDER` if the policy says `pill=yes`,
seeds `_TUI_CURRENT_STAGE_*` and `_TUI_STAGE_START_TS=now`, marks the
agent state `running`, and writes the status file.

**Contract.** `DISPLAY_LABEL` must come from `get_stage_display_label()` —
never pass a raw internal stage name. Calling twice for the same label
without an intervening `tui_stage_end` produces a new lifecycle id; the
prior cycle's late spinner ticks are dropped (they no longer match the
current owner id).

### 3.2 `tui_stage_end DISPLAY_LABEL [MODEL] [TURNS] [TIME] [VERDICT]`
Auto-closes any still-open substage (see §3.5), appends one entry to
`_TUI_STAGES_COMPLETE`, marks the lifecycle id closed (so late updates
keyed off `tui_current_lifecycle_id` capture cannot land), and clears
`_TUI_CURRENT_LIFECYCLE_ID`. All intermediate writes are coalesced via
`_TUI_SUPPRESS_WRITE` so callers see exactly one status-file mutation.

**Contract.** The `DISPLAY_LABEL` passed here must match the one passed
to `tui_stage_begin` for the lifecycle id to flow through correctly.

### 3.3 `tui_substage_begin LABEL [MODEL]` (lib/tui_ops_substage.sh)
Records `_TUI_CURRENT_SUBSTAGE_LABEL` and `_TUI_CURRENT_SUBSTAGE_START_TS`
and flushes the status file. **Does not** touch the parent stage's label,
start ts, lifecycle id, or `_TUI_STAGES_COMPLETE`. The `MODEL` argument
exists for call-site symmetry with `tui_stage_begin` but is not retained.

### 3.4 `tui_substage_end LABEL [VERDICT]`
Clears the substage globals and flushes the status file. `LABEL` and
`VERDICT` are accepted for symmetry but are not retained — the substage
is a breadcrumb, not a timeline entry, so no `_TUI_STAGES_COMPLETE` row
is written.

### 3.5 Auto-close-and-warn rule
If `tui_stage_end` runs while `_TUI_CURRENT_SUBSTAGE_LABEL` is still set,
`_tui_autoclose_substage_if_open` clears the substage globals and emits a
single `warn` event:

    [tui] substage '<sublabel>' auto-closed by parent end

This catches forgotten `tui_substage_end` pairs (crashes, early returns,
missed exit branches) without leaking inconsistent state into the next
stage.

### 3.6 `run_op LABEL CMD [ARGS...]` (lib/tui_ops.sh)
Wraps a long-running shell command. Internally calls `tui_substage_begin`
with `LABEL`, runs the command, then `tui_substage_end`. Spawns a
heartbeat subprocess (10s tick) so the watchdog never fires during the
operation. When `_TUI_ACTIVE != true`, becomes a transparent passthrough.

### 3.7 `TUI_LIFECYCLE_V2` opt-out
When `TUI_LIFECYCLE_V2=false`, all substage functions and the auto-close
helper become no-ops — no globals set, no status-file writes, no events.
The opt-out is currently retained for safety; retirement is a separate
follow-up milestone (see M119 Non-Goals).

---

## 4. Status file schema

`tui_status.json` is the JSON object emitted by `_tui_json_build_status`
in `lib/tui_helpers.sh` and consumed by `tools/tui.py`. There is no
`schema_version` field — tolerance is per-field (consumers default
unknown/missing keys to safe values).

| Field                       | Type      | Meaning |
|-----------------------------|-----------|---------|
| `version`                   | int       | Static `1`; never bumped (tolerance is per-field). |
| `run_id`                    | string    | Run identity (`_CURRENT_RUN_ID` or `TIMESTAMP`). |
| `milestone`                 | string    | Current milestone id (e.g. `"119"`). |
| `milestone_title`           | string    | Human-readable milestone title. |
| `task`                      | string    | The `$TASK` argument. |
| `attempt` / `max_attempts`  | int / int | Pipeline retry counters from the Output Bus. |
| `stage_num` / `stage_total` | int / int | 1-based position of the active stage in the pill row. |
| `stage_label`               | string    | The active *pipeline stage* label (never substage). |
| `current_lifecycle_id`      | string    | `<label>#<cycle>` — empty when no stage is open. |
| `current_substage_label`    | string    | Active substage label, or `""`. |
| `current_substage_start_ts` | int       | Unix ts when the substage opened, or `0`. |
| `agent_turns_used` / `agent_turns_max` | int | Turn counters from the active agent. |
| `agent_elapsed_secs`        | int       | Wall-clock elapsed for the active stage / final value at stage end. |
| `stage_start_ts`            | int       | Unix ts when the active stage opened (parent), `0` when idle. |
| `agent_model`               | string    | Model id for the active stage. |
| `pipeline_elapsed_secs`     | int       | Wall-clock elapsed since pipeline start. |
| `stages_complete`           | array     | One JSON object per finished stage (label, lifecycle_id, model, turns, time, verdict). |
| `current_agent_status`      | string    | `idle | running | working | complete`. |
| `run_mode`                  | string    | `task | milestone | complete | …`. |
| `cli_flags`                 | string    | Pretty-printed non-default CLI flags. |
| `stage_order`               | array     | Pill row order (stable for the run). |
| `last_event` / `recent_events` | string / array | Ring buffer; entries have `ts`, `level`, `type`, optional `source`, `msg`. |
| `action_items`              | array     | Action items routed via the Output Bus. |
| `verdict`                   | string?   | Final verdict at completion (null otherwise). |
| `complete`                  | bool      | True when `tui_complete` has been called. |

`recent_events` entries omit the `source` key when no stage/substage is
active (per M117) — consumers must treat `source` as optional.

---

## 5. Event attribution

The breadcrumb prefix on Recent Events flows through this chain:

1. A call site invokes `log` / `warn` / `error` / `success` (defined in
   `lib/common.sh`).
2. Each routes through `_tui_notify`, which calls
   `_tui_compute_source` to resolve the active stage/substage.
3. `_tui_compute_source` consults `_TUI_CURRENT_STAGE_LABEL` and
   `_TUI_CURRENT_SUBSTAGE_LABEL` and returns:
   - `"stage » substage"` when both are set
   - `"stage"` when only the stage is set
   - empty string when neither is set, *or* when `TUI_LIFECYCLE_V2=false`
4. `_tui_notify` invokes `tui_append_event "$level" "$msg" "runtime" "$src"`.
5. The renderer in `tools/tui_render.py` reads `source` per-event and
   prefixes the rendered line.

Plain log files (`LOG_FILE`) never carry the breadcrumb — attribution is
TUI-only, by design.

---

## 6. Adding a new stage

Use this checklist as a dry-run against an existing stage (e.g. `review`)
to verify it produces all the same files and call sites the codebase
already has.

1. **Pick an internal name** (snake_case) and a **display label**
   (kebab-case, lower) — e.g. `internal=my_phase`, `display=my-phase`.
2. **`get_stage_display_label`** in `lib/pipeline_order.sh`: add a new
   `case` arm mapping `my_phase) echo "my-phase" ;;`.
3. **`get_stage_metrics_key`** in `lib/pipeline_order_policy.sh`: add a
   case arm only if internal name and display label differ in a way the
   default fallback can't handle.
4. **`get_stage_policy`** in `lib/pipeline_order_policy.sh`: add a
   policy record `my-phase) echo "pipeline|yes|yes|yes|-" ;;` (or
   `pre|conditional|...` etc.).
5. **`PIPELINE_ORDER_*`** in `lib/pipeline_order.sh`: add `my_phase` to
   the relevant order constant(s) at the position where it should run.
6. **Stage implementation** at `stages/my_phase.sh`: new function
   `run_stage_my_phase()`, sourced from `tekhton.sh`.
7. **Lifecycle calls** in `tekhton.sh`'s pipeline loop:
   - `tui_stage_begin "my-phase" "${CLAUDE_STANDARD_MODEL:-}"`
   - `run_stage_my_phase`
   - `tui_stage_end "my-phase" "${CLAUDE_STANDARD_MODEL:-}" "${turns}" "${duration}s" "${verdict}"`
8. **Optional**: a per-stage test under `tests/`.

After the change, `tests/test_tui_lifecycle_invariants.sh` invariant 1
will re-validate that any new `stages_complete` rows the new stage emits
have a class in `{pipeline, pre, post}`.

---

## 7. Adding a new sub-stage

Substages are lighter weight — no policy record, no pill, no completion
row.

1. **Optional policy record** in `get_stage_policy`: add a
   `class=sub` entry with `parent=<parent stage>` if you want renderers
   to identify it explicitly. Most substages work without one because
   the renderer falls back to the `op` policy for unknown labels and
   only uses substage state for the breadcrumb.
2. **Wrap the substage body** at the call site:
   ```bash
   tui_substage_begin "my-substage" "${CLAUDE_STANDARD_MODEL:-}"
   run_my_substage_body
   tui_substage_end "my-substage" "${VERDICT}"
   ```
3. **No changes** are needed to:
   - `_TUI_STAGE_ORDER` / pill row
   - `_TUI_STAGES_COMPLETE` logic
   - `get_run_stage_plan`
   - the renderer (it already reads `current_substage_label`)
4. **Trust the auto-close.** If your substage body has multiple early
   returns and you forget a `tui_substage_end` on one path, the parent's
   `tui_stage_end` will auto-close and emit a single warn event — but
   write the explicit pair anyway; the warn is a regression signal, not
   a feature.

---

## 8. Adding a new `run_op`

Drop-in. No policy record needed (the catch-all `op` policy applies).

```bash
run_op "Running my long command" my_command --arg1 --arg2
```

`run_op` registers the label as a substage internally, runs the command,
and clears the substage on return — preserving the wrapped command's
exit code. The label appears in the timings live row's breadcrumb
("parent » Running my long command") while the command executes, and
disappears as soon as it returns.

---

## 9. Debugging checklist

| Symptom | Likely cause |
|---------|--------------|
| Pill flashes the wrong label briefly. | A `tui_stage_begin` call passed a substage label by mistake — substages must use `tui_substage_begin`, which never touches the pill row. |
| Live row label disagrees with the header pill. | A `tui_substage_begin` call wrote to `_TUI_CURRENT_STAGE_LABEL` directly. Check for direct writes to that global outside `tui_update_stage`. |
| Stage appears twice in `stages_complete`. | `tui_stage_end` was called twice for the same lifecycle id without an intervening `tui_stage_begin`. Check for early-return paths that miss the begin call. |
| Live-row timer resets when entering a substage. | `tui_substage_begin` should not touch `_TUI_STAGE_START_TS`. If it appears to, check whether your substage body re-routes through `tui_update_stage` (which *does* reset). |
| Recent Event has a stale or wrong attribution. | `_TUI_CURRENT_SUBSTAGE_LABEL` was set without a corresponding clear, *or* the auto-close-and-warn rule fired (look for the warn event). |
| `current_operation` field appears in JSON. | Retired in M115. The field MUST NOT come back — `tests/test_run_op_lifecycle.sh` enforces its absence. |
| `tui_stage_transition` referenced anywhere. | Retired in M116. `tests/test_m116_substage_migration.sh` and `tests/test_tui_lifecycle_invariants.sh` (invariant 7) enforce its absence in production code. |
| Watchdog kills the sidecar mid-run. | A long-running command outside `run_op` is silencing status writes for > `TUI_WATCHDOG_TIMEOUT` seconds. Wrap it in `run_op`. |
| Auto-close warn fires unexpectedly. | A path through your code missed a `tui_substage_end` call. The warn message names the offending substage — search call sites for that label and fix the missing pair. |

---

## 10. Where to make changes

| You want to... | Edit... |
|----------------|---------|
| Add a new pill class | `get_stage_policy`, renderer pill spec |
| Change live-row format | `tools/tui_render_timings.py` |
| Add a JSON field | `_tui_json_build_status`, then renderer consumer |
| Add a new event level | `tui_append_event`, renderer event spec, `_out_emit` routing |
| Change the breadcrumb format | `_tui_compute_source` in `lib/common.sh`, renderer prefix |
| Reset state for tests | Mirror `_activate()` in `tests/test_tui_substage_api.sh` |

---

*Last reviewed: M119 (TUI Lifecycle Invariants + Model Documentation).*
