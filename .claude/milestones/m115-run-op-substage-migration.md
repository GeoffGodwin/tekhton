# M115 - `run_op` Migration and `current_operation` Retirement

<!-- milestone-meta
id: "115"
status: "pending"
-->

## Overview

M104 introduced `run_op` as a wrapper around long shell operations with a
working-bar rendering mode. It works by setting a `_TUI_OPERATION_LABEL` global
which `lib/tui_helpers.sh` serializes into `tui_status.json` as
`current_operation`, and the Python renderer overrides the live-row label when
`agent_status == "working"` to show `current_operation` instead of the stage
label.

This is functionally a parallel substage mechanism — one that predates M110's
policy system and the M113 substage API. It causes the exact bug pattern the
M113–M119 sequence exists to eliminate: during `run_op`, the coder stage's live
row label flips to "Running completion tests" and its timer semantics become
ambiguous (see `tools/tui_render_timings.py:77-80`).

M115 migrates `run_op` onto the M113 substage API and retires
`_TUI_OPERATION_LABEL` / `current_operation` entirely. After M115 there is a
single substage mechanism in the codebase.

**Budget: 1.5x typical milestone effort.** The retirement touches 8 files
across bash libs, Python modules, and tests. Migration is straightforward but
mechanical and test-heavy.

## Design

### Goal 1 — Migrate `run_op` to the substage API

Rewrite `run_op` in `lib/tui_ops.sh` to wrap its operation in
`tui_substage_begin` / `tui_substage_end` instead of setting
`_TUI_OPERATION_LABEL`:

Before (conceptual):
```bash
run_op() {
    local label="$1"; shift
    _TUI_OPERATION_LABEL="$label"
    tui_update_stage ...
    "$@"
    local rc=$?
    _TUI_OPERATION_LABEL=""
    tui_update_stage ...
    return $rc
}
```

After (conceptual):
```bash
run_op() {
    local label="$1"; shift
    tui_substage_begin "$label"
    "$@"
    local rc=$?
    tui_substage_end "$label" "$([ $rc -eq 0 ] && echo PASS || echo FAIL)"
    return $rc
}
```

The "working" agent_status behavior is preserved via existing signals; only
the label-override mechanism changes.

### Goal 2 — Remove the renderer's `current_operation` override

Delete the `agent_status == "working"` branch in
`tools/tui_render_timings.py` (currently lines 77–80) that substitutes
`current_operation` for `current_label`. With M114's substage breadcrumb logic
already live, the same UX now falls out naturally: `run_op "Running completion
tests" bash -c "$TEST_CMD"` inside the coder stage will render as
`coder » Running completion tests` via the substage pathway.

Also remove the `current_operation` fallback branch in `tools/tui_render.py`
active-bar rendering (line ~84).

### Goal 3 — Drop the JSON field

Remove `current_operation` emission from `lib/tui_helpers.sh`'s status-JSON
builder. Old Python consumers running against new bash output simply stop
receiving the field (Python defaults handle absence — already required by
M114).

### Goal 4 — Delete `_TUI_OPERATION_LABEL` state

Remove the global variable declaration and all read/write sites. After M115
the string `_TUI_OPERATION_LABEL` must not appear in any `.sh` file.

### Goal 5 — Update tests

Inventory (from pre-M115 grep):

**Code files (5):**
- `lib/tui_ops.sh` — migrate `run_op`
- `lib/tui_helpers.sh` — drop `current_operation` emission
- `tools/tui_render.py` — drop fallback branch
- `tools/tui_render_timings.py` — drop override branch
- `tools/tui.py` — drop any residual references

**Test files (3):**
- `tests/test_run_op_lifecycle.sh` — rewrite to assert on substage fields
- `tools/tests/test_tui.py` — update any `current_operation` assertions
- `tools/tests/test_tui_render_timings.py` — update any
  `current_operation`/`agent_status="working"` override cases to assert on
  breadcrumb rendering

Each test is rewritten to assert on the substage breadcrumb contract M113/M114
established, not on the retired mechanism.

### Goal 6 — Leave historical milestone docs untouched

`.claude/milestones/m104-tui-operation-liveness.md` and
`m108-tui-stage-timings-column.md` reference the retired fields. These are
historical records; do not rewrite them. M115's own doc (this file) is the
tombstone for `current_operation`.

## Files Modified

| File | Change |
|------|--------|
| `lib/tui_ops.sh` | Rewrite `run_op` on substage API; delete `_TUI_OPERATION_LABEL` |
| `lib/tui_helpers.sh` | Remove `current_operation` from status JSON |
| `tools/tui_render.py` | Remove `current_operation` fallback in active-bar |
| `tools/tui_render_timings.py` | Remove `agent_status == "working"` label-override branch |
| `tools/tui.py` | Remove any residual `current_operation` references |
| `tests/test_run_op_lifecycle.sh` | Rewrite on substage contract |
| `tools/tests/test_tui.py` | Update affected cases |
| `tools/tests/test_tui_render_timings.py` | Update affected cases |

## Acceptance Criteria

- [ ] `run_op LABEL CMD...` causes `current_substage_label=LABEL` to appear in
      `tui_status.json` for the duration of CMD; clears on return.
- [ ] `run_op` return code is preserved (non-zero from wrapped command
      propagates).
- [ ] `_TUI_OPERATION_LABEL` does not appear in any `.sh` file
      (`grep -r _TUI_OPERATION_LABEL lib stages tests` is empty).
- [ ] `current_operation` does not appear in any `.sh`, `.py`, or status-JSON
      consumer file outside historical milestone docs.
- [ ] Stage-timings live row during `run_op "Running completion tests" ...`
      inside coder renders as `coder » Running completion tests`, with the
      coder stage's timer (not reset at run_op entry).
- [ ] `stages_complete` never lists a `run_op` label as its own entry.
- [ ] `tests/test_run_op_lifecycle.sh` passes under the new contract.
- [ ] `tools/tests/test_tui.py` and `tools/tests/test_tui_render_timings.py`
      pass after update.
- [ ] Existing callers of `run_op` (e.g., `lib/gates_completion.sh:86`) require
      no source changes.
- [ ] Shellcheck clean for all touched scripts.
- [ ] `python -m pytest tools/tests/` runs clean.

## Non-Goals

- Changing the set of call sites that invoke `run_op`.
- Introducing new run_op variants or flags.
- Removing the `TUI_LIFECYCLE_V2` opt-out flag.
- Rewriting M104/M108 historical milestone docs.
- Deleting `tui_stage_transition` (M116).
