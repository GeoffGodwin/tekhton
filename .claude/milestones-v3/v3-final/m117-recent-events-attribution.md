# M117 - Recent Events Substage Attribution

<!-- milestone-meta
id: "117"
status: "done"
-->

## Overview

After M113–M116, the stage-timings panel, pill row, and header consistently
report the pipeline stage while sub-stages appear as breadcrumbs. The Recent
Events log, however, still emits raw lines with no indication of whether a
message came from the parent stage's main agent or from an active substage.

A user watching the log sees coder work and scout work interleaved with no
attribution — the same confusion that triggered this initiative, just in a
different surface. M117 closes the gap by prefixing Recent Events emissions
with the active substage label when one is set.

Example (during scout work inside coder):

```
Before:  [info] scanning repo map
After:   [coder » scout] scanning repo map
```

When no substage is active, events render as today.

## Design

### Goal 1 — Route log emissions through a single attribution point

`lib/common.sh` currently defines `_tui_notify` which fans log/success/warn/
error calls into `_out_emit` and then into `tui_append_event`. This is the
single choke point for TUI-bound events.

Add attribution logic inside `_tui_notify` (or the thinnest wrapper it
delegates to) that consults `_TUI_CURRENT_SUBSTAGE_LABEL` and
`_TUI_CURRENT_STAGE_LABEL`:

```bash
# Conceptual
local prefix=""
if [[ -n "${_TUI_CURRENT_SUBSTAGE_LABEL:-}" ]]; then
    prefix="${_TUI_CURRENT_STAGE_LABEL} » ${_TUI_CURRENT_SUBSTAGE_LABEL}"
fi
# prefix is appended to event payload as a structured field
```

The prefix is stored as a dedicated JSON field on the event (e.g.,
`source`), not spliced into the message string. The Python renderer applies
the visual prefix. This keeps event payloads machine-parseable and decouples
attribution styling from event production.

### Goal 2 — Python renderer applies the prefix visually

Update `tools/tui_render.py` (Recent Events panel builder) to prepend
`"[${source}] "` to the rendered line when `source` is non-empty. Keep the
existing styling (dim prefix, default body). When `source` is absent or
empty, render lines unchanged.

### Goal 3 — Preserve log-file formats

`lib/common.sh` writes plaintext logs to stderr and to any session log files.
Those paths must NOT gain the breadcrumb prefix — logs remain as today.
Attribution is a TUI-only concern. Only `tui_append_event` (and downstream
renderer) receives the `source` field.

### Goal 4 — Handle events emitted outside any stage

Pre-flight and intake emit events before any pipeline stage is open. In that
case, `_TUI_CURRENT_STAGE_LABEL` may be set to `preflight` / `intake`
(pipeline stages of class `pre`). Substage label is empty. Attribution falls
back to stage-only or blank.

Events emitted outside *any* stage (e.g., startup banner) have both globals
empty. The `source` field is omitted; renderer renders unprefixed.

### Goal 5 — Respect opt-out

When `TUI_LIFECYCLE_V2=false`, attribution logic is skipped (matches M113's
no-op substage behavior). Events render exactly as pre-M117.

## Files Modified

| File | Change |
|------|--------|
| `lib/common.sh` | Add substage/stage attribution to `_tui_notify` / `_out_emit` path; pass `source` field to `tui_append_event` |
| `lib/tui_ops.sh` | Extend `tui_append_event` to accept and emit optional `source` field on the event record |
| `lib/tui_helpers.sh` | Propagate `source` through the events ring buffer serialization |
| `tools/tui_render.py` | Render `[source] ` prefix when `source` is non-empty; unchanged otherwise |
| `tools/tests/test_tui_render.py` | Add cases: substage-prefixed event, stage-only event, unattributed event |
| `tests/test_tui_attribution.sh` | New test: events emitted during substage carry breadcrumb `source`; events outside substage carry stage-only source or none; opt-out flag disables |

## Acceptance Criteria

- [ ] Events emitted while a substage is active (e.g., during scout) carry a
      `source` field of the form `"parent » substage"` in `tui_status.json`'s
      events buffer.
- [ ] Events emitted during a stage with no active substage carry `source`
      equal to the stage label (e.g., `"coder"`).
- [ ] Events emitted before any stage (e.g., banner) carry no `source` field
      or an empty one.
- [ ] Python renderer displays `[coder » scout] ...` for substage events,
      `[coder] ...` for stage-only events, and unprefixed lines for
      unattributed events.
- [ ] Attribution does NOT appear in plaintext log-file output (stderr,
      session logs) — only in `tui_status.json` events and rendered TUI.
- [ ] With `TUI_LIFECYCLE_V2=false`, events carry no `source` field and
      render exactly as pre-M117.
- [ ] Event ring-buffer depth (`TUI_EVENT_LINES`) behavior unchanged.
- [ ] Shellcheck clean for `lib/common.sh`, `lib/tui_ops.sh`,
      `lib/tui_helpers.sh`.
- [ ] `python -m pytest tools/tests/test_tui_render.py` passes.
- [ ] `bash tests/test_tui_attribution.sh` passes.

## Non-Goals

- Filtering Recent Events by substage.
- Coloring events differently per stage/substage.
- Retroactively attributing events already in the ring buffer at the moment
  substage tracking starts.
- Adding attribution to `.claude/logs/` JSONL records beyond the TUI surface.
- Changing `_out_emit` log-level semantics or log-file destinations.
