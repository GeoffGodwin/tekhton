# Milestone 98: TUI Redesign — Layout, Run Context, Logo Animation & Completion Hold
<!-- milestone-meta
id: "98"
status: "done"
-->

## Overview

M97 shipped a working TUI sidecar but with a layout that misallocates screen
real estate: two symmetric 40%-wide panels (Current Stage / Pipeline) display
~10 nearly-static lines while the Recent Events panel — the highest-signal
zone during a live run — is confined to a tiny fixed strip at the bottom. The
spinner in `lib/agent.sh` also writes directly to `/dev/tty` in a way that
bleeds through the rich alternate-screen buffer when spawned from child
processes (e.g. `tests/run_tests.sh → test_agent_fifo_invocation.sh`), causing
flickering text overlaid on the TUI border.

This milestone fixes the spinner bleed, completely redesigns the layout to
prioritise the event feed, adds a run-context header (how was Tekhton called,
what mode, what task, which milestone), ships an animated arch logo in the
header, and changes the sidecar lifecycle so the screen holds at completion
rather than vanishing — letting the user read the full event history before
the finalize banner prints.

## Design

### §1 — Spinner Bleed Fix (bug fix, prerequisite)

**Root cause.** `_TUI_ACTIVE` is a bash global set in the parent shell but not
exported. Child processes launched with `bash child.sh` (not `source`) start
with an empty environment, so `_TUI_ACTIVE` is unset and evaluates to `false`
in the guard added in M97.5. The test runner calls:

```
tekhton (TUI active) → bash tests/run_tests.sh → bash test_agent_fifo_invocation.sh
                                                        └─ run_agent "TestTimeout" ...
                                                              └─ spinner: ${_TUI_ACTIVE:-false} = "false"
                                                                          ↳ writes to /dev/tty  ← flicker
```

**Fix.** In `lib/tui.sh`, change `_TUI_ACTIVE=false` (line ~20) and all
assignments to use `export _TUI_ACTIVE`. Because the variable name begins with
`_`, it propagates through `bash child.sh` invocations and is visible inside
`run_agent`'s spinner subshell. No child file sources `lib/tui.sh`, so nothing
resets it.

`lib/plan_batch.sh` has a second unguarded spinner (the "Generating..." spinner
used during planning batch runs). Add the same guard there:

```bash
# lib/plan_batch.sh ~line 43 — inside the spinner subshell
if [[ "${_TUI_ACTIVE:-false}" != "true" ]]; then
    printf '\r\033[0;36m[tekhton]\033[0m %s Generating... %dm%02ds ' \
        "${chars:i%${#chars}:1}" "$mins" "$secs" > /dev/tty
fi
```

**Files:** `lib/tui.sh` (export), `lib/plan_batch.sh` (guard).

---

### §2 — New Layout: Events-First Three-Zone Design

Replace the current four-panel layout (header / stage+pipeline / events) with
a three-zone layout that gives the event feed all remaining screen height.

**Target layout (80-column terminal, ~30-line illustration):**

```
╭─────────────────────────────────────────────────────────────── 14:32:15 ──╮
│  ▄▄▄▄   ▄▄▄▄   ▄███▄   ▄▄▄▄   TEKHTON   M97 — TUI redesign…             │
│  ████   ████   ████    ████    milestone · Pass 2/3 · --complete          │
│  ████   ████             ████  Task: "Fix spinner guard and redesign TUI  │
│  ████   ████   ████    ████    layout for better real-time observability"  │
│  ✓ intake  ✓ scout  ▶ coder  ○ security  ○ review  ○ tester               │
│  Coder · claude-opus-4-7 · ████████░░ 14/35 turns · 3m12s · ⠏ Running   │
╰────────────────────────────────────────────────────────────────────────────╯
╭─ Recent events ────────────────────────────────────────────────────────────╮
│  14:32:01  [coder]   Edited lib/agent.sh — spinner guard (TUI_ACTIVE)     │
│  14:31:58  [gate]    shellcheck: 0 errors — build gate passed              │
│  14:31:50  [prerun]  tests: 47 passed, 0 failed — baseline clean           │
│  14:31:45  [scout]   3 files flagged as primary targets                    │
│  14:32:01  [coder]   Previous event that slid off top remains scrollable  │
│  ...  (fills ALL remaining terminal height — ratio=1)  ...                │
╰────────────────────────────────────────────────────────────────────────────╯
```

