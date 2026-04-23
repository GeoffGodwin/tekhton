"""Quota-pause active-bar renderer for tools/tui_render.py (M124).

Extracted to keep tui_render.py under the 300-line ceiling. Exports
_build_paused_bar.

Renders the active-stage bar while enter_quota_pause in lib/quota.sh has
the pipeline waiting on a Claude usage-limit refresh. The parent stage
label is preserved on the left so the user can see which stage was
running; the body shows an amber PAUSED indicator, a countdown to the
next probe, the total time spent paused, and a truncated reason string.
"""
from __future__ import annotations

import time
from typing import Any

from rich.table import Table
from rich.text import Text

from tui_render_common import _fmt_duration


def _build_paused_bar(status: dict[str, Any]) -> Table:
    stage_label = status.get("stage_label") or "—"
    reason = status.get("pause_reason") or "Rate limited"
    pause_started_at = int(status.get("pause_started_at", 0) or 0)
    next_probe_at = int(status.get("pause_next_probe_at", 0) or 0)

    now = int(time.time())
    paused_for = max(0, now - pause_started_at) if pause_started_at else 0
    next_in = max(0, next_probe_at - now) if next_probe_at else 0

    if next_in > 0:
        countdown_mins = next_in // 60
        countdown_secs = next_in % 60
        countdown_text = f"next probe in {countdown_mins}m{countdown_secs:02d}s"
    elif next_probe_at:
        countdown_text = "probe due"
    else:
        countdown_text = "awaiting refresh"

    if len(reason) > 48:
        reason_short = reason[:47] + "…"
    else:
        reason_short = reason

    grid = Table.grid(padding=(0, 1), expand=False)
    grid.add_column(no_wrap=True)
    grid.add_column(no_wrap=True)
    grid.add_column(no_wrap=True)
    grid.add_column(no_wrap=True)
    grid.add_row(
        Text(stage_label, style="bold"),
        Text("⏸ PAUSED — quota refresh", style="bold yellow"),
        Text(f"{countdown_text} · paused {_fmt_duration(paused_for)}",
             style="yellow"),
        Text(reason_short, style="dim yellow"),
    )
    return grid
