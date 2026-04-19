"""M103 — action-item rendering tests for tools/tui_hold.py.

The _hold_on_complete() function is what the TUI sidecar invokes after the
rich.Live loop exits. When the pipeline emits structured action items (via
out_action_item in lib/output_format.sh), they must appear beneath an
"Action items:" header with per-severity icons; an empty or missing list
must suppress the header entirely.

These two tests cover the spec's acceptance criteria from M103 §6.
"""
from __future__ import annotations

import builtins
import io
import sys
from pathlib import Path

import pytest

pytest.importorskip("rich")

from rich.console import Console  # noqa: E402

TOOLS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS_DIR))

import tui  # noqa: E402


def _make_console() -> tuple[Console, io.StringIO]:
    sio = io.StringIO()
    return Console(file=sio, force_terminal=False, width=80), sio


def _no_tty(monkeypatch: pytest.MonkeyPatch) -> None:
    real_open = builtins.open

    def fake_open(path, *args, **kwargs):
        if str(path) == "/dev/tty":
            raise OSError("no tty in test env")
        return real_open(path, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", fake_open)
    monkeypatch.setattr("tui_hold.time.sleep", lambda _s: None)


def _base_status() -> dict:
    return {
        "version": 1,
        "run_id": "run_m103",
        "milestone": "103",
        "milestone_title": "Output Bus Tests + Integration Validation",
        "task": "M103",
        "attempt": 1,
        "max_attempts": 5,
        "stage_num": 0,
        "stage_total": 0,
        "stage_label": "",
        "agent_turns_used": 0,
        "agent_turns_max": 0,
        "agent_elapsed_secs": 0,
        "agent_model": "",
        "stage_start_ts": 0,
        "pipeline_elapsed_secs": 42,
        "run_mode": "milestone",
        "cli_flags": "",
        "stage_order": [],
        "stages_complete": [],
        "current_agent_status": "idle",
        "last_event": "",
        "recent_events": [],
        "action_items": [],
        "verdict": "SUCCESS",
        "complete": True,
    }


def test_action_items_rendered(monkeypatch: pytest.MonkeyPatch) -> None:
    """All three severity levels render with their distinct icon + suffix."""
    _no_tty(monkeypatch)
    console, sio = _make_console()

    status = _base_status()
    status["action_items"] = [
        {"msg": "Rotate DB credentials", "severity": "critical"},
        {"msg": "Review drift log", "severity": "warning"},
        {"msg": "Open a PR", "severity": "normal"},
    ]

    tui._hold_on_complete(status, console)
    output = sio.getvalue()

    assert "Action items:" in output
    assert "Rotate DB credentials" in output
    assert "Review drift log" in output
    assert "Open a PR" in output
    assert "[CRITICAL]" in output
    assert "\u2717" in output  # critical
    assert "\u26a0" in output  # warning
    assert "\u2139" in output  # normal


def test_empty_action_items_no_section(monkeypatch: pytest.MonkeyPatch) -> None:
    """Empty list AND missing key both suppress the 'Action items:' header."""
    _no_tty(monkeypatch)

    console, sio = _make_console()
    status = _base_status()
    status["action_items"] = []
    tui._hold_on_complete(status, console)
    assert "Action items:" not in sio.getvalue()

    console, sio = _make_console()
    status = _base_status()
    status.pop("action_items", None)
    tui._hold_on_complete(status, console)
    assert "Action items:" not in sio.getvalue()

    console, sio = _make_console()
    status = _base_status()
    status["action_items"] = None
    tui._hold_on_complete(status, console)
    assert "Action items:" not in sio.getvalue()