**Zone breakdown:**

| Zone | `rich.Layout` size | Content |
|------|--------------------|---------| 
| `header` | `size=8` | Logo (left) + run context (right) + stage pills row + active-stage bar |
| `events` | `ratio=1` | Full-height scrolling event feed; fills whatever is left |

The `middle` split (stage panel / pipeline panel) is eliminated entirely.

**`_build_layout()` becomes:**

```python
layout = Layout()
layout.split_column(
    Layout(name="header", size=8),
    Layout(name="events", ratio=1),
)
layout["header"].update(_build_header_bar(status))
layout["events"].update(_build_events_panel(status))
```

`_build_stage_panel()` and `_build_pipeline_panel()` are deleted.

---

### §3 — Run Context in the Header

The header (`size=8`) is one `Panel` containing a `Table.grid` with two
columns: logo (left, 14 chars wide) and context (right, fills remaining width).

**Context column rows (in order):**

1. `TEKHTON  M{milestone} — {milestone_title}` (bold cyan / white)
2. `{run_mode}  ·  Pass {attempt}/{max_attempts}  ·  {cli_flags}` (dim)
3. `Task: "{task truncated to 60 chars…}"` (white)
4. *(blank spacer)*
5. Stage pills: `✓ intake  ✓ scout  ▶ coder  ○ security  ○ review  ○ tester`
6. Active-stage bar: `{label} · {model_short} · [progress bar] {turns_used}/{turns_max} turns · {elapsed} · {spinner}`

**`run_mode` derivation** — emitted by shell, not Python:

| Mode booleans (shell) | `run_mode` string |
|----------------------|-------------------|
| `MILESTONE_MODE=true` | `milestone` |
| `FIX_NONBLOCKERS_MODE=true` | `fix-nb` |
| `FIX_DRIFT_MODE=true` | `fix-drift` |
| `COMPLETE_MODE=true` (no milestone) | `complete` |
| *(none)* | `task` |

**`cli_flags` string** — non-default flags only, space-separated:
`--auto-advance`, `--skip-audit`, `--skip-security`, `--skip-docs`,
`--start-at STAGE`, `--human`, `--no-commit`. Built by `tui_set_context` at
startup and stored in `_TUI_CLI_FLAGS`.

**`stage_order` array** — ordered list of stage labels, set once at
`tui_set_context` call. Each stage has a state: `pending | running | complete |
fail`. Python derives state from `stages_complete` (done labels) +
`stage_label` (current) + remaining as `pending`. Stage pill icons:

| State | Icon | Style |
|-------|------|-------|
| `pending` | `○` | dim |
| `running` | `▶` | yellow bold |
| `complete` | `✓` | green |
| `fail` | `✗` | red |

**`model_short`** — strip `claude-` prefix and `-` separators:
`claude-opus-4-7` → `opus-4-7`.

---

### §4 — Shell Changes for Context

#### New function: `tui_set_context RUN_MODE FLAGS_STRING STAGE_ORDER_LIST`

Added to `lib/tui.sh`. Called from `tekhton.sh` just before `tui_start`:

