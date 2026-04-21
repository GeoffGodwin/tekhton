# M113 - TUI Hierarchical Substage API

<!-- milestone-meta
id: "113"
status: "pending"
-->

## Overview

M110 introduced a policy-driven stage model (`class|pill|timings|active|parent`)
and the `tui_stage_begin`/`tui_stage_end` lifecycle protocol. Scout, rework, and
architect-remediation were declared sub-stages in policy, but the *lifecycle
helpers themselves* still treat them like pipeline stages: their calls overwrite
`_TUI_CURRENT_STAGE_LABEL`, reset timers, and push completion rows to
`_TUI_STAGES_COMPLETE`.

The result is the desync that motivates the M113–M119 sequence:

- Stage-timings panel shows `coder` starting, then *completes* as `scout`, then
  opens a fresh `coder` row with a reset timer.
- Recent events log alternates `coder` → `scout` → `coder`.
- The pill row is correct (M110 fixed that surface) but the live row and header
  contradict it.

M113 introduces the first half of the fix: a **hierarchical substage API** that
lets sub-stages announce and retire themselves without disturbing their parent
stage's live row, timer, header, or completed-stage records. No caller is
migrated in M113 — this milestone only adds the API and the underlying state
tracking. M114 then migrates scout and wires the renderer.

## Design

### Goal 1 — Introduce `tui_substage_begin` / `tui_substage_end`

Add two new helpers to `lib/tui_ops.sh`:

- `tui_substage_begin LABEL [MODEL]` — mark a substage as active *inside* the
  currently open pipeline stage.
- `tui_substage_end LABEL [VERDICT]` — close the named substage.

Semantics:

- The parent stage's `_TUI_CURRENT_STAGE_LABEL`, `_TUI_CURRENT_STAGE_START_TS`,
  and lifecycle-id are **not mutated** by substage begin/end.
- Substage completion is **not** appended to `_TUI_STAGES_COMPLETE`. Substages
  are transient breadcrumbs, not pipeline-timeline entries.
- A `_TUI_CURRENT_SUBSTAGE_LABEL` global is set on begin, cleared on end. It is
  exposed (readable) so downstream milestones (M117 Recent Events attribution)
  can consult it from `lib/common.sh` without sourcing `tui_ops.sh` state.
- A `_TUI_CURRENT_SUBSTAGE_START_TS` global tracks substage start time so the
  renderer (M114) can display a substage duration hint if desired. Optional for
  consumers; always set by the API.

### Goal 2 — Auto-close substages when the parent ends

If `tui_stage_end` fires while `_TUI_CURRENT_SUBSTAGE_LABEL` is set, the parent
close is preceded by an implicit `tui_substage_end "<label>" "AUTO"` and a
single `warn "[tui] substage '<label>' auto-closed by parent end"` emission to
Recent events. This keeps state sane when a substage crashes or forgets to
close, without hard-failing the pipeline.

### Goal 3 — Respect the M110 opt-out flag

When `TUI_LIFECYCLE_V2=false`, both `tui_substage_begin` and `tui_substage_end`
must no-op. Users who opted out of M110 semantics stay on pre-M110 behavior
without partial hybridization.

### Goal 4 — Publish substage fields in `tui_status.json` as optional

Extend `lib/tui_helpers.sh` to emit two new keys in the status JSON:

- `current_substage_label` (string, empty when no substage active)
- `current_substage_start_ts` (int, 0 when no substage active)

Both fields are **optional**. Readers (Python renderer, future consumers) must
tolerate their absence. `tui_status.json` has no existing `schema_version`, so
no version bump is introduced; tolerance is enforced by M114's acceptance.

### Goal 5 — Keep migration surface minimal

No callers are migrated in M113. `stages/coder.sh` still uses
`tui_stage_transition` for scout; `stages/review.sh` and `stages/architect.sh`
still use `tui_stage_begin`/`tui_stage_end` for their sub-stages. The API is
dormant until M114 begins wiring it up. This keeps M113's blast radius to
`lib/tui_ops.sh`, `lib/tui_helpers.sh`, and a unit test.

## Files Modified

| File | Change |
|------|--------|
| `lib/tui_ops.sh` | Add `tui_substage_begin`, `tui_substage_end`; add `_TUI_CURRENT_SUBSTAGE_LABEL` / `_TUI_CURRENT_SUBSTAGE_START_TS` globals; extend `tui_stage_end` with auto-close-and-warn rule; gate all substage behavior on `TUI_LIFECYCLE_V2` |
| `lib/tui_helpers.sh` | Include `current_substage_label` and `current_substage_start_ts` in status JSON builder |
| `tests/test_tui_substage_api.sh` | New test file: API contract, no-op under opt-out, auto-close-and-warn, non-mutation of parent state |

## Acceptance Criteria

- [ ] `tui_substage_begin LABEL` sets `_TUI_CURRENT_SUBSTAGE_LABEL` and
      `_TUI_CURRENT_SUBSTAGE_START_TS` and writes a status-file update.
- [ ] `tui_substage_end LABEL` clears both globals and writes a status-file
      update. Substage completion is NOT appended to `_TUI_STAGES_COMPLETE`.
- [ ] `_TUI_CURRENT_STAGE_LABEL`, `_TUI_CURRENT_STAGE_START_TS`, and the parent
      lifecycle-id are unchanged across a full `tui_substage_begin` →
      `tui_substage_end` cycle.
- [ ] When `tui_stage_end` fires with `_TUI_CURRENT_SUBSTAGE_LABEL` still set,
      the substage is auto-closed first and a single `warn "[tui] substage
      '<label>' auto-closed by parent end"` event is emitted.
- [ ] With `TUI_LIFECYCLE_V2=false`, both substage functions are no-ops
      (no variables set, no status-file write, no event emission).
- [ ] `tui_status.json` includes `current_substage_label` and
      `current_substage_start_ts` keys when a substage is active; absent or
      empty when none is active.
- [ ] `_TUI_CURRENT_SUBSTAGE_LABEL` is readable from external scripts
      (`lib/common.sh` can consult it without extra sourcing).
- [ ] No existing caller is modified. `stages/coder.sh`, `stages/review.sh`,
      `stages/architect.sh` remain byte-identical to pre-M113.
- [ ] Shellcheck clean for all touched scripts.
- [ ] New test `tests/test_tui_substage_api.sh` exercises the full contract and
      passes.

## Non-Goals

- Migrating scout, rework, or architect-remediation to the new API (M114, M116).
- Renderer changes (M114).
- Retiring `tui_stage_transition` (M116).
- Event attribution / breadcrumb prefixing in Recent events (M117).
- Changing `TUI_LIFECYCLE_V2` default or removing the flag.
