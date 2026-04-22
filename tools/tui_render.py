"""Rendering helpers for tools/tui.py (M98 layout redesign).

Exports:
    _fmt_duration, _build_logo, _build_simple_logo, _build_header_bar,
    _build_events_panel, _build_timings_panel

Imported by tui.py which re-exports these symbols for test discovery.

Lifecycle model: see docs/tui-lifecycle-model.md for stage classes, pill/
timings/events ownership, and the source-attribution flow used by the
events panel.
"""
from __future__ import annotations

import time
from typing import Any

from rich.panel import Panel
from rich.progress_bar import ProgressBar
from rich.table import Table
from rich.text import Text

from tui_render_common import _SPIN_CHARS, _fmt_duration  # noqa: F401
from tui_render_logo import _build_logo, _build_simple_logo  # noqa: F401
from tui_render_timings import _build_timings_panel  # noqa: F401


# ---- Stage pills ------------------------------------------------------------

_STAGE_PILL_SPEC = {
    "pending":  ("\u25cb", "dim"),           # ○
    "running":  ("\u25b6", "yellow bold"),    # ▶
    "complete": ("\u2713", "green"),         # ✓
    "fail":     ("\u2717", "red"),           # ✗
}


def _stage_state(stage: str, stages_complete: list[dict[str, Any]],
                 current_label: str, current_status: str) -> str:
    # Running state takes priority over history; a stage may have prior
    # completed entries (multiple rework cycles) and still be running again.
    if stage.lower() == (current_label or "").lower():
        if current_status == "running":
            return "running"
    for s in stages_complete:
        if (s.get("label") or "").lower() == stage.lower():
            v = (s.get("verdict") or "").upper()
            return "fail" if v in ("FAIL", "FAILED", "BLOCKED", "REJECT") else "complete"
    if stage.lower() == (current_label or "").lower():
        if current_status == "complete":
            return "complete"
    return "pending"


def _build_stage_pills(status: dict[str, Any]) -> Text:
    # M100: stage_order is populated by get_display_stage_order() in
    # lib/pipeline_order.sh before the sidecar starts. If the JSON hasn't
    # been written yet (very early startup) fall back to numbered placeholders
    # derived from stage_total — never a hardcoded stage list, which would
    # silently mask ordering regressions when the pipeline is reconfigured.
    order = status.get("stage_order") or []
    if not order:
        stage_total = int(status.get("stage_total", 0) or 0)
        if stage_total > 0:
            order = [f"stage-{i + 1}" for i in range(stage_total)]
    stages_complete = status.get("stages_complete") or []
    current_label = status.get("stage_label") or ""
    current_status = status.get("current_agent_status") or "idle"
    text = Text()
    for i, stage in enumerate(order):
        state = _stage_state(stage, stages_complete, current_label, current_status)
        icon, style = _STAGE_PILL_SPEC[state]
        if i > 0:
            text.append("  ")
        text.append(f"{icon} {stage}", style=style)
    return text


# ---- Active-stage bar -------------------------------------------------------

def _model_short(model: str) -> str:
    if not model:
        return ""
    return model[len("claude-"):] if model.startswith("claude-") else model


def _build_working_bar(status: dict[str, Any]) -> Table:
    # M115: current_operation was retired in favour of the M113 substage API.
    # During run_op the wrapped label lives in current_substage_label and the
    # parent pipeline stage continues to own stage_label. Render them as a
    # "parent » label" breadcrumb when both are present; fall back
    # gracefully when only one (or neither) is set.
    stage_label = status.get("stage_label") or ""
    sublabel = status.get("current_substage_label") or ""
    if stage_label and sublabel:
        op_label = f"{stage_label} » {sublabel}"
    elif sublabel:
        op_label = sublabel
    elif stage_label:
        op_label = stage_label
    else:
        op_label = "Working\u2026"
    char = _SPIN_CHARS[int(time.time() * 10) % len(_SPIN_CHARS)]
    grid = Table.grid(padding=(0, 1), expand=False)
    grid.add_column(no_wrap=True); grid.add_column(no_wrap=True)
    grid.add_row(Text(op_label, style="bold white"),
                 Text(f"{char} Working", style="yellow"))
    return grid


