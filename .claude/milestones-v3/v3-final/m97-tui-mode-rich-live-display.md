# Milestone 97: TUI Mode — Rich Live Display
<!-- milestone-meta
id: "97"
status: "done"
-->
<!-- PM-tweaked: 2026-04-17 -->

## Overview

Tekhton's terminal output, even after the M96 hygiene pass, is fundamentally a
scrolling log — each line appears once and disappears off the top of the
terminal as the run progresses. For a pipeline that routinely runs 30–150
minutes, this means the most important question ("what is it doing right now,
and how far along is it?") requires the user to scroll or keep the terminal
focused.

This milestone introduces an opt-in TUI mode: a full-screen live display built
on Python's `rich` library that splits the terminal into a persistent status
zone (updating in-place) and a scrolling event zone (recent notable events).
Tekhton falls back to the M96 cleaned-up plain output automatically when Python
is unavailable, the terminal is non-interactive, or `TUI_ENABLED=false`.

This is a companion to the Python tooling that already exists in `tools/`
(repo map, tag cache, tree-sitter indexer). The TUI process runs in the same
optional virtualenv pattern: if the venv is absent, TUI silently disables
itself.

## Design

### Architecture

Tekhton spawns a lightweight Python process (`tools/tui.py`) at pipeline start
as a background sidecar. The two processes communicate via a small status file
(`$TEKHTON_DIR/tui_status.json`) and optional named pipe
(`$TEKHTON_DIR/tui_events.fifo`). Tekhton writes state updates; the TUI process
reads and re-renders at a configurable tick rate (default: 500ms).

No changes to the core pipeline's sequential execution model. The sidecar is
fully decoupled: if it crashes or is killed, the pipeline continues unaffected.

```
tekhton.sh  ──writes──▶  tui_status.json  ──reads──▶  tools/tui.py
                          tui_events.fifo               (rich.live)
```

### Status file schema

`tui_status.json` is overwritten atomically (write to `.tmp`, then `mv`) by
`lib/tui.sh`. Schema:

```json
{
  "version": 1,
  "run_id": "20260417_220722_m96",
  "milestone": "96",
  "milestone_title": "CLI Output Hygiene",
  "task": "M96",
  "attempt": 1,
  "max_attempts": 5,
  "stage": "coder",
  "stage_num": 1,
  "stage_total": 4,
  "stage_label": "Coder",
  "agent_turns_used": 42,
  "agent_turns_max": 70,
  "agent_elapsed_secs": 1540,
  "agent_model": "claude-opus-4-7",
  "pipeline_elapsed_secs": 1820,
  "stages_complete": [
    {"label": "Intake",    "model": "claude-sonnet-4-6", "turns": "2/10",  "time": "16s",  "verdict": "PASS"},
    {"label": "Scout",     "model": "claude-haiku-4-5",  "turns": "19/20", "time": "1m6s", "verdict": null},
    {"label": "Coder",     "model": "claude-opus-4-7",   "turns": "60/70", "time": "26m41s","verdict": null}
  ],
  "current_agent_status": "running",
  "last_event": "Invoking coder agent (max 70 turns)...",
  "recent_events": [
    {"ts": "14:23:01", "level": "info",    "msg": "[✓] Pre-flight: 3 passed"},
    {"ts": "14:23:04", "level": "info",    "msg": "[✓] Tests pass at baseline"},
    {"ts": "14:23:05", "level": "info",    "msg": "[✓] Scout finished — 5 files, medium complexity"},
    {"ts": "14:23:07", "level": "info",    "msg": "Invoking coder agent (max 70 turns)..."}
  ],
  "action_items": [],
  "verdict": null,
  "complete": false
}
```

### TUI layout (rich.live + Layout)

```
┌─────────────────────────────────────────────────────────┐
│  Tekhton  M96 — CLI Output Hygiene           14:24:31   │
├──────────────────────────────┬──────────────────────────┤
│  Stage 1 / 4 — Coder         │  Pipeline               │
│  claude-opus-4-7              │  Elapsed:   30m 20s     │
│                               │  Attempt:   1 / 5       │
│  Turns   [████████░░]  60/70  │                         │
│  Time    26m 41s              │  Stages complete: 2     │
│  Context ~12.7k (6%)          │  Intake  ✓  16s         │
│                               │  Scout   ✓  1m6s        │
│  ⠸ Running...                 │                         │
├──────────────────────────────┴──────────────────────────┤
│  Recent events                                          │
│  14:23:01  [✓] Pre-flight: 3 passed                     │
│  14:23:04  [✓] Tests pass at baseline                   │
│  14:23:05  [✓] Scout finished — 5 files, medium         │
│  14:23:07  Invoking coder agent (max 70 turns)...       │
└─────────────────────────────────────────────────────────┘
```

The layout uses `rich.layout` with a fixed header, two-column middle panel, and
a scrolling `rich.table` for recent events (last 8 lines, configurable). On
terminal resize, rich handles reflowing automatically.

### lib/tui.sh

New file. Sourced by `tekhton.sh`. Provides:

- `tui_start` — check `TUI_ENABLED`, check venv + `tools/tui.py`, spawn
  sidecar, create FIFO, write initial `tui_status.json`
- `tui_update_stage STAGE_NUM STAGE_TOTAL STAGE_LABEL MODEL` — overwrites
  status file with current stage info
- `tui_update_agent TURNS_USED TURNS_MAX ELAPSED_SECS` — tick updates from
  agent monitor (called by existing spinner tick in `lib/agent_monitor.sh`)
- `tui_append_event LEVEL MSG` — appends to `recent_events` ring buffer (max
  8 entries) and rewrites status file
- `tui_complete VERDICT` — marks complete, triggers final render, then kills
  sidecar
- `tui_stop` — unconditional sidecar teardown (called in EXIT trap)

When `TUI_ENABLED=false` or TTY check fails, all functions are no-ops. The
existing `log`, `warn`, `success` calls in `lib/common.sh` pass through to
stdout unchanged — TUI mode does not suppress plain output; it supplements it
(the plain output functions write to the log file as before, with stdout
redirected to the sidecar's event stream when TUI is active).

### tools/tui.py

Single-file Python script. Dependencies: `rich` (already in
`tools/requirements.txt`). Reads `tui_status.json` on a tick, renders the
`rich.live` layout, and exits cleanly when the status file marks `complete:
true` or when stdin closes.

Startup: invoked by `tui_start` as a background process:
```bash
"$REPO_MAP_VENV_DIR/bin/python" "$TEKHTON_HOME/tools/tui.py" \
    --status-file "$_TUI_STATUS_FILE" &
_TUI_PID=$!
```

### Fallback behaviour

| Condition | Result |
|-----------|--------|
| `TUI_ENABLED=false` | Plain M96 output (no change) |
| Non-interactive TTY (`! -t 1`) | Auto-disable TUI, plain output |
| Python venv absent | Warn once, disable TUI, plain output |
| `rich` import fails | Warn once, disable TUI, plain output |
| Sidecar crashes mid-run | Log to file, pipeline continues, plain output resumes |
| Terminal < 80 cols | TUI renders degraded single-column layout |

### Integration points

The TUI update calls are inserted at the same locations as the existing
`print_run_summary` and agent monitor calls — no new decision points in the
pipeline logic.

Key integration locations:
- `tekhton.sh`: `tui_start` after startup checks; `tui_stop` in EXIT trap
- `lib/agent.sh` / `lib/agent_monitor.sh`: `tui_update_agent` on each spinner
  tick
- `tekhton.sh` stage dispatch: `tui_update_stage` before each stage invocation
- `lib/common.sh`: `log`, `warn`, `success` call `tui_append_event` as a side
  effect when TUI is active
- `lib/finalize.sh`: `tui_complete` before final banner

## Configuration

New keys in `lib/config_defaults.sh` (and documented in CLAUDE.md):

| Key | Default | Notes |
|-----|---------|-------|
| `TUI_ENABLED` | `auto` | `auto` = enable on interactive TTY if venv present; `true` = always try; `false` = disable |
| `TUI_TICK_MS` | `500` | Status file poll interval in milliseconds |
| `TUI_EVENT_LINES` | `8` | Recent event lines shown in scroll panel |
| `TUI_VENV_DIR` | `${REPO_MAP_VENV_DIR}` | Shared with indexer venv by default |

## Migration Impact

[PM: Added — milestone introduces 4 new config keys. All have safe defaults; no
existing `pipeline.conf` requires changes.]

- **Existing users**: No action required. All new keys default to `auto`/existing
  behaviour. Runs without the Python venv continue to work exactly as before
  (plain M96 output, one warning if `TUI_ENABLED=auto`).
- **`tools/requirements.txt`**: `rich` must be present (milestone states it is
  already listed; confirm before merging).
- **CI / non-interactive environments**: `TUI_ENABLED=auto` detects non-TTY
  automatically — no pipeline.conf change needed for CI.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| New shell files | 1 | `lib/tui.sh` |
| New Python files | 1 | `tools/tui.py` |
| Shell files modified | 6 | `tekhton.sh`, `lib/common.sh`, `lib/agent_monitor.sh`, `lib/agent.sh`, `lib/finalize.sh`, `lib/config_defaults.sh` [PM: corrected from 4 — Integration Points names `lib/agent.sh` (tui_update_agent) and `lib/finalize.sh` (tui_complete) which were absent from the original count] |
| New config keys | 4 | `TUI_ENABLED`, `TUI_TICK_MS`, `TUI_EVENT_LINES`, `TUI_VENV_DIR` |
| Shell tests added | 1 | `tests/test_tui_fallback.sh` — verifies no crash and correct plain-output fallback when venv absent |
| Python tests added | 1 | `tools/tests/test_tui.py` — status file parsing, layout rendering smoke test |

## Acceptance Criteria

- [ ] `TUI_ENABLED=auto` activates TUI on an interactive terminal with venv
      present
- [ ] `TUI_ENABLED=false` produces identical output to a pre-M97 run (plain
      M96-clean output)
- [ ] `TUI_ENABLED=auto` on a non-TTY (piped or CI) produces plain output, no
      errors
- [ ] Python venv absent with `TUI_ENABLED=auto`: single warning line, run
      continues normally with plain output
- [ ] Sidecar process is always terminated by the EXIT trap — no zombie
      `tui.py` processes after abnormal exit
- [ ] Turn progress bar updates at least once per agent spinner tick
- [ ] Completed stages appear in the completed stages panel with correct
      turn/time data
- [ ] Terminal resize does not crash the sidecar
- [ ] `tools/tests/test_tui.py` passes (status file parse + render smoke test)
- [ ] `tests/test_tui_fallback.sh` passes (venv-absent fallback)