```bash
# tekhton.sh — derive run_mode
_tui_run_mode="task"
[[ "$MILESTONE_MODE"         = true ]] && _tui_run_mode="milestone"
[[ "$FIX_NONBLOCKERS_MODE"   = true ]] && _tui_run_mode="fix-nb"
[[ "$FIX_DRIFT_MODE"         = true ]] && _tui_run_mode="fix-drift"
[[ "$COMPLETE_MODE"          = true ]] && [[ "$MILESTONE_MODE" != true ]] \
    && _tui_run_mode="complete"

# derive cli_flags
_tui_cli_flags=""
[[ "$AUTO_ADVANCE"       = true ]] && _tui_cli_flags+=" --auto-advance"
[[ "$SKIP_AUDIT"         = true ]] && _tui_cli_flags+=" --skip-audit"
[[ "$SKIP_SECURITY"      = true ]] && _tui_cli_flags+=" --skip-security"
[[ "$SKIP_DOCS"          = true ]] && _tui_cli_flags+=" --skip-docs"
[[ "${HUMAN_MODE:-false}" = true ]] && _tui_cli_flags+=" --human"
[[ "${AUTO_COMMIT:-true}" = false ]] && _tui_cli_flags+=" --no-commit"
[[ "${START_AT:-coder}"  != coder ]] && _tui_cli_flags+=" --start-at ${START_AT}"
_tui_cli_flags="${_tui_cli_flags# }"  # strip leading space

if declare -f tui_set_context &>/dev/null; then
    tui_set_context "$_tui_run_mode" "$_tui_cli_flags" \
        "intake" "scout" "coder" "security" "review" "tester"
fi
```

`tui_set_context` sets new globals:
- `_TUI_RUN_MODE="$1"`
- `_TUI_CLI_FLAGS="$2"`
- `_TUI_STAGE_ORDER=("${@:3}")` — bash array of stage labels in pipeline order

These are emitted in the status JSON by `_tui_json_build_status`.

#### New JSON fields added to `tui_helpers.sh`:

```json
"run_mode": "milestone",
"cli_flags": "--auto-advance",
"stage_order": ["intake","scout","coder","security","review","tester"]
```

`_tui_json_build_status` gains:
```bash
local run_mode="${_TUI_RUN_MODE:-task}"
local cli_flags="${_TUI_CLI_FLAGS:-}"
# stage_order array → JSON array of strings
```

#### `TUI_EVENT_LINES` meaning shift

The config key previously controlled both the in-shell ring-buffer depth AND
the panel display height. Now that the events panel is `ratio=1` (terminal
height driven), `TUI_EVENT_LINES` controls only the ring-buffer depth.

Default: `8 → 60`. Update `lib/config_defaults.sh`:

```bash
: "${TUI_EVENT_LINES:=60}"   # ring-buffer depth; display height is terminal-driven
```

Also update `CLAUDE.md` variable reference table.

---

### §5 — Arch Logo Animation

A 5-row × 12-character Unicode block art animation embedded as a constant in
`tools/tui.py`. Renders in the left column of the header Panel.

**How the SVG maps to character art.**
The SVG (`assets/tekhton-logo.svg`) is a semicircular arch: inner radius 50,
outer radius 80, centre at (100, 148) on a 200×200 canvas. Six voussoir
stones (3 left / 3 right) each span 30°. The arch walls are **widest at the
base** (~30 px per side) and narrow to ~8 px at the crown — each voussoir
tapers as it converges toward the top. The keystone is a trapezoid: wider at
its outer (top) face, narrower at its inner (bottom) face where it seats into
the 30° crown gap. The arch barrel (interior) is a clean open void; no
horizontal fill crosses it at any height.

Mapping to 12 chars × 5 rows (1 char ≈ 20 SVG px):

| Row | What it represents | Arch-wall width each side |
|-----|--------------------|--------------------------|
| 0 | above crown (keystone / ghost / empty) | — |
| 1 | crown zone — upper voussoirs (L1/R1) | ½ char (`▌ ▐`) |
| 2 | mid-upper arch (L1/R1 body, L2/R2 top) | 2 chars |
| 3 | mid-lower arch (L2/R2 / L3/R3) | 2 chars, wider apart |
| 4 | spring line / base pillars | 2 chars, widest gap |

The arch gap at the crown is 4 chars wide (matching the SVG's ~25 px inner gap
= ~1.3 chars, rounded up for legibility). The base interior spans 8 chars (SVG
inner diameter at spring line ≈ 100 px = 5 chars; relaxed to 8 for a more
open-feeling arch).

