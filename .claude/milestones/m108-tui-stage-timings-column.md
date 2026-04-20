# M108 — TUI Stage Timings Column
<!-- milestone-meta
id: "108"
status: "done"
-->

## Overview

When the CLI output mode was replaced by the TUI sidecar, per-stage timing
summaries were lost. The old CLI printed after every stage:

```
[Coder]   Turns: 28/70 | Time: 3m12s
[Tester]  Turns: 14/30 | Time: 1m44s
```

These repeated on every line but gave the user a clear sense of progress and cost.
The TUI has `stages_complete` in its JSON (populated since M97/M106), but nothing
renders that data anywhere.

This milestone splits the bottom panel into two columns:
- **Left (ratio=2):** Recent events — existing, unchanged.
- **Right (ratio=1):** Stage timings — a growing list of completed stages with
  elapsed time and turns, plus the currently-running stage with a live clock.

Sub-stages (scout, rework) appear as their own rows since they are first-class
entries in `stages_complete` after M107. The panel grows naturally as each stage
completes; no special handling per stage type is required.

## Design

### §1 — `_build_timings_panel` in `tools/tui_render.py`

The timings panel reads from two sources in the status JSON:

1. `stages_complete`: list of completed stage objects — used for finished rows.
2. `stage_label` + `current_agent_status` + `stage_start_ts` / `agent_elapsed_secs`
   + `agent_turns_used` / `agent_turns_max` — used for the live "current" row.

**Prerequisites:** `time` is already imported in `tui_render.py` (used by
`_build_active_bar`). No new import needed for `time.time()` calls below.

```python
def _build_timings_panel(status: dict[str, Any]) -> Panel:
    stages_complete = status.get("stages_complete") or []
    current_label   = status.get("stage_label") or ""
    agent_status    = status.get("current_agent_status") or "idle"
    stage_start_ts  = int(status.get("stage_start_ts", 0) or 0)
    elapsed_secs    = int(status.get("agent_elapsed_secs", 0) or 0)
    turns_used      = int(status.get("agent_turns_used", 0) or 0)
    turns_max       = int(status.get("agent_turns_max", 0) or 0)

    grid = Table.grid(padding=(0, 1))
    grid.add_column(no_wrap=True)                      # icon + label
    grid.add_column(no_wrap=True, justify="right")     # elapsed
    grid.add_column(no_wrap=True, justify="right")     # turns

    if not stages_complete and not (current_label and agent_status in ("running", "working")):
        grid.add_row("", Text("(no stages yet)", style="dim italic"), "")
    else:
        for stage in stages_complete:
            label      = stage.get("label") or "?"
            time_str   = stage.get("time") or ""
            turns_str  = stage.get("turns") or ""
            verdict    = (stage.get("verdict") or "").upper()
            if verdict in ("FAIL", "FAILED", "BLOCKED", "REJECT"):
                icon, style = "\u2717", "red"      # ✗
            else:
                icon, style = "\u2713", "green"    # ✓
            grid.add_row(
                Text(f"{icon} {label}", style=style),
                Text(time_str, style="dim"),
                Text(turns_str, style="dim"),
            )

        # Live "current" row: shown while a stage is actively running.
        # Elapsed updates every tick (computed from stage_start_ts in Python).
        # Turns always show "--/max" during execution because the Claude CLI only
        # reports the final turn count when the agent exits; there is no live
        # turn-by-turn stream available to the shell side during the run.
        if current_label and agent_status in ("running", "working"):
            if stage_start_ts > 0:
                live_elapsed = max(0, int(time.time()) - stage_start_ts)
            else:
                live_elapsed = elapsed_secs
            # Turns are unknown until agent exit: always show "--/max"
            live_turns = f"--/{turns_max}" if turns_max else "--"
            char = _SPIN_CHARS[int(time.time() * 10) % len(_SPIN_CHARS)]
            grid.add_row(
                Text(f"{char} {current_label}", style="yellow bold"),
                Text(_fmt_duration(live_elapsed), style="yellow"),
                Text(live_turns, style="yellow dim"),
            )

    return Panel(grid, title="Stage timings", border_style="cyan", padding=(0, 1))
```

**Design notes:**

- The `"working"` status (shell ops via `run_op`) also shows a live row, since
  long-running shell operations like test baseline capture are meaningful progress.
  The `current_label` during `"working"` comes from `current_operation`.
  
  Update the live-row condition in the implementation to also show `current_operation`
  for the `"working"` case:
  ```python
  if agent_status == "working":
      display_label = status.get("current_operation") or current_label
  else:
      display_label = current_label
  ```

- Sub-stages (scout, rework) appear as normal rows because M107 wires them to
  `tui_stage_end`, which appends to `stages_complete`. No special handling needed.

- The `time_str` column uses whatever the shell side stored in the stage record
  (e.g., `"45s"`, `"2m10s"`). The live row uses `_fmt_duration(live_elapsed)` for
  consistency.

- **Turns are only available after agent exit.** The Claude CLI does not stream
  turn counts during execution; `_turns_file` is only written when the agent
  process terminates. The live row therefore always shows `--/max` for turns.
  Completed rows in `stages_complete` always have the real final count (e.g.,
  `"28/70"`), because `tui_stage_end` is called after `run_agent` returns. This
  asymmetry is intentional and correct: elapsed is a local clock computation,
  while turns require the agent to report back.

### §2 — Layout Split in `tools/tui.py`

Replace the single `events` layout with a horizontal body split:

