"""Stage timings panel for tools/tui_render.py (M108).

Extracted to keep tui_render.py under the 300-line ceiling. Exports
_build_timings_panel.

Lifecycle model: see docs/tui-lifecycle-model.md for stage classes, the
live-row vs completed-row split, and substage breadcrumb rendering.
"""
from __future__ import annotations

import time
from typing import Any

from rich.panel import Panel
from rich.table import Table
from rich.text import Text

from tui_render_common import _SPIN_CHARS, _fmt_duration


_FAIL_VERDICTS = {"FAIL", "FAILED", "BLOCKED", "REJECT"}


def _normalize_time(time_str: str) -> str:
    """Normalize a stage time string to the canonical _fmt_duration output.

    Completed-stage rows arrive as raw seconds ("90s"); live rows are formatted
    by _fmt_duration ("1m 30s"). Route plain "<int>s" through _fmt_duration so
    both forms render identically. Anything else (empty, already-formatted,
    pre-hardcoded strings) passes through untouched.
    """
    if not time_str:
        return time_str
    stripped = time_str.strip()
    if stripped.endswith("s"):
        core = stripped[:-1]
        if core.isdigit():
            return _fmt_duration(int(core))
    return time_str


def _build_timings_panel(status: dict[str, Any]) -> Panel:
    stages_complete = status.get("stages_complete") or []
    current_label = status.get("stage_label") or ""
    agent_status = status.get("current_agent_status") or "idle"
    stage_start_ts = int(status.get("stage_start_ts", 0) or 0)
    elapsed_secs = int(status.get("agent_elapsed_secs", 0) or 0)
    turns_max = int(status.get("agent_turns_max", 0) or 0)
    # M114: substage fields are optional — default to empty so old bash →
    # new Python and new bash → old Python remain compatible. We only need the
    # label here; the live-row timer keeps using the parent's stage_start_ts so
    # there is no visible reset at the substage boundary.
    substage_label = status.get("current_substage_label") or ""

    grid = Table.grid(padding=(0, 1))
    grid.add_column(no_wrap=True)
    grid.add_column(no_wrap=True, justify="right")
    grid.add_column(no_wrap=True, justify="right")

    has_live_row = bool(current_label) and agent_status in ("running", "working")

    if not stages_complete and not has_live_row:
        grid.add_row("", Text("(no stages yet)", style="dim italic"), "")
        return Panel(grid, title="Stage timings", border_style="cyan",
                     padding=(0, 1))

    for stage in stages_complete:
        label = stage.get("label") or "?"
        time_str = _normalize_time(stage.get("time") or "")
        turns_str = stage.get("turns") or ""
        verdict = (stage.get("verdict") or "").upper()
        if verdict in _FAIL_VERDICTS:
            icon, style = "\u2717", "red"
        else:
            icon, style = "\u2713", "green"
        grid.add_row(
            Text(f"{icon} {label}", style=style),
            Text(time_str, style="dim"),
            Text(turns_str, style="dim"),
        )

    if has_live_row:
        display_label = current_label

        # M114/M115: when a substage is active, render breadcrumb form
        # "{stage} » {substage}" so the user sees the transient phase without
        # the parent stage label disappearing. Applies to both agent runs
        # ("running") and shell ops ("working") — M115 migrated run_op onto
        # the substage API, so the working state now flows through the same
        # path instead of the retired current_operation override.
        if substage_label and current_label and agent_status in ("running",
                                                                 "working"):
            display_label = f"{current_label} » {substage_label}"

        if stage_start_ts > 0:
            live_elapsed = max(0, int(time.time()) - stage_start_ts)
        else:
            live_elapsed = elapsed_secs

        # Turns are unknown until the agent exits — Claude CLI reports the
        # final count only on process termination. Normal running rows show
        # "--/max"; during a substage (M114) or a shell op (M115 working
        # state, which does not use turns at all) the parent counter is
        # either stale or meaningless, so blank the column.
        if agent_status == "working" or (
            substage_label and agent_status == "running"
        ):
            live_turns = ""
        else:
            live_turns = f"--/{turns_max}" if turns_max else "--"
        char = _SPIN_CHARS[int(time.time() * 10) % len(_SPIN_CHARS)]
        grid.add_row(
            Text(f"{char} {display_label}", style="yellow bold"),
            Text(_fmt_duration(live_elapsed), style="yellow"),
            Text(live_turns, style="yellow dim"),
        )

    return Panel(grid, title="Stage timings", border_style="cyan", padding=(0, 1))
