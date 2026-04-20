"""Logo rendering helpers for tools/tui_render.py.

Extracted to keep tui_render.py under the 300-line ceiling. Exports
_build_logo and _build_simple_logo.
"""
from __future__ import annotations

import time
from typing import Any

from rich.text import Text


# Five 12-char rows representing a semicircular arch. Row 0 is the keystone
# zone (animates through ghost → floating → seated states); rows 1–4 are the
# arch walls and always present. See milestone doc §5 for the SVG mapping.

_ARCH_WALLS: list[tuple[str, str]] = [
    ("   \u258c    \u2590   ", "white"),    # row 1 crown — voussoir faces
    ("  \u2588\u2588    \u2588\u2588  ", "white"),  # row 2 mid-upper
    (" \u2588\u2588      \u2588\u2588 ", "white"),  # row 3 mid-lower
    ("\u2588\u2588        \u2588\u2588", "white"),  # row 4 base
]
_LOGO_FRAMES: list[tuple[str, str]] = [
    ("    \u2591\u2591\u2591\u2591    ", "dim cyan"),               # ghost
    ("    \u2588\u2588\u2588\u2588    ", "bold bright_cyan"),       # floating
    ("            ", ""),                                           # seated (row 0 empty)
]
_LOGO_FRAME2_CROWN = ("   \u258c\u2588\u2588\u2588\u2588\u2590   ", "bold white")
_LOGO_COMPLETE_ROW0 = ("            ", "")
_LOGO_COMPLETE_CROWN = ("   \u258c\u2588\u2588\u2588\u2588\u2590   ", "bold yellow")
_LOGO_COMPLETE_WALL_STYLE = "yellow"
_LOGO_IDLE_ROW0 = ("            ", "")
_LOGO_IDLE_CROWN = ("   \u258c\u2588\u2588\u2588\u2588\u2590   ", "dim white")
_LOGO_IDLE_WALL_STYLE = "dim white"

_SIMPLE_LOGO_LINES = [
    "     /\\     ",
    "    /  \\    ",
    "   / () \\   ",
    "  /______\\  ",
    " |        | ",
]


def _rows_to_text(rows: list[tuple[str, str]]) -> Text:
    text = Text()
    for i, (chars, style) in enumerate(rows):
        if i > 0:
            text.append("\n")
        if style:
            text.append(chars, style=style)
        else:
            text.append(chars)
    return text


def _build_simple_logo(status: dict[str, Any]) -> Text:
    style = "yellow" if status.get("complete") else "white"
    text = Text()
    for i, line in enumerate(_SIMPLE_LOGO_LINES):
        if i > 0:
            text.append("\n")
        text.append(line, style=style)
    return text


def _build_logo(status: dict[str, Any]) -> Text:
    if status.get("simple_logo"):
        return _build_simple_logo(status)
    if status.get("complete"):
        rows = [_LOGO_COMPLETE_ROW0, _LOGO_COMPLETE_CROWN,
                *[(c, _LOGO_COMPLETE_WALL_STYLE) for c, _ in _ARCH_WALLS[1:]]]
    elif (status.get("current_agent_status") or "idle") == "idle":
        rows = [_LOGO_IDLE_ROW0, _LOGO_IDLE_CROWN,
                *[(c, _LOGO_IDLE_WALL_STYLE) for c, _ in _ARCH_WALLS[1:]]]
    else:
        # "running" (agent) and "working" (shell op) both animate identically.
        frame = int(time.time() * 0.6) % 3
        crown = _LOGO_FRAME2_CROWN if frame == 2 else _ARCH_WALLS[0]
        rows = [_LOGO_FRAMES[frame], crown, *_ARCH_WALLS[1:]]
    return _rows_to_text(rows)