```
          Row:  0123456789AB   (hex col labels, 12 chars wide)
Row 4 base:     "██        ██"  ← arch springs: 2-char wall + 8-char void + 2-char wall
Row 3 lower:    " ██      ██ "  ← walls 2 wide, 6-char interior
Row 2 mid:      "  ██    ██  "  ← walls 2 wide, 4-char interior
Row 1 crown:    "   ▌    ▐   "  ← walls ½ wide (half-blocks), gap open
Row 0 above:    "    ████    "  ← keystone body (4 chars, floats at crown width)
```

The `▌` (left-half block) on the left and `▐` (right-half block) on the right
in row 1 represent the angled inner faces of L1/R1 — the voussoir faces that
the keystone tapers against when seated. The keystone when seated shows as
`▌████▐` in that row: the same voussoir faces now flanking the solid keystone
body. The arch barrel (rows 1–4 interior spaces) is always open — no
horizontal fill ever crosses it.

**Three animation frames** — inspired by the SVG's floating capstone descending
into place, rendered as a neon-sign blink cycling through three positions:

```
          Frame 0              Frame 1              Frame 2
          keystone absent      keystone floating    keystone seated
          (ghost/dim)          (high above arch)    (locks into crown)

Row 0:  "    ░░░░    "       "    ████    "       "            "
Row 1:  "   ▌    ▐   "       "   ▌    ▐   "       "   ▌████▐   "
Row 2:  "  ██    ██  "       "  ██    ██  "       "  ██    ██  "
Row 3:  " ██      ██ "       " ██      ██ "       " ██      ██ "
Row 4:  "██        ██"       "██        ██"       "██        ██"
```

- **Frame 0**: `░░░░` (light shade blocks, U+2591) at row 0 show the ghost /
  unlit-neon outline of where the keystone belongs. The arch gap (row 1,
  between `▌` and `▐`) is open — keystone is absent.
- **Frame 1**: `████` at row 0 — keystone materialised and floating high.
  Gap in row 1 still open.
- **Frame 2**: row 0 empty; row 1 becomes `▌████▐` — keystone has descended
  into the crown gap, its body flush between the voussoir faces. Arch
  complete. No bar crosses the interior — the interior spaces in rows 2–4
  remain untouched.

Frame advance: `frame = int(time.time() * 0.6) % 3` — new frame every ~1.7 s.

**Styles per frame / state:**

| State | Row 0 style | Row 1 keystone style | Wall style |
|-------|-------------|----------------------|------------|
| Frame 0 (ghost) | `"dim cyan"` | `"white"` (voussoirs only) | `"white"` |
| Frame 1 (high) | `"bold bright_cyan"` | `"white"` (voussoirs only) | `"white"` |
| Frame 2 (seated) | `""` (empty) | `"bold white"` (keystone+voussoirs) | `"white"` |
| idle | `""` (empty) | `"dim white"` | `"dim white"` |
| complete | `""` (empty) | `"bold yellow"` | `"yellow"` |

**Complete state** — when `complete=true` in the status JSON: lock to the
Frame 2 shape and apply gold styling to every row. The seated arch in gold =
the keystone is permanently in place.

**Idle state** — when `current_agent_status == "idle"` and not complete:
render the Frame 2 (seated / arch-complete) shape, all dim white.

**`_build_logo(status: dict) -> Text`:**

