#!/usr/bin/env python3
"""Tekhton TUI sidecar: reads tui_status.json and renders a rich.live layout.

Runs as a background process spawned by lib/tui.sh. Reads the status file on
a tick, re-renders, and exits when the status file marks complete=true or
when the parent kills it (SIGTERM/SIGINT). On complete, exits the Live
alternate screen and dumps the final event log via tui_hold._hold_on_complete
so the user can read the full run history before the finalize banner prints.

Layout (M108): size=8 header panel (logo + run context + stage pills +
active-stage bar) above a ratio=1 body that splits horizontally into a
ratio=2 events panel (left) and a ratio=1 stage-timings panel (right).
See .claude/milestones/m108-tui-stage-timings-column.md.
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
import time
from pathlib import Path
from typing import Any

from rich.console import Console
from rich.layout import Layout
from rich.live import Live

# Re-export render helpers so tests that `import tui` can access
# `tui._build_logo`, `tui._build_header_bar`, etc.
from tui_render import (  # noqa: F401 — re-exports for tests
    _build_events_panel,
    _build_header_bar,
    _build_logo,
    _build_simple_logo,
    _build_timings_panel,
    _fmt_duration,
)
from tui_hold import _hold_on_complete  # noqa: F401 — re-export for tests

_STOP = False


def _handle_signal(_signum, _frame):
    global _STOP
    _STOP = True


def _read_status(path: Path) -> dict[str, Any] | None:
    try:
        raw = path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError):
        return None
    if not raw.strip():
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def _empty_status() -> dict[str, Any]:
    return {
        "version": 1,
        "milestone": "",
        "milestone_title": "Starting...",
        "task": "",
        "attempt": 1,
        "max_attempts": 1,
        "stage_label": "",
        "stage_num": 0,
        "stage_total": 0,
        "agent_turns_used": 0,
        "agent_turns_max": 0,
        "agent_elapsed_secs": 0,
        "stage_start_ts": 0,
        "pipeline_elapsed_secs": 0,
        "stages_complete": [],
        "current_agent_status": "idle",
        "current_operation": "",
        "recent_events": [],
        "run_mode": "task",
        "cli_flags": "",
        "stage_order": [],
        "complete": False,
    }


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--status-file", required=True, type=Path)
    parser.add_argument("--tick-ms", type=int, default=500)
    parser.add_argument("--event-lines", type=int, default=60)
    parser.add_argument("--simple-logo", action="store_true")
    parser.add_argument(
        "--watchdog-secs",
        type=int,
        default=0,
        help=(
            "Self-terminate after this many seconds of status-file inactivity "
            "when agent_status is idle and complete is still false. "
            "0 = disabled. Prevents the sidecar from hanging indefinitely when "
            "the parent shell blocks (e.g. on a slow git pre-commit hook) before "
            "it can send the complete signal."
        ),
    )
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    tick = max(0.05, args.tick_ms / 1000.0)
    event_lines = max(0, args.event_lines)
    simple_logo = args.simple_logo
    watchdog_secs = max(0, args.watchdog_secs)

    try:
        _tty = open("/dev/tty", "w")  # noqa: SIM115 — lifetime = sidecar
        console = Console(file=_tty, force_terminal=True)
    except OSError:
        console = Console(force_terminal=True)

    last_status: dict[str, Any] = _empty_status()
    if simple_logo:
        last_status["simple_logo"] = True

    # Watchdog: track when the status file was last modified so we can
    # self-terminate if the parent shell stops updating it while idle.
    _last_mtime: float = 0.0
    _last_mtime_time: float = time.monotonic()
    try:
        _last_mtime = args.status_file.stat().st_mtime
    except OSError:
        pass

    with Live(
        _build_layout(last_status, event_lines),
        console=console,
        refresh_per_second=max(1, int(1 / tick)),
        screen=True,
        transient=True,
    ) as live:
        while not _STOP:
            status = _read_status(args.status_file) or last_status
            if simple_logo:
                status["simple_logo"] = True
            try:
                live.update(_build_layout(status, event_lines))
            except Exception:  # noqa: BLE001 - render failures must not crash
                pass
            last_status = status
            if status.get("complete"):
                time.sleep(tick)
                break

            # Watchdog: if the status file hasn't been touched for watchdog_secs
            # while the pipeline is idle (all stages done, no agent running),
            # self-terminate so the terminal isn't stuck indefinitely when the
            # parent shell blocks before sending the complete signal.
            if watchdog_secs > 0:
                try:
                    cur_mtime = args.status_file.stat().st_mtime
                    if cur_mtime != _last_mtime:
                        _last_mtime = cur_mtime
                        _last_mtime_time = time.monotonic()
                except OSError:
                    pass
                if (
                    status.get("current_agent_status") == "idle"
                    and status.get("agent_turns_used", 0) > 0
                    and time.monotonic() - _last_mtime_time > watchdog_secs
                ):
                    break

            time.sleep(tick)

    if last_status.get("complete"):
        try:
            _hold_on_complete(last_status, console)
        except Exception:  # noqa: BLE001 — never block finalize
            pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
