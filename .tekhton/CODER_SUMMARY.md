# Coder Summary — M108: TUI Stage Timings Column

## Status: COMPLETE

## What Was Implemented

Implemented the M108 design: the bottom of the TUI now splits into a
two-column body — events (left, ratio=2) and stage timings (right, ratio=1).
The timings column lists every completed stage with elapsed time and turn
count, plus a yellow live row for the actively running stage / shell op.

### §1 — `_build_timings_panel` (new function)

Reads `stages_complete` for finished rows and the `stage_label` /
`current_agent_status` / `stage_start_ts` / `agent_turns_max` /
`current_operation` keys for the live row. Behaviour matches the milestone
spec exactly:

- Empty + idle → `(no stages yet)` placeholder.
- Each completed stage → `✓ <label>` (green) or `✗ <label>` (red) for
  verdicts in `{FAIL, FAILED, BLOCKED, REJECT}`.
- Live row only when `current_agent_status` is `running` or `working`. For
  `working`, the label comes from `current_operation` so the visible row
  reflects the actual shell op rather than the prior agent stage.
- Live elapsed is recomputed each tick from `stage_start_ts`; live turns are
  always `--/max` because the Claude CLI only reports the final turn count
  on agent exit (documented as an intentional asymmetry in the milestone).

### §2 — Layout split in `tools/tui.py`

`_build_layout` now produces a `header` + `body` column, with `body`
horizontally split into `events` (ratio=2) and `timings` (ratio=1). The
header layer is unchanged.

### §3 — Re-export for tests

`tools/tui.py` re-exports `_build_timings_panel` alongside the existing
render helpers so tests calling `tui._build_timings_panel(...)` resolve.
`_empty_status()` gained a `current_operation: ""` key so the new tests can
build status dicts without locally redefining the empty-state shape.

### §4 — `tui_hold.py`

Untouched (out of scope per milestone §4).

### §5 — Tests

Added the five tests called out in the milestone, plus the existing 56 tests
all continue to pass:

- `test_timings_panel_empty`
- `test_timings_panel_completed_stages` (also asserts ✓ icon and time strings)
- `test_timings_panel_live_running_row` (asserts `--/70` live turns)
- `test_timings_panel_fail_verdict` (asserts ✗ icon)
- `test_layout_has_timings_column` (asserts both names in
  `layout["body"].children`)

## Architectural Notes

The new `_build_timings_panel` is large enough that adding it directly to
`tui_render.py` would push that file from 240 → ~300+ lines (over the
project ceiling). To stay under the ceiling I followed the existing pattern
used for `tui_render_logo.py` and extracted the new function into
`tui_render_timings.py`. To avoid code duplication and a circular import
between `tui_render` and `tui_render_timings` (both need `_fmt_duration` and
`_SPIN_CHARS`), I created a small shared module `tui_render_common.py` that
both render modules import from. `tui_render.py` re-imports the symbols
from common with `# noqa: F401` so external callers of
`tui_render._fmt_duration` / `tui_render._SPIN_CHARS` continue to work.

This is a structural reorganization, not an API change — every public
symbol is still reachable at its original import path, and `tui.py`'s
re-export block is unchanged in shape (only the new symbol added).

## Files Modified

| File | Status | Purpose |
|------|--------|---------|
| `tools/tui_render_common.py` | NEW (23 lines) | Shared `_fmt_duration` + `_SPIN_CHARS` to break the import cycle between render modules |
| `tools/tui_render_timings.py` | NEW (79 lines) | Holds `_build_timings_panel(status)` |
| `tools/tui_render.py` | MODIFIED (227 lines, was 240) | Imports `_fmt_duration` + `_SPIN_CHARS` from common; re-exports `_build_timings_panel` from timings module |
| `tools/tui.py` | MODIFIED (204 lines, was 196) | Layout split into `body → events + timings`; re-exports `_build_timings_panel`; `_empty_status()` adds `current_operation` |
| `tools/tests/test_tui.py` | MODIFIED (848 lines, was 767) | Adds 5 M108 tests at bottom |

All modified Python files are under the 300-line ceiling. The existing
test file is over the limit but is explicitly out of scope for this
milestone (per the prior reviewer report's non-blocking note: "Python test
file line count" is an out-of-scope item).

## Docs Updated

None — no public-surface changes in this task. The TUI sidecar JSON
schema gained no new keys (every key consumed by the timings panel was
already populated by M97/M104/M106/M107). `_empty_status()` adding
`current_operation: ""` brings it in line with the keys the shell side
already writes (it was previously omitted only because the empty-state
fallback never needed it before this milestone). No CLI flags, no
config keys, no public functions changed.

## Human Notes Status

No human notes were provided in this run.

## Test Verification

- `python -m pytest tools/tests/test_tui.py -q` → 61 passed (56 existing + 5 new)
- `python -m pytest tools/tests/` → 150 passed (full Python suite)
- `bash tests/run_tests.sh` → 408 shell passed, 0 failed; 150 Python passed
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` → exit 0, no output

## Acceptance Criteria Verification

All criteria from the milestone are satisfied:

- [x] Bottom panel has two visible columns: events (left) + Stage timings (right)
- [x] Empty state shows `(no stages yet)` (verified by `test_timings_panel_empty`)
- [x] Completed stages render with ✓, elapsed, turns ratio
  (verified by `test_timings_panel_completed_stages`)
- [x] BLOCKED/FAIL/REJECT verdicts render with ✗ in red
  (verified by `test_timings_panel_fail_verdict`; verdict set in `_FAIL_VERDICTS`)
- [x] Live yellow row updates each tick with elapsed (computed from
  `stage_start_ts` like `_build_active_bar`) and `--/max` turns
  (verified by `test_timings_panel_live_running_row`)
- [x] Sub-stages appear automatically because M107 wires them to
  `tui_stage_end` → `stages_complete` (no special handling needed)
- [x] `working` status uses `current_operation` for the live label (handled
  in the `if agent_status == "working"` branch)
- [x] Layout renders without exceptions on representative widths (existing
  `test_build_layout_full` covers this; new layout asserted by
  `test_layout_has_timings_column`)
- [x] Five new tests pass
- [x] All existing TUI tests pass
- [x] `shellcheck` clean (no `.sh` files modified)