```python
# Module-level constants — (text, style) tuples per row.
# All rows are exactly 12 characters wide.
_ARCH_WALLS: list[tuple[str, str]] = [          # rows 1–4, arch always present
    ("   ▌    ▐   ", "white"),   # row 1 crown — voussoir faces, gap open
    ("  ██    ██  ", "white"),   # row 2 mid-upper
    (" ██      ██ ", "white"),   # row 3 mid-lower
    ("██        ██", "white"),   # row 4 base
]
_LOGO_FRAMES: list[tuple[str, str]] = [
    # row 0 only — what appears above the arch in each frame
    ("    ░░░░    ", "dim cyan"),        # frame 0: ghost keystone
    ("    ████    ", "bold bright_cyan"),# frame 1: keystone floating high
    ("            ", ""),                # frame 2: keystone gone from row 0
]
_LOGO_FRAME2_CROWN = ("   ▌████▐   ", "bold white")  # row 1 when keystone seated
_LOGO_COMPLETE_ROW0 = ("            ", "")
_LOGO_COMPLETE_CROWN = ("   ▌████▐   ", "bold yellow")
_LOGO_COMPLETE_WALL_STYLE = "yellow"
_LOGO_IDLE_CROWN = ("   ▌████▐   ", "dim white")
_LOGO_IDLE_WALL_STYLE = "dim white"


def _build_logo(status: dict[str, Any]) -> Text:
    complete = status.get("complete", False)
    agent_status = status.get("current_agent_status", "idle")

    if complete:
        rows = [
            _LOGO_COMPLETE_ROW0,
            _LOGO_COMPLETE_CROWN,
            *[(chars, _LOGO_COMPLETE_WALL_STYLE) for chars, _ in _ARCH_WALLS[1:]],
        ]
    elif agent_status == "idle":
        rows = [
            ("            ", ""),
            _LOGO_IDLE_CROWN,
            *[(chars, _LOGO_IDLE_WALL_STYLE) for chars, _ in _ARCH_WALLS[1:]],
        ]
    else:
        frame = int(time.time() * 0.6) % 3
        crown = _LOGO_FRAME2_CROWN if frame == 2 else _ARCH_WALLS[0]
        rows = [
            _LOGO_FRAMES[frame],  # row 0: ghost / high / empty
            crown,                # row 1: open gap or seated keystone
            *_ARCH_WALLS[1:],     # rows 2–4: always the same
        ]

    text = Text()
    for i, (chars, style) in enumerate(rows):
        if i > 0:
            text.append("\n")
        if style:
            text.append(chars, style=style)
        else:
            text.append(chars)
    return text
```

**`TUI_SIMPLE_LOGO` config key** (new, default `false`): when `true`, replaces
the block art with a plain 5-line ASCII fallback for terminals where Unicode
block glyphs render at incorrect widths:

```
     /\
    /  \
   / () \
  /______\
 |        |
```

Default `false`; add to `lib/config_defaults.sh` and `CLAUDE.md`.

---

### §6 — Hold-on-Complete: Pause Before Finalize Banner

**Current behaviour:** `tui_complete` writes `complete=true` to the status
file, waits 0.3s, SIGKILLs the sidecar. The alternate screen vanishes and the
finalize banner prints instantly. Any run longer than a few seconds means the
entire event history is gone.

**New behaviour:**

1. `tui_complete VERDICT` writes `complete=true` and `verdict` to the JSON as
   before, then enters a **wait loop** (polls `kill -0 $_TUI_PID`) instead of
   immediately killing the sidecar:

```bash
tui_complete() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    _TUI_VERDICT="${1:-}"
    _TUI_COMPLETE=true
    _TUI_AGENT_STATUS="complete"
    _tui_write_status
    # Wait up to TUI_COMPLETE_HOLD_TIMEOUT for sidecar to exit naturally
    local _deadline=$(( $(date +%s) + ${TUI_COMPLETE_HOLD_TIMEOUT:-120} ))
    while [[ -n "$_TUI_PID" ]] && kill -0 "$_TUI_PID" 2>/dev/null; do
        [[ $(date +%s) -ge $_deadline ]] && break
        sleep 0.1
    done
    tui_stop
}
```

2. **Python sidecar detects `complete=true`:** exits `Live` context (which
   sends `RMCUP` / restores normal terminal mode), then enters a **hold
   sequence** on `/dev/tty` before calling `sys.exit`:

```python
# Inside main(), after the Live loop exits:
if status.get("complete"):
    _hold_on_complete(status, console, event_lines)
```

