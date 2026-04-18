"""Tests for tools/tui.py — the rich.live sidecar renderer.

Verifies:
- status file parsing (valid, empty, malformed)
- layout construction does not raise on representative inputs
- graceful handling of partial / missing status keys
- _fmt_duration edge cases
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

# Skip the entire module if rich is not installed in the test venv.
rich = pytest.importorskip("rich")  # noqa: F841

TOOLS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS_DIR))

import tui  # noqa: E402


def _sample_status() -> dict:
    return {
        "version": 1,
        "run_id": "run_20260417_143000",
        "milestone": "97",
        "milestone_title": "TUI Mode",
        "task": "M97",
        "attempt": 1,
        "max_attempts": 5,
        "stage_num": 1,
        "stage_total": 4,
        "stage_label": "Coder",
        "agent_turns_used": 42,
        "agent_turns_max": 70,
        "agent_elapsed_secs": 1540,
        "agent_model": "claude-opus-4-7",
        "pipeline_elapsed_secs": 1820,
        "stages_complete": [
            {"label": "Intake", "model": "sonnet", "turns": "2/10", "time": "16s", "verdict": "PASS"},
        ],
        "current_agent_status": "running",
        "last_event": "Invoking coder...",
        "recent_events": [
            {"ts": "14:23:01", "level": "info", "msg": "[✓] Pre-flight: 3 passed"},
            {"ts": "14:23:05", "level": "success", "msg": "Scout finished"},
        ],
        "action_items": [],
        "verdict": None,
        "complete": False,
    }


def test_fmt_duration_zero():
    assert tui._fmt_duration(0) == "0s"


def test_fmt_duration_seconds():
    assert tui._fmt_duration(42) == "42s"


def test_fmt_duration_minutes():
    assert tui._fmt_duration(125) == "2m5s"


def test_fmt_duration_hours():
    assert tui._fmt_duration(3725) == "1h2m5s"


def test_read_status_missing(tmp_path: Path):
    assert tui._read_status(tmp_path / "nope.json") is None


def test_read_status_empty(tmp_path: Path):
    p = tmp_path / "s.json"
    p.write_text("")
    assert tui._read_status(p) is None


def test_read_status_malformed(tmp_path: Path):
    p = tmp_path / "s.json"
    p.write_text("{not json}")
    assert tui._read_status(p) is None


def test_read_status_roundtrip(tmp_path: Path):
    p = tmp_path / "s.json"
    p.write_text(json.dumps(_sample_status()))
    data = tui._read_status(p)
    assert data is not None
    assert data["milestone"] == "97"
    assert data["agent_turns_used"] == 42


def test_build_layout_full():
    layout = tui._build_layout(_sample_status(), event_lines=8)
    assert layout is not None
    # Render into a string to ensure it doesn't crash
    from rich.console import Console
    console = Console(file=open("/dev/null", "w"), width=100)
    console.print(layout)


def test_build_layout_empty_status():
    layout = tui._build_layout(tui._empty_status(), event_lines=8)
    assert layout is not None


def test_build_layout_missing_keys():
    # A status with only a few keys — should not raise.
    partial = {"stage_label": "Review", "agent_turns_used": 5}
    layout = tui._build_layout(partial, event_lines=8)
    assert layout is not None


def test_build_events_panel_with_levels():
    status = _sample_status()
    status["recent_events"] = [
        {"ts": "t1", "level": "info", "msg": "info msg"},
        {"ts": "t2", "level": "warn", "msg": "warn msg"},
        {"ts": "t3", "level": "error", "msg": "error msg"},
        {"ts": "t4", "level": "success", "msg": "success msg"},
    ]
    panel = tui._build_events_panel(status, max_lines=8)
    assert panel is not None


def test_build_stage_panel_idle():
    status = _sample_status()
    status["current_agent_status"] = "idle"
    panel = tui._build_stage_panel(status)
    assert panel is not None


def test_build_stage_panel_complete():
    status = _sample_status()
    status["current_agent_status"] = "complete"
    panel = tui._build_stage_panel(status)
    assert panel is not None


def test_build_pipeline_panel_with_failed_stage():
    status = _sample_status()
    status["stages_complete"] = [
        {"label": "Coder", "time": "5m", "verdict": "FAIL"},
    ]
    panel = tui._build_pipeline_panel(status)
    assert panel is not None
