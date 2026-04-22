# Coder Summary — M117 Recent Events Substage Attribution

## Status: COMPLETE

## What Was Implemented

**Goal.** Recent Events log entries in the TUI now carry a `source` field that
reflects the active pipeline stage (and substage, if any), so a user watching
the Recent Events panel sees `[coder » scout] scanning repo map` instead of
bare `scanning repo map`.

**Attribution pipeline.**
- `lib/common.sh` — new `_tui_compute_source()` helper consults
  `_TUI_CURRENT_STAGE_LABEL` and `_TUI_CURRENT_SUBSTAGE_LABEL`. Returns
  `"stage » substage"` when both are set, the single label otherwise, or
  empty string when no pipeline stage is open (banner events, pre-stage
  noise). Short-circuits to empty under `TUI_LIFECYCLE_V2=false` (M113 opt-out).
  `_tui_notify()` now passes the computed source as the 4th positional
  argument to `tui_append_event`.
- `lib/tui_ops.sh` — `tui_append_event` gained an optional `SOURCE` arg
  (positional slot 4). Ring buffer entry shape extended from 4-field
  `ts|level|type|msg` to 5-field `ts|level|type|source|msg`. `msg` is still
  the last field so it can contain `|` unconditionally.
- `lib/tui_helpers.sh` — `_tui_recent_events_json` parses the 5-field shape,
  falling back to legacy 4-field and 3-field shapes for robustness. Emits
  `source` as a JSON field only when non-empty; absent field means the
  renderer should render unprefixed.
- `tools/tui_render.py` — `_build_events_panel` prepends `[<source>] ` (dim
  style) to the message body when the event has a non-empty `source`;
  otherwise renders exactly as pre-M117.

**Log-file isolation.** Attribution is a TUI-only concern. `_out_emit` writes
to stdout / `LOG_FILE` with the unprefixed `notify_msg`; only the
`_tui_notify` leg threads source through to the ring buffer. Verified by test
M117-6 (grep `LOG_FILE` for the breadcrumb — must not be present).

## Files Modified

- `lib/common.sh` — Added `_tui_compute_source()`; extended `_tui_notify()`.
- `lib/tui_ops.sh` — Extended `tui_append_event()` signature and serialisation.
- `lib/tui_helpers.sh` — Extended `_tui_recent_events_json()` parser.
- `tools/tui_render.py` — Added source-prefix rendering in `_build_events_panel`.
- `tools/tests/test_tui.py` — Added 5 renderer cases (substage prefix,
  stage-only, unattributed, empty-source, mixed).
- `tests/test_tui_attribution.sh` (NEW) — 11 assertions covering substage
  attribution, stage-only, unattributed, opt-out (`TUI_LIFECYCLE_V2=false`),
  log-file isolation, ring-buffer depth, and `|`-containing msg round-trip.
- `tests/test_tui_stage_wiring.sh` — Updated M110-9 / M110-10 assertions to
  match new 5-field shape (`|runtime||msg` / `|summary||msg` — empty source).
- `tests/test_tui_multipass_lifecycle.sh` — Updated Test 4 / Test 5 ring-buffer
  pattern globs to account for the extra empty-source segment.

## Human Notes Status

No human notes for this task.

## Observed Issues (out of scope)

- `lib/common.sh` is 445 lines after this change (was 421 before — pre-existing
  over-ceiling). M117 added ~24 lines for the attribution helper and call site.
  Splitting common.sh below 300 lines would require extracting colors,
  box-drawing, phase timing, or gitignore helpers into their own module and
  touching every source site — clearly a separate cleanup milestone. The net
  addition here is small and fully localised to the logging surface it serves.

## Test Results

- Shell tests: `431 passed, 0 failed` (up from 8 pre-existing failures in
  baseline; baseline failures were unrelated to M117 surfaces).
- Python tests: `188 passed`.
- New shell test `test_tui_attribution.sh`: 11 passed, 0 failed.
- Shellcheck: clean across `tekhton.sh`, `lib/*.sh`, `stages/*.sh`, and the
  new test file.

## Docs Updated

None — no public-surface changes in this task. The `tui_append_event`
signature gained an optional positional argument, but all existing callers
continue to work unchanged and no user-facing config key or CLI flag was
added. The ring-buffer entry format is an internal serialisation concern.