```python
def _hold_on_complete(
    status: dict[str, Any],
    console: Console,
    event_lines: int,
) -> None:
    """Print full event log to normal scroll, then wait for Enter."""
    verdict = (status.get("verdict") or "").upper()
    pipeline_elapsed = int(status.get("pipeline_elapsed_secs", 0) or 0)
    task = status.get("task", "")
    milestone = status.get("milestone", "")

    # Divider
    console.print()
    console.rule("[bold cyan]Tekhton — Run Complete[/bold cyan]", style="cyan")

    # Summary line
    verdict_style = "bold green" if verdict == "SUCCESS" else "bold red"
    console.print(
        f"  Verdict: [{verdict_style}]{verdict}[/{verdict_style}]   "
        f"Elapsed: {_fmt_duration(pipeline_elapsed)}   "
        + (f"Milestone: {milestone}   " if milestone else "")
        + (f'Task: "{task[:60]}{"…" if len(task) > 60 else ""}"' if task else ""),
    )
    console.print()

    # Full event history (all buffered events, not just last N)
    events = status.get("recent_events", []) or []
    if events:
        console.print("[bold]Event log:[/bold]", style="dim")
        for ev in events:
            ts    = ev.get("ts", "")
            level = ev.get("level", "info")
            msg   = ev.get("msg", "")
            style = {"info": "white", "warn": "yellow",
                     "error": "red", "success": "green"}.get(level, "white")
            console.print(f"  [dim]{ts}[/dim]  [{style}]{msg}[/{style}]")
        console.print()

    # Hold prompt
    try:
        _tty_in = open("/dev/tty", "r")
        console.print("[dim]Press [bold]Enter[/bold] to continue…[/dim]", end="")
        _tty_in.readline()
        _tty_in.close()
    except OSError:
        time.sleep(3)  # non-interactive fallback: brief pause then continue
```

3. User presses Enter → sidecar calls `sys.exit(0)` → the shell's wait loop in
   `tui_complete` unblocks → `tui_stop` runs (no-op; sidecar already exited) →
   `finalize_run` continues → the finalize banner prints in normal terminal
   scroll, visible above the event dump in the user's scrollback buffer.

**New config key:**

| Key | Default | Notes |
|-----|---------|-------|
| `TUI_COMPLETE_HOLD_TIMEOUT` | `120` | Seconds to wait for sidecar to exit naturally before force-killing |

Add to `lib/config_defaults.sh` and `CLAUDE.md`.

---

### §7 — Updated Status JSON Schema

Full schema after M98 additions (new fields marked `[NEW]`):

```json
{
  "version": 1,
  "run_id": "20260418_143201_m97",
  "milestone": "97",
  "milestone_title": "TUI Mode: rich.live display",
  "task": "Fix spinner guard and redesign TUI layout…",
  "attempt": 2,
  "max_attempts": 3,
  "stage_num": 3,
  "stage_total": 6,
  "stage_label": "coder",
  "agent_turns_used": 14,
  "agent_turns_max": 35,
  "agent_elapsed_secs": 192,
  "stage_start_ts": 1745001234,
  "agent_model": "claude-opus-4-7",
  "pipeline_elapsed_secs": 312,
  "stages_complete": [
    {"label":"intake","model":"claude-sonnet-4-6","turns":"2/10","time":"18s","verdict":"PASS"},
    {"label":"scout","model":"claude-haiku-4-5","turns":"11/20","time":"54s","verdict":null}
  ],
  "current_agent_status": "running",
  "run_mode": "milestone",      
  "cli_flags": "--auto-advance",
  "stage_order": ["intake","scout","coder","security","review","tester"],
  "last_event": "Invoking coder agent (max 35 turns)…",
  "recent_events": [...],
  "action_items": [],
  "verdict": null,
  "complete": false
}
```

---

## Configuration

New and changed keys in `lib/config_defaults.sh`:

| Key | Old Default | New Default | Notes |
|-----|-------------|-------------|-------|
| `TUI_EVENT_LINES` | `8` | `60` | Ring-buffer depth only; display height is terminal-driven |
| `TUI_COMPLETE_HOLD_TIMEOUT` | *(new)* | `120` | Max seconds to wait for sidecar before SIGKILL after complete |
| `TUI_SIMPLE_LOGO` | *(new)* | `false` | Use ASCII fallback instead of block-char arch logo |

---

## Files Modified

