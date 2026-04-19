"""Hold-on-complete handler for tools/tui.py (M98 §6).

After the rich.Live loop exits (complete=true in status), dump the final
summary and full event log to /dev/tty in normal scroll, then wait for
Enter so the user can read the run history before the finalize banner
prints.
"""
from __future__ import annotations

import time
from typing import Any

from rich.console import Console

from tui_render import _EVENT_LEVEL_STYLES, _fmt_duration, _truncate


def _verdict_style(verdict: str) -> str:
    v = (verdict or "").upper()
    if v == "SUCCESS":
        return "bold green"
    if v in ("FAIL", "FAILED", "BLOCKED"):
        return "bold red"
    return "bold yellow"


def _hold_on_complete(status: dict[str, Any], console: Console) -> None:
    verdict = (status.get("verdict") or "").upper()
    pipeline_elapsed = int(status.get("pipeline_elapsed_secs", 0) or 0)
    task = status.get("task") or ""
    milestone = status.get("milestone") or ""

    console.print()
    console.rule("[bold cyan]Tekhton \u2014 Run Complete[/bold cyan]", style="cyan")

    vstyle = _verdict_style(verdict)
    verdict_label = verdict or "COMPLETE"
    pieces = [
        f"  Verdict: [{vstyle}]{verdict_label}[/{vstyle}]",
        f"Elapsed: {_fmt_duration(pipeline_elapsed)}",
    ]
    if milestone:
        pieces.append(f"Milestone: {milestone}")
    if task:
        pieces.append(f'Task: "{_truncate(task, 60)}"')
    console.print("   ".join(pieces))
    console.print()

    events = status.get("recent_events") or []
    if events:
        console.print("[bold]Event log:[/bold]", style="dim")
        for ev in events:
            ts = ev.get("ts", "")
            level = ev.get("level", "info")
            msg = ev.get("msg", "")
            style = _EVENT_LEVEL_STYLES.get(level, "white")
            console.print(f"  [dim]{ts}[/dim]  [{style}]{msg}[/{style}]")
        console.print()

    action_items = status.get("action_items") or []
    if action_items:
        console.print("[bold]Action items:[/bold]", style="dim")
        for item in action_items:
            msg = item.get("msg", "")
            sev = item.get("severity", "normal")
            if sev == "critical":
                prefix, style, suffix = "\u2717", "red", " [CRITICAL]"
            elif sev == "warning":
                prefix, style, suffix = "\u26a0", "yellow", ""
            else:
                prefix, style, suffix = "\u2139", "cyan", ""
            console.print(f"  [{style}]{prefix} {msg}{suffix}[/{style}]")
        console.print()

    try:
        tty_in = open("/dev/tty", "r")
    except OSError:
        # Non-interactive fallback: brief pause then continue.
        time.sleep(3)
        return
    try:
        console.print(
            "[dim]Press [bold]Enter[/bold] to continue\u2026[/dim]", end="",
        )
        tty_in.readline()
    finally:
        tty_in.close()
