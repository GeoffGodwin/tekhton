"""Shared utilities for tui_render and its companion modules.

Holds primitives that multiple render modules need so that companion files
(tui_render_timings, etc.) can import them without creating a cycle through
tui_render.
"""
from __future__ import annotations


# Braille spinner cycle used by active-bar, working-bar, and timings panel.
_SPIN_CHARS = "\u280b\u2819\u2839\u2838\u283c\u2834\u2826\u2827\u2807\u280f"


def _fmt_duration(secs: int) -> str:
    if secs <= 0:
        return "0s"
    hours, rem = divmod(int(secs), 3600)
    mins, s = divmod(rem, 60)
    if hours:
        return f"{hours}h{mins}m{s}s"
    if mins:
        return f"{mins}m{s}s"
    return f"{s}s"