| File | Change |
|------|--------|
| `lib/tui.sh` | `export _TUI_ACTIVE`; new `tui_set_context` function; new globals `_TUI_RUN_MODE`, `_TUI_CLI_FLAGS`, `_TUI_STAGE_ORDER`; extended wait loop in `tui_complete` |
| `lib/tui_helpers.sh` | Add `run_mode`, `cli_flags`, `stage_order` fields to `_tui_json_build_status` |
| `lib/plan_batch.sh` | Wrap `printf` spinner with `[[ "${_TUI_ACTIVE:-false}" != "true" ]]` guard |
| `lib/config_defaults.sh` | `TUI_EVENT_LINES` `8→60`; add `TUI_COMPLETE_HOLD_TIMEOUT=120`; add `TUI_SIMPLE_LOGO=false` |
| `tekhton.sh` | Add `tui_set_context` call before `tui_start` (derive run_mode, cli_flags, stage_order) |
| `tools/tui.py` | Replace 4-panel layout with 2-zone; add `_build_header_bar`, `_build_logo`, `_hold_on_complete`; remove `_build_stage_panel`, `_build_pipeline_panel`; animate logo; hold-on-complete dump+prompt |
| `CLAUDE.md` | Update `TUI_EVENT_LINES` description; add `TUI_COMPLETE_HOLD_TIMEOUT`, `TUI_SIMPLE_LOGO` to config table |

---

## Acceptance Criteria

- [ ] `_TUI_ACTIVE` is exported — child processes (`bash tests/run_tests.sh`)
      inherit `true` and their spinners produce no `/dev/tty` output while TUI
      is running. Verified: `test_agent_fifo_invocation.sh` completes without
      the `TestTimeout (0mXXs, --/10)` text appearing on the TUI border.
- [ ] `lib/plan_batch.sh` spinner is suppressed when `_TUI_ACTIVE=true`
- [ ] New layout renders: header (size=8) above, events (ratio=1) fills rest —
      no "Current Stage" or "Pipeline" panels visible
- [ ] Stage pills row shows correct icons: `✓` for completed stages, `▶` for
      active stage, `○` for pending — in `stage_order` sequence order
- [ ] Active-stage bar shows label, model (without `claude-` prefix), progress
      bar, turns fraction, elapsed time, and spinner char — all on one row
- [ ] Header context row shows correct `run_mode`, `attempt/max_attempts`, and
      any non-default `cli_flags` for: milestone run, fix-nb run, task run,
      run with `--skip-audit`
- [ ] Task string in header is truncated at 60 chars with `…` when longer
- [ ] Logo animates: capstone cycles through 3 positions at 0.6 Hz when an
      agent is running; freezes on seated position when idle; turns gold when
      `complete=true`
- [ ] `TUI_SIMPLE_LOGO=true` renders the 4-line ASCII fallback with no block
      chars
- [ ] Event feed fills all available terminal height; `TUI_EVENT_LINES=60`
      ring-buffer stores last 60 events (not 8); event count > 8 is visible
      on a normal terminal (≥24 rows)
- [ ] On `complete=true`: sidecar exits `Live` context (terminal restored to
      normal mode), prints divider + verdict + full event history + "Press
      Enter to continue…" prompt to `/dev/tty`, waits for keypress before
      exiting
- [ ] After Enter: finalize banner from `finalize_run` prints in normal
      terminal scroll (not alternate screen), visible in scrollback
- [ ] If sidecar doesn't exit within `TUI_COMPLETE_HOLD_TIMEOUT` seconds,
      `tui_complete` force-kills it and pipeline continues normally
- [ ] `TUI_COMPLETE_HOLD_TIMEOUT=0` skips the wait and kills immediately
      (existing M97 behaviour for non-interactive / CI wrapping)
- [ ] Terminal resize does not crash the sidecar (rich handles repaint)
- [ ] `TUI_ENABLED=false` produces identical plain output — no regressions from
      M96/M97 plain mode
- [ ] `tests/test_tui_fallback.sh` passes unchanged (fallback paths unaffected)
- [ ] `tools/tests/test_tui.py` updated: tests for `_build_header_bar`,
      `_build_logo` (each of 3 frames + complete + idle states),
      `_hold_on_complete` (smoke test with mock console), and absence of
      `_build_stage_panel`/`_build_pipeline_panel`
- [ ] `shellcheck` passes on all modified `.sh` files with zero new warnings
