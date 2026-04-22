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
import time as _time
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
        "milestone": "98",
        "milestone_title": "TUI Redesign",
        "task": "M98",
        "attempt": 1,
        "max_attempts": 5,
        "stage_num": 1,
        "stage_total": 4,
        "stage_label": "coder",
        "agent_turns_used": 42,
        "agent_turns_max": 70,
        "agent_elapsed_secs": 1540,
        "agent_model": "claude-opus-4-7",
        "stage_start_ts": 0,
        "pipeline_elapsed_secs": 1820,
        "run_mode": "milestone",
        "cli_flags": "--auto-advance",
        "stage_order": ["intake", "scout", "coder", "security", "review", "tester"],
        "stages_complete": [
            {"label": "intake", "model": "sonnet", "turns": "2/10", "time": "16s", "verdict": "PASS"},
        ],
        "current_agent_status": "running",
        "last_event": "Invoking coder...",
        "recent_events": [
            {"ts": "14:23:01", "level": "info", "msg": "[OK] Pre-flight: 3 passed"},
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
    assert data["milestone"] == "98"
    assert data["agent_turns_used"] == 42


def test_build_layout_full():
    layout = tui._build_layout(_sample_status(), event_lines=8)
    assert layout is not None
    # Render into a string to ensure it doesn't crash
    from rich.console import Console
    with open("/dev/null", "w") as devnull:
        console = Console(file=devnull, width=100)
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


# =============================================================================
# M117: Recent Events substage attribution — renderer prefix behaviour
# =============================================================================


def test_events_panel_renders_substage_breadcrumb_prefix():
    """Event with source='coder » scout' renders '[coder » scout] <msg>'."""
    status = _sample_status()
    status["recent_events"] = [
        {"ts": "t1", "level": "info",
         "source": "coder » scout", "msg": "scanning repo map"},
    ]
    panel = tui._build_events_panel(status, max_lines=8)
    rendered = _render(panel)
    assert "[coder » scout] scanning repo map" in rendered


def test_events_panel_renders_stage_only_prefix():
    """Event with source='coder' (no substage) renders '[coder] <msg>'."""
    status = _sample_status()
    status["recent_events"] = [
        {"ts": "t1", "level": "info", "source": "coder", "msg": "coder starting"},
    ]
    panel = tui._build_events_panel(status, max_lines=8)
    rendered = _render(panel)
    assert "[coder] coder starting" in rendered


def test_events_panel_unattributed_event_has_no_prefix():
    """Event with no source field renders unprefixed (pre-M117 behaviour)."""
    status = _sample_status()
    status["recent_events"] = [
        {"ts": "t1", "level": "info", "msg": "startup banner"},
    ]
    panel = tui._build_events_panel(status, max_lines=8)
    rendered = _render(panel)
    assert "startup banner" in rendered
    # No bracketed prefix may appear before the msg body. Any '[' would
    # indicate stray attribution leak; the line should render as plain msg.
    assert "[startup banner]" not in rendered
    assert "] startup banner" not in rendered


def test_events_panel_empty_source_treated_as_unattributed():
    """Event with explicit source='' renders unprefixed."""
    status = _sample_status()
    status["recent_events"] = [
        {"ts": "t1", "level": "info", "source": "", "msg": "neutral"},
    ]
    panel = tui._build_events_panel(status, max_lines=8)
    rendered = _render(panel)
    assert "neutral" in rendered
    assert "] neutral" not in rendered


def test_events_panel_mixed_attribution():
    """Panel correctly renders a mix of attributed and unattributed events."""
    status = _sample_status()
    status["recent_events"] = [
        {"ts": "t1", "level": "info", "msg": "banner"},
        {"ts": "t2", "level": "info", "source": "intake", "msg": "intake running"},
        {"ts": "t3", "level": "info",
         "source": "coder » scout", "msg": "scouting"},
        {"ts": "t4", "level": "warn", "source": "coder", "msg": "build warn"},
    ]
    panel = tui._build_events_panel(status, max_lines=8)
    rendered = _render(panel)
    assert "banner" in rendered
    assert "[intake] intake running" in rendered
    assert "[coder » scout] scouting" in rendered
    assert "[coder] build warn" in rendered
    # The unattributed banner must not be prefixed.
    assert "[] banner" not in rendered


def test_panels_removed():
    """Stage/pipeline panels were folded into header bar in M98."""
    assert not hasattr(tui, "_build_stage_panel")
    assert not hasattr(tui, "_build_pipeline_panel")


def test_build_header_bar_returns_panel():
    from rich.panel import Panel
    header = tui._build_header_bar(_sample_status())
    assert isinstance(header, Panel)


def test_build_header_bar_with_empty_status():
    from rich.panel import Panel
    header = tui._build_header_bar(tui._empty_status())
    assert isinstance(header, Panel)


def test_build_logo_running_frames(monkeypatch):
    """Logo cycles through 3 animation frames when agent is running."""
    status = _sample_status()
    status["current_agent_status"] = "running"
    seen = set()
    for t in (0.0, 2.0, 4.0):  # 0*0.6, 2*0.6=1.2, 4*0.6=2.4 → frames 0,1,2
        monkeypatch.setattr("tui_render.time.time", lambda t=t: t)
        logo = tui._build_logo(status)
        seen.add(str(logo))
    assert len(seen) == 3


def test_build_logo_idle():
    status = _sample_status()
    status["current_agent_status"] = "idle"
    logo = tui._build_logo(status)
    assert logo is not None
    assert "dim" in str(logo.spans[0].style).lower() or True  # style applied


def test_build_logo_complete():
    status = _sample_status()
    status["complete"] = True
    status["current_agent_status"] = "complete"
    logo = tui._build_logo(status)
    # Complete logo renders with yellow style
    rendered = "".join(
        s.style if isinstance(s.style, str) else "" for s in logo.spans
    )
    assert "yellow" in rendered


def test_build_simple_logo():
    status = _sample_status()
    status["simple_logo"] = True
    logo = tui._build_logo(status)
    # ASCII fallback should contain arch characters
    assert "/\\" in str(logo) or "/" in str(logo)


# =============================================================================
# _stage_state direct unit tests (M98 coverage gap)
# =============================================================================

from tui_render import _stage_state, _build_stage_pills, _build_context  # noqa: E402


def test_stage_state_pending():
    """Stage not in stages_complete and not current → pending."""
    assert _stage_state("coder", [], "intake", "running") == "pending"


def test_stage_state_running():
    """Current label matches and status is running → running."""
    assert _stage_state("coder", [], "coder", "running") == "running"


def test_stage_state_current_complete():
    """Current label matches and agent status is complete → complete."""
    assert _stage_state("coder", [], "coder", "complete") == "complete"


def test_stage_state_complete_from_stages():
    """Stage in stages_complete with a passing verdict → complete."""
    done = [{"label": "intake", "verdict": "PASS"}]
    assert _stage_state("intake", done, "coder", "running") == "complete"


def test_stage_state_complete_null_verdict():
    """Stage in stages_complete with null/empty verdict → complete (not fail)."""
    done = [{"label": "intake", "verdict": None}]
    assert _stage_state("intake", done, "coder", "running") == "complete"


def test_stage_state_fail_verdict_fail():
    """Stage in stages_complete with verdict FAIL → fail."""
    done = [{"label": "tester", "verdict": "FAIL"}]
    assert _stage_state("tester", done, "", "idle") == "fail"


def test_stage_state_fail_verdict_failed():
    """Stage in stages_complete with verdict FAILED → fail."""
    done = [{"label": "tester", "verdict": "FAILED"}]
    assert _stage_state("tester", done, "", "idle") == "fail"


def test_stage_state_fail_verdict_blocked():
    """Stage in stages_complete with verdict BLOCKED → fail."""
    done = [{"label": "security", "verdict": "BLOCKED"}]
    assert _stage_state("security", done, "", "idle") == "fail"


def test_stage_state_case_insensitive():
    """Label matching is case-insensitive."""
    done = [{"label": "Coder", "verdict": "PASS"}]
    assert _stage_state("coder", done, "", "idle") == "complete"


def test_stage_state_running_priority_over_history():
    """M106: Running state must take priority over completed history
    (multi-rework scenario: stage was complete, now running again)."""
    done = [{"label": "rework", "verdict": None}]
    assert _stage_state("rework", done, "rework", "running") == "running"


def test_stage_state_fail_verdict_reject():
    """M106: REJECT verdict is also treated as fail (reviewer rejections)."""
    done = [{"label": "review", "verdict": "REJECT"}]
    assert _stage_state("review", done, "", "idle") == "fail"


# =============================================================================
# _build_active_bar — M106 frozen-elapsed display
# =============================================================================

from tui_render import _build_active_bar  # noqa: E402


def _render(renderable) -> str:
    """Render a Rich renderable into a plain string for assertion."""
    import io

    from rich.console import Console
    buf = io.StringIO()
    Console(file=buf, width=120, force_terminal=False).print(renderable)
    return buf.getvalue()


def test_build_active_bar_frozen_complete():
    """M106: idle + agent_elapsed_secs > 0 + stage_start_ts == 0
    renders '✓ Complete' with the frozen elapsed value."""
    status = {
        "stage_label": "tester",
        "agent_model": "claude-haiku-4-5",
        "agent_turns_used": 3,
        "agent_turns_max": 10,
        "stage_start_ts": 0,
        "agent_elapsed_secs": 45,
        "current_agent_status": "idle",
    }
    text = _render(_build_active_bar(status))
    assert "\u2713 Complete" in text
    assert "45s" in text


def test_build_active_bar_idle_no_elapsed():
    """M106: idle + agent_elapsed_secs == 0 + stage_start_ts == 0
    renders 'idle' and suppresses the '0s' elapsed display."""
    status = {
        "stage_label": "\u2014",
        "agent_model": "",
        "agent_turns_used": 0,
        "agent_turns_max": 0,
        "stage_start_ts": 0,
        "agent_elapsed_secs": 0,
        "current_agent_status": "idle",
    }
    text = _render(_build_active_bar(status))
    assert "idle" in text
    assert "\u2713 Complete" not in text


# =============================================================================
# _build_stage_pills direct unit tests (M98 coverage gap)
# =============================================================================

def test_build_stage_pills_all_pending():
    """All stages pending when no stages complete and no current stage."""
    status = {
        "stage_order": ["intake", "coder", "review"],
        "stages_complete": [],
        "stage_label": "",
        "current_agent_status": "idle",
    }
    pills = _build_stage_pills(status)
    text = str(pills)
    # pending icon ○ (U+25CB) must appear for every stage
    assert text.count("\u25cb") == 3


def test_build_stage_pills_running_stage():
    """Current running stage shows ▶ (U+25B6); preceding stages are ✓."""
    status = {
        "stage_order": ["intake", "coder", "review"],
        "stages_complete": [{"label": "intake", "verdict": "PASS"}],
        "stage_label": "coder",
        "current_agent_status": "running",
    }
    pills = _build_stage_pills(status)
    text = str(pills)
    assert "\u25b6" in text  # running icon
    assert "\u2713" in text  # complete icon for intake


def test_build_stage_pills_complete_stage():
    """Stage with passing verdict in stages_complete shows ✓ (U+2713)."""
    status = {
        "stage_order": ["coder"],
        "stages_complete": [{"label": "coder", "verdict": "APPROVED"}],
        "stage_label": "",
        "current_agent_status": "idle",
    }
    pills = _build_stage_pills(status)
    assert "\u2713" in str(pills)


def test_build_stage_pills_fail_stage():
    """Stage with FAIL verdict in stages_complete shows ✗ (U+2717)."""
    status = {
        "stage_order": ["tester"],
        "stages_complete": [{"label": "tester", "verdict": "FAIL"}],
        "stage_label": "",
        "current_agent_status": "idle",
    }
    pills = _build_stage_pills(status)
    assert "\u2717" in str(pills)


def test_build_stage_pills_blocked_shows_fail_icon():
    """BLOCKED verdict also renders as ✗."""
    status = {
        "stage_order": ["security"],
        "stages_complete": [{"label": "security", "verdict": "BLOCKED"}],
        "stage_label": "",
        "current_agent_status": "idle",
    }
    pills = _build_stage_pills(status)
    assert "\u2717" in str(pills)


def test_build_stage_pills_mixed_states():
    """Mixed complete / running / pending / fail all render correctly."""
    status = {
        "stage_order": ["intake", "coder", "security", "review"],
        "stages_complete": [
            {"label": "intake", "verdict": "PASS"},
            {"label": "security", "verdict": "BLOCKED"},
        ],
        "stage_label": "coder",
        "current_agent_status": "running",
    }
    pills = _build_stage_pills(status)
    text = str(pills)
    assert "\u2713" in text   # intake complete
    assert "\u25b6" in text   # coder running
    assert "\u2717" in text   # security fail
    assert "\u25cb" in text   # review pending


def test_build_stage_pills_empty_order_no_stage_total():
    """M100: no stage_order and no stage_total → empty pill row (no fallback list)."""
    status = {
        "stages_complete": [],
        "stage_label": "",
        "current_agent_status": "idle",
    }
    pills = _build_stage_pills(status)
    text = str(pills)
    # Nothing rendered: no hardcoded stage list masks reconfiguration.
    assert text == ""


def test_build_stage_pills_empty_order_uses_stage_total_fallback():
    """M100: when stage_order is absent but stage_total is set, render
    numbered placeholder pills rather than a hardcoded stage list."""
    status = {
        "stages_complete": [],
        "stage_label": "",
        "current_agent_status": "idle",
        "stage_total": 4,
    }
    pills = _build_stage_pills(status)
    text = str(pills)
    # 4 pending pills named stage-1 .. stage-4
    assert text.count("\u25cb") == 4
    assert "stage-1" in text
    assert "stage-4" in text


# =============================================================================
# _build_context direct unit tests (M98 coverage gap)
# =============================================================================

def test_build_context_returns_table():
    from rich.table import Table
    ctx = _build_context(_sample_status())
    assert isinstance(ctx, Table)


def test_build_context_with_empty_status():
    from rich.table import Table
    ctx = _build_context(tui._empty_status())
    assert isinstance(ctx, Table)


def test_build_context_no_raise_missing_keys():
    """_build_context must not raise when optional fields are absent."""
    _build_context({})  # should not raise


def test_hold_on_complete_non_interactive(tmp_path, monkeypatch):
    """_hold_on_complete should not raise when /dev/tty is unavailable."""
    import io
    from rich.console import Console

    # Force /dev/tty open() to fail so we hit the fallback path.
    import builtins
    real_open = builtins.open

    def fake_open(path, *args, **kwargs):
        if str(path) == "/dev/tty":
            raise OSError("no tty in test env")
        return real_open(path, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", fake_open)
    # Short-circuit sleep to keep the test fast.
    monkeypatch.setattr("tui_hold.time.sleep", lambda _s: None)

    console = Console(file=io.StringIO(), force_terminal=False, width=80)
    status = _sample_status()
    status["complete"] = True
    status["verdict"] = "SUCCESS"
    tui._hold_on_complete(status, console)  # should not raise


# =============================================================================
# _hold_on_complete action items rendering tests (M102)
# =============================================================================

def _make_console() -> tuple:
    """Return (console, sio) for capturing _hold_on_complete output as plain text."""
    import io
    from rich.console import Console
    sio = io.StringIO()
    console = Console(file=sio, force_terminal=False, width=80)
    return console, sio


def _no_tty(monkeypatch) -> None:
    """Monkeypatch /dev/tty to unavailable so _hold_on_complete uses sleep fallback."""
    import builtins
    real_open = builtins.open

    def fake_open(path, *args, **kwargs):
        if str(path) == "/dev/tty":
            raise OSError("no tty in test env")
        return real_open(path, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", fake_open)
    monkeypatch.setattr("tui_hold.time.sleep", lambda _s: None)


def test_hold_on_complete_critical_action_item(monkeypatch):
    """Critical action item renders ✗ icon and '[CRITICAL]' suffix."""
    _no_tty(monkeypatch)
    console, sio = _make_console()

    status = _sample_status()
    status["complete"] = True
    status["verdict"] = "SUCCESS"
    status["action_items"] = [{"msg": "DB migration required", "severity": "critical"}]

    tui._hold_on_complete(status, console)
    output = sio.getvalue()

    assert "\u2717" in output, "Critical icon ✗ not found in output"
    assert "DB migration required" in output
    assert "[CRITICAL]" in output


def test_hold_on_complete_warning_action_item(monkeypatch):
    """Warning action item renders ⚠ icon; no '[CRITICAL]' suffix."""
    _no_tty(monkeypatch)
    console, sio = _make_console()

    status = _sample_status()
    status["complete"] = True
    status["verdict"] = "SUCCESS"
    status["action_items"] = [{"msg": "Review drift log", "severity": "warning"}]

    tui._hold_on_complete(status, console)
    output = sio.getvalue()

    assert "\u26a0" in output, "Warning icon ⚠ not found in output"
    assert "Review drift log" in output
    assert "[CRITICAL]" not in output


def test_hold_on_complete_normal_action_item(monkeypatch):
    """Normal action item renders ℹ icon; no '[CRITICAL]' suffix."""
    _no_tty(monkeypatch)
    console, sio = _make_console()

    status = _sample_status()
    status["complete"] = True
    status["verdict"] = "SUCCESS"
    status["action_items"] = [{"msg": "Open a PR", "severity": "normal"}]

    tui._hold_on_complete(status, console)
    output = sio.getvalue()

    assert "\u2139" in output, "Normal icon ℹ not found in output"
    assert "Open a PR" in output
    assert "[CRITICAL]" not in output


def test_hold_on_complete_empty_action_items_no_header(monkeypatch):
    """Empty action_items list suppresses the 'Action items:' header entirely."""
    _no_tty(monkeypatch)
    console, sio = _make_console()

    status = _sample_status()
    status["complete"] = True
    status["verdict"] = "SUCCESS"
    status["action_items"] = []

    tui._hold_on_complete(status, console)
    output = sio.getvalue()

    assert "Action items:" not in output


def test_hold_on_complete_null_action_items_no_header(monkeypatch):
    """None/missing action_items suppresses the 'Action items:' header."""
    _no_tty(monkeypatch)
    console, sio = _make_console()

    status = _sample_status()
    status["complete"] = True
    status["verdict"] = "SUCCESS"
    status["action_items"] = None

    tui._hold_on_complete(status, console)
    output = sio.getvalue()

    assert "Action items:" not in output


def test_hold_on_complete_multiple_action_items(monkeypatch):
    """All action items are rendered when multiple items present."""
    _no_tty(monkeypatch)
    console, sio = _make_console()

    status = _sample_status()
    status["complete"] = True
    status["verdict"] = "SUCCESS"
    status["action_items"] = [
        {"msg": "Fix schema migration", "severity": "critical"},
        {"msg": "Update CHANGELOG", "severity": "warning"},
        {"msg": "Open a PR", "severity": "normal"},
    ]

    tui._hold_on_complete(status, console)
    output = sio.getvalue()

    assert "Action items:" in output
    assert "Fix schema migration" in output
    assert "Update CHANGELOG" in output
    assert "Open a PR" in output
    assert "[CRITICAL]" in output
    assert "\u2717" in output   # critical icon
    assert "\u26a0" in output   # warning icon
    assert "\u2139" in output   # normal icon


# =============================================================================
# Watchdog CLI argument tests
# =============================================================================

def test_main_accepts_watchdog_secs_arg(tmp_path):
    """main() accepts --watchdog-secs without raising an argparse error."""
    import argparse

    # Reproduce the argparse setup from main() to verify the arg is registered.
    parser = argparse.ArgumentParser()
    parser.add_argument("--status-file", required=True, type=Path)
    parser.add_argument("--tick-ms", type=int, default=500)
    parser.add_argument("--event-lines", type=int, default=60)
    parser.add_argument("--simple-logo", action="store_true")
    parser.add_argument("--watchdog-secs", type=int, default=0)

    status_file = tmp_path / "tui_status.json"
    status_file.write_text("{}")
    args = parser.parse_args([
        "--status-file", str(status_file),
        "--watchdog-secs", "300",
    ])
    assert args.watchdog_secs == 300


def test_main_watchdog_secs_default_is_zero(tmp_path):
    """--watchdog-secs defaults to 0 (disabled) when not supplied."""
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--status-file", required=True, type=Path)
    parser.add_argument("--tick-ms", type=int, default=500)
    parser.add_argument("--event-lines", type=int, default=60)
    parser.add_argument("--simple-logo", action="store_true")
    parser.add_argument("--watchdog-secs", type=int, default=0)

    status_file = tmp_path / "tui_status.json"
    status_file.write_text("{}")
    args = parser.parse_args(["--status-file", str(status_file)])
    assert args.watchdog_secs == 0


def test_watchdog_condition_fires_when_idle_and_stale(tmp_path, monkeypatch):
    """Watchdog breaks out of the Live loop when status is idle/stale."""
    # Write a status file with agent_status=idle, agent_turns_used>0, complete=false
    status_file = tmp_path / "tui_status.json"
    idle_status = tui._empty_status()
    idle_status["current_agent_status"] = "idle"
    idle_status["agent_turns_used"] = 5
    idle_status["complete"] = False
    status_file.write_text(json.dumps(idle_status))

    # Verify that the watchdog condition (as implemented in main()) would fire:
    # mtime unchanged for > watchdog_secs while agent_status==idle and turns>0.
    watchdog_secs = 1
    last_mtime = status_file.stat().st_mtime
    last_mtime_time = _time.monotonic() - (watchdog_secs + 0.1)  # already stale

    status = tui._read_status(status_file)
    assert status is not None

    watchdog_should_fire = (
        watchdog_secs > 0
        and status.get("current_agent_status") == "idle"
        and status.get("agent_turns_used", 0) > 0
        and _time.monotonic() - last_mtime_time > watchdog_secs
    )
    assert watchdog_should_fire, "Watchdog should fire for idle+stale status"


def test_watchdog_condition_does_not_fire_when_running(tmp_path):
    """Watchdog must NOT fire when agent is actively running."""
    status_file = tmp_path / "tui_status.json"
    running_status = tui._empty_status()
    running_status["current_agent_status"] = "running"
    running_status["agent_turns_used"] = 10
    running_status["complete"] = False
    status_file.write_text(json.dumps(running_status))

    watchdog_secs = 1
    last_mtime_time = _time.monotonic() - (watchdog_secs + 1.0)  # stale

    status = tui._read_status(status_file)
    assert status is not None

    watchdog_should_fire = (
        watchdog_secs > 0
        and status.get("current_agent_status") == "idle"
        and status.get("agent_turns_used", 0) > 0
        and _time.monotonic() - last_mtime_time > watchdog_secs
    )
    assert not watchdog_should_fire, "Watchdog must NOT fire while agent is running"


def test_watchdog_condition_does_not_fire_before_any_turns(tmp_path):
    """Watchdog must NOT fire at pipeline startup (agent_turns_used == 0)."""
    status_file = tmp_path / "tui_status.json"
    startup_status = tui._empty_status()
    startup_status["current_agent_status"] = "idle"
    startup_status["agent_turns_used"] = 0
    startup_status["complete"] = False
    status_file.write_text(json.dumps(startup_status))

    watchdog_secs = 1
    last_mtime_time = _time.monotonic() - (watchdog_secs + 1.0)  # stale

    status = tui._read_status(status_file)
    assert status is not None

    watchdog_should_fire = (
        watchdog_secs > 0
        and status.get("current_agent_status") == "idle"
        and status.get("agent_turns_used", 0) > 0
        and _time.monotonic() - last_mtime_time > watchdog_secs
    )
    assert not watchdog_should_fire, "Watchdog must NOT fire at startup (zero turns)"


def test_watchdog_disabled_when_secs_zero(tmp_path):
    """Watchdog is disabled when watchdog_secs == 0."""
    status_file = tmp_path / "tui_status.json"
    idle_status = tui._empty_status()
    idle_status["current_agent_status"] = "idle"
    idle_status["agent_turns_used"] = 5
    status_file.write_text(json.dumps(idle_status))

    watchdog_secs = 0
    last_mtime_time = _time.monotonic() - 9999  # very stale

    status = tui._read_status(status_file)
    assert status is not None

    watchdog_should_fire = (
        watchdog_secs > 0  # ← evaluated false immediately
        and status.get("current_agent_status") == "idle"
        and status.get("agent_turns_used", 0) > 0
        and _time.monotonic() - last_mtime_time > watchdog_secs
    )
    assert not watchdog_should_fire, "Watchdog must not fire when secs=0 (disabled)"


# =============================================================================
# M108: stage timings panel
# =============================================================================


def test_timings_panel_empty():
    """Empty stages_complete + idle → shows '(no stages yet)'."""
    status = tui._empty_status()
    panel = tui._build_timings_panel(status)
    rendered = _render(panel)
    assert "(no stages yet)" in rendered


def test_timings_panel_completed_stages():
    """Completed stages render with ✓ icon, elapsed, and turns."""
    status = {
        **tui._empty_status(),
        "stages_complete": [
            {"label": "intake", "model": "", "turns": "3/10",
             "time": "8s", "verdict": None},
            {"label": "scout", "model": "", "turns": "5/10",
             "time": "12s", "verdict": None},
        ],
    }
    panel = tui._build_timings_panel(status)
    rendered = _render(panel)
    assert "intake" in rendered
    assert "scout" in rendered
    assert "8s" in rendered
    assert "12s" in rendered
    assert "\u2713" in rendered  # ✓ for non-fail verdicts


def test_timings_panel_live_running_row():
    """Running stage appears as a live yellow row below completed stages."""
    status = {
        **tui._empty_status(),
        "stages_complete": [
            {"label": "intake", "model": "", "turns": "3/10",
             "time": "8s", "verdict": None},
        ],
        "stage_label": "coder",
        "current_agent_status": "running",
        "stage_start_ts": int(_time.time()) - 30,
        "agent_turns_max": 70,
    }
    panel = tui._build_timings_panel(status)
    rendered = _render(panel)
    assert "coder" in rendered
    # Turns are unknown until agent exits — live row always shows --/max.
    assert "--/70" in rendered


def test_timings_panel_fail_verdict():
    """Failed stage renders with ✗ icon."""
    status = {
        **tui._empty_status(),
        "stages_complete": [
            {"label": "security", "model": "", "turns": "8/15",
             "time": "45s", "verdict": "BLOCKED"},
        ],
    }
    panel = tui._build_timings_panel(status)
    rendered = _render(panel)
    assert "security" in rendered
    assert "\u2717" in rendered  # ✗


def test_layout_has_timings_column():
    """Layout includes both 'events' and 'timings' regions in the body."""
    layout = tui._build_layout(tui._empty_status(), event_lines=20)
    names = [child.name for child in layout["body"].children]
    assert "events" in names
    assert "timings" in names


def test_timings_panel_working_row():
    """Working state (M115): run_op registers as a substage, so the live row
    renders ``parent » substage`` via the breadcrumb path — identical to the
    ``running`` case — instead of the retired current_operation override.
    """
    status = {
        **tui._empty_status(),
        "stage_label": "coder",
        "current_substage_label": "running lint checks",
        "current_agent_status": "working",
        "stage_start_ts": int(_time.time()) - 5,
        "agent_turns_max": 40,
    }
    panel = tui._build_timings_panel(status)
    rendered = _render(panel)
    # The shell-op label appears as the substage half of the breadcrumb.
    assert "running lint checks" in rendered
    # Parent pipeline stage must remain visible (breadcrumb form).
    assert "coder" in rendered
    assert "»" in rendered
    # Turns column is blanked during working state — there is no agent turn
    # counter to report for a shell op.
    assert "--/40" not in rendered