def _build_active_bar(status: dict[str, Any]) -> Table:
    label = status.get("stage_label") or "\u2014"
    model = _model_short(status.get("agent_model") or "")
    used = int(status.get("agent_turns_used", 0) or 0)
    maxt = int(status.get("agent_turns_max", 0) or 0)
    stage_start_ts = int(status.get("stage_start_ts", 0) or 0)
    elapsed_secs = int(status.get("agent_elapsed_secs", 0) or 0)

    if stage_start_ts > 0:
        elapsed = max(0, int(time.time()) - stage_start_ts)   # live clock
    else:
        elapsed = elapsed_secs                                 # frozen at completion
    agent_status = status.get("current_agent_status") or "idle"

    # M104: shell-op "working" state shows only the operation label + spinner.
    # Model / turns / elapsed are agent-only concepts and don't apply here.
    if agent_status == "working":
        return _build_working_bar(status)

    grid = Table.grid(padding=(0, 1), expand=False)
    for _ in range(6):
        grid.add_column(no_wrap=True)

    bar_total = max(maxt, 1)
    bar = ProgressBar(total=bar_total, completed=min(used, bar_total), width=12)
    if agent_status == "running":
        char = _SPIN_CHARS[int(time.time() * 10) % len(_SPIN_CHARS)]
        spinner = Text(f"{char} Running", style="yellow")
    elif agent_status == "complete":
        spinner = Text("\u2713 Complete", style="green")
    elif agent_status == "idle" and elapsed > 0:
        # idle + elapsed > 0 = stage finished (tui_stage_end was called).
        # Note: tui_finish_stage always sets status to "idle", never "complete";
        # the presence of a frozen elapsed value is the signal that a stage ended.
        spinner = Text("\u2713 Complete", style="green")
    else:
        spinner = Text("idle", style="dim")
        elapsed = 0  # suppress "0s" for the initial pre-stage idle state

    turns_str = f"{used}/{maxt}" if maxt else f"{used}"
    grid.add_row(
        Text(label, style="bold"),
        Text(model or "\u2014", style="dim"),
        bar,
        Text(f"{turns_str} turns", style="dim"),
        Text(_fmt_duration(elapsed), style="dim"),
        spinner,
    )
    return grid


# ---- Header bar (logo + context) --------------------------------------------

def _truncate(s: str, limit: int) -> str:
    return s if len(s) <= limit else s[:limit] + "\u2026"


def _build_context(status: dict[str, Any]) -> Table:
    milestone = status.get("milestone") or ""
    title = status.get("milestone_title") or ""
    task = status.get("task") or ""
    run_mode = status.get("run_mode") or "task"
    attempt = status.get("attempt", 1) or 1
    max_attempts = status.get("max_attempts", 1) or 1
    cli_flags = status.get("cli_flags") or ""

    grid = Table.grid(expand=True)
    grid.add_column(no_wrap=False)

    header = Text()
    header.append("TEKHTON", style="bold cyan")
    if milestone:
        header.append(f"  M{milestone}", style="bold white")
    if title:
        header.append(f" \u2014 {_truncate(title, 50)}", style="white")
    grid.add_row(header)

    meta = Text(style="dim")
    meta.append(run_mode)
    meta.append(f"  \u00b7  Pass {attempt}/{max_attempts}")
    if cli_flags:
        meta.append(f"  \u00b7  {cli_flags}")
    grid.add_row(meta)

    if task:
        grid.add_row(Text(f'Task: "{_truncate(task, 60)}"', style="white"))
    else:
        grid.add_row("")

    grid.add_row("")  # blank spacer
    grid.add_row(_build_stage_pills(status))
    grid.add_row(_build_active_bar(status))
    return grid


def _build_header_bar(status: dict[str, Any]) -> Panel:
    logo = _build_logo(status)
    context = _build_context(status)
    outer = Table.grid(expand=True, padding=(0, 1))
    outer.add_column(no_wrap=True, width=14)
    outer.add_column(ratio=1)
    outer.add_row(logo, context)
    clock = time.strftime("%H:%M:%S")
    return Panel(
        outer,
        border_style="cyan",
        padding=(0, 1),
        subtitle=f"[dim]{clock}[/dim]",
        subtitle_align="right",
    )


# ---- Events panel -----------------------------------------------------------

_EVENT_LEVEL_STYLES = {"info": "white", "warn": "yellow",
                       "error": "red", "success": "green"}


def _build_events_panel(status: dict[str, Any], max_lines: int) -> Panel:
    events = status.get("recent_events") or []
    if max_lines > 0:
        events = events[-max_lines:]
    grid = Table.grid(padding=(0, 1))
    grid.add_column(no_wrap=True, style="dim")
    grid.add_column(no_wrap=False)
    if not events:
        grid.add_row("", Text("(no events yet)", style="dim italic"))
    else:
        for ev in events:
            ts = ev.get("ts", "")
            level = ev.get("level", "info")
            msg = ev.get("msg", "")
            source = ev.get("source", "") or ""
            style = _EVENT_LEVEL_STYLES.get(level, "white")
            # M117: render attribution as a dim bracketed prefix so substage
            # breadcrumbs ("coder » scout") are visually distinct from the
            # message body without disrupting the existing level-coloured
            # styling. Events without a source render unchanged.
            if source:
                line = Text()
                line.append(f"[{source}] ", style="dim")
                line.append(msg, style=style)
                grid.add_row(ts, line)
            else:
                grid.add_row(ts, Text(msg, style=style))
    return Panel(grid, title="Recent events", border_style="cyan", padding=(0, 1))
