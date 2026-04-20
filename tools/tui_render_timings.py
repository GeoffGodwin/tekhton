"""Stage timings panel for tools/tui_render.py (M108).

Extracted to keep tui_render.py under the 300-line ceiling. Exports
_build_timings_panel.
"""
from __future__ import annotations

import time
from typing import Any

from rich.panel import Panel
from rich.table import Table
from rich.text import Text

from tui_render_common import _SPIN_CHARS, _fmt_duration


_FAIL_VERDICTS = {"FAIL", "FAILED", "BLOCKED", "REJECT"}


def _build_timings_panel(status: dict[str, Any]) -> Panel:
    stages_complete = status.get("stages_complete") or []
    current_label = status.get("stage_label") or ""
    agent_status = status.get("current_agent_status") or "idle"
    stage_start_ts = int(status.get("stage_start_ts", 0) or 0)
    elapsed_secs = int(status.get("agent_elapsed_secs", 0) or 0)
    turns_max = int(status.get("agent_turns_max", 0) or 0)

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
        time_str = stage.get("time") or ""
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
        # During shell-op "working" state the meaningful label lives in
        # current_operation (the agent stage label may be from the prior step).
        if agent_status == "working":
            display_label = status.get("current_operation") or current_label
        else:
            display_label = current_label

        if stage_start_ts > 0:
            live_elapsed = max(0, int(time.time()) - stage_start_ts)
        else:
            live_elapsed = elapsed_secs

        # Turns are unknown until the agent exits — Claude CLI reports the
        # final count only on process termination. Always show "--/max".
        live_turns = f"--/{turns_max}" if turns_max else "--"
        char = _SPIN_CHARS[int(time.time() * 10) % len(_SPIN_CHARS)]
        grid.add_row(
            Text(f"{char} {display_label}", style="yellow bold"),
            Text(_fmt_duration(live_elapsed), style="yellow"),
            Text(live_turns, style="yellow dim"),
        )

    return Panel(grid, title="Stage timings", border_style="cyan", padding=(0, 1))