```python
def _build_layout(status: dict[str, Any], event_lines: int) -> Layout:
    layout = Layout()
    layout.split_column(
        Layout(name="header", size=8),
        Layout(name="body", ratio=1),
    )
    layout["body"].split_row(
        Layout(name="events", ratio=2),
        Layout(name="timings", ratio=1),
    )
    layout["header"].update(_build_header_bar(status))
    layout["events"].update(_build_events_panel(status, event_lines))
    layout["timings"].update(_build_timings_panel(status))
    return layout
```

### §3 — Re-export `_build_timings_panel` for Tests

`tools/tui.py` re-exports render helpers from `tui_render` so that test files
importing `tui` can access them. Add `_build_timings_panel` to the existing
re-export block:

```python
from tui_render import (  # noqa: F401 — re-exports for tests
    _build_events_panel,
    _build_header_bar,
    _build_logo,
    _build_simple_logo,
    _build_timings_panel,   # ← ADD
    _fmt_duration,
)
```

### §4 — `hold_on_complete` Event Log: Out of Scope

The `_hold_on_complete` function in `tools/tui_hold.py` already prints a full
event log to the terminal after the TUI exits. A future milestone may refine
this to surface `stages_complete` timing rows and reduce duplication with the
new timings column. **No changes to `tui_hold.py` in this milestone.**

### §5 — Test Coverage in `tools/tests/test_tui.py`

Add tests covering:

```python
# Use tui._empty_status() from tools/tui.py (re-exported for tests).
# If _empty_status() is missing "current_operation", add it there as part
# of this milestone rather than redefining a local copy.


def test_timings_panel_empty():
    """Empty stages_complete + idle → shows '(no stages yet)'"""
    status = {**tui._empty_status(), "current_operation": ""}
    panel = tui._build_timings_panel(status)
    assert "(no stages yet)" in str(panel.renderable)

def test_timings_panel_completed_stages():
    """Completed stages render with ✓ icon, elapsed, and turns"""
    status = {**tui._empty_status(), "current_operation": "", "stages_complete": [
        {"label": "intake", "model": "", "turns": "3/10", "time": "8s", "verdict": None},
        {"label": "scout",  "model": "", "turns": "5/10", "time": "12s", "verdict": None},
    ]}
    panel = tui._build_timings_panel(status)
    rendered = str(panel.renderable)
    assert "intake" in rendered
    assert "scout" in rendered

def test_timings_panel_live_running_row():
    """Running stage appears as a live yellow row below completed stages"""
    status = {**tui._empty_status(),
              "current_operation": "",
              "stages_complete": [{"label": "intake", "model": "",
                                   "turns": "3/10", "time": "8s", "verdict": None}],
              "stage_label": "coder",
              "current_agent_status": "running",
              "stage_start_ts": int(time.time()) - 30,
              "agent_turns_max": 70}
    panel = tui._build_timings_panel(status)
    rendered = str(panel.renderable)
    assert "coder" in rendered
    assert "--/70" in rendered  # turns unknown until agent exits; live row always shows --/max

def test_timings_panel_fail_verdict():
    """Failed stage renders with ✗ icon in red"""
    status = {**tui._empty_status(), "current_operation": "", "stages_complete": [
        {"label": "security", "model": "", "turns": "8/15", "time": "45s",
         "verdict": "BLOCKED"},
    ]}
    panel = tui._build_timings_panel(status)
    rendered = str(panel.renderable)
    assert "security" in rendered

def test_layout_has_timings_column():
    """Layout includes both 'events' and 'timings' regions"""
    layout = tui._build_layout(tui._empty_status(), event_lines=20)
    names = [child.name for child in layout["body"].children]
    assert "events" in names
    assert "timings" in names
```

### §6 — Minimum Terminal Width

The timings column needs approximately 28 characters minimum (icon+label ≈ 14,
elapsed ≈ 7, turns ≈ 7). With ratio=1 of the body, on an 80-column terminal the
timings panel gets ~26 columns after borders, which is tight but renders without
hard wrapping because all columns use `no_wrap=True`.

Rich clips overflowing text gracefully on narrow terminals. No special minimum-width
guard is required. If the user's terminal is narrower than 60 columns, both panels
compress and content is clipped — consistent with existing Rich behaviour in the
header panel.

## Files Modified

| File | Change |
|------|--------|
| `tools/tui_render.py` | Add `_build_timings_panel(status)` |
| `tools/tui.py` | Restructure `_build_layout` to split body into events+timings; add `_build_timings_panel` to re-export block; add `current_operation` key to `_empty_status()` |
| `tools/tests/test_tui.py` | Add five new tests covering the timings panel and layout split |

## Acceptance Criteria

- [ ] Bottom panel has two visible columns: "Recent events" on the left, "Stage timings" on the right
- [ ] When no stages have run yet, the timings column shows `(no stages yet)`
- [ ] As each stage completes, its row appears in the timings column with a ✓ icon, elapsed time, and turns ratio
- [ ] A stage with verdict BLOCKED, FAIL, or REJECT shows a ✗ icon in red
- [ ] While a stage is running, a yellow live row appears at the bottom of the timings column with the current elapsed and turn count; it updates on each TUI tick
- [ ] Sub-stages (scout, rework) appear as their own rows in the timings column
- [ ] During a `run_op` shell operation (`current_agent_status == "working"`), the live row shows the operation label from `current_operation` with the working spinner
- [ ] The layout renders without Python exceptions on 80-column and 120-column terminals (test via `console.width` override in tests)
- [ ] All five new tests in `test_tui.py` pass
- [ ] All existing TUI tests continue to pass (`python -m pytest tools/tests/`)
- [ ] `shellcheck` passes on any modified `.sh` files with zero new warnings (none expected for this milestone)
