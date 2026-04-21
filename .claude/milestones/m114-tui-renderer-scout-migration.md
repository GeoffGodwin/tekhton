# M114 - TUI Renderer + Scout Substage Migration

<!-- milestone-meta
id: "114"
status: "pending"
-->

## Overview

M113 adds the hierarchical substage API but leaves every caller unchanged. M114
migrates the first (and most visible) sub-stage — **scout** — from the legacy
`tui_stage_transition` protocol onto the new substage API, and updates the
Python renderer to display substages as non-disruptive breadcrumbs instead of
treating them like pipeline stages.

After M114, a user running the coder stage will see:

- Pill row: unchanged (`coder` stays active; no scout pill — consistent with
  M110 policy).
- Stage-timings live row: `coder » scout` while scout is active, reverting to
  `coder` with a continuous (non-reset) timer when scout finishes. The turns
  column is blank while scout is active because scout has no agent-turn
  counter of its own.
- Stage-timings completed rows: scout is NOT listed. Only `coder` appears when
  the coder stage completes.
- Header: continues to show `coder` throughout. Never flips to `scout`.
- Recent events: scout's existing log lines remain. (Attribution prefixes are
  out of scope; handled in M117.)

## Design

### Goal 1 — Renderer shows substage as breadcrumb in the live row

Update `tools/tui_render_timings.py::_build_timings_panel`:

- When `status.current_substage_label` is non-empty during an active stage,
  render the live-row label as `"{current_stage_label} » {current_substage_label}"`.
- Use the **parent** stage's start timestamp for the live-row duration. Do NOT
  reset when the substage begins.
- The turns column renders as an empty string while a substage is active.
  Parent-stage turns reappear when the substage ends.

### Goal 2 — Renderer tolerates missing keys

Since `tui_status.json` gains two new optional fields (`current_substage_label`,
`current_substage_start_ts`), the Python side must default both to empty/0 when
absent. This keeps old bash → new Python and new bash → old Python compatible
during the rollout window.

### Goal 3 — Migrate scout to the substage API

Replace the scout lifecycle block in `stages/coder.sh` (currently lines
~235–251):

Before:
```bash
tui_stage_begin "scout" ...
# scout runs
tui_stage_transition "scout" "coder" ...
```

After:
```bash
tui_substage_begin "scout" ...
# scout runs
tui_substage_end "scout" "${scout_verdict:-PASS}"
```

The outer `tui_stage_begin "coder"` at `tekhton.sh:2367` remains the single
owner of the coder pipeline-stage lifecycle. Scout no longer opens or closes a
stage — it is a transient breadcrumb inside coder.

### Goal 4 — Scout no longer appears in completed stage rows

With M113 guaranteeing that `tui_substage_end` does NOT push to
`_TUI_STAGES_COMPLETE`, this goal is mechanically enforced by the migration in
Goal 3. Acceptance explicitly verifies the resulting `stages_complete` array in
`tui_status.json` never contains a scout entry.

### Goal 5 — Keep `tui_stage_transition` alive for now

`tui_stage_transition` still has one remaining caller (architect-remediation in
`stages/architect.sh:151`). Deletion is deferred to M116. M114 leaves the
function in `lib/tui_ops.sh` untouched.

## Files Modified

| File | Change |
|------|--------|
| `tools/tui_render_timings.py` | Render `"{stage} » {substage}"` breadcrumb; blank turns column during substage; default missing substage keys to empty/0 |
| `tools/tui_render.py` | Defensive: header and pill row remain driven by `current_stage_label` only; verify no regression when substage fields are present |
| `stages/coder.sh` | Replace scout's `tui_stage_begin` + `tui_stage_transition` pair with `tui_substage_begin` + `tui_substage_end` |
| `tools/tests/test_tui_render_timings.py` | Add test cases: (a) substage breadcrumb rendering, (b) turns column blank during substage, (c) parent timer continuity across substage, (d) missing-key tolerance |
| `tests/test_tui_stage_wiring.sh` | Update M110 tests 5 & 6 to reflect that scout is no longer a stage-level transition; OR mark them for removal in M116 (they test `tui_stage_transition`, not scout specifically — leave intact for M116's deletion cleanup) |

## Acceptance Criteria

- [ ] When scout runs, `tui_status.json` shows `current_stage_label="coder"`
      and `current_substage_label="scout"` simultaneously.
- [ ] The stage-timings live row renders as `coder » scout` (breadcrumb form)
      while scout is active.
- [ ] The live-row duration timer is computed from the coder stage start, not
      the scout substage start — no visible reset at scout boundary.
- [ ] The turns column is blank while scout is active and shows coder's turns
      (e.g., `--/50`) after scout ends.
- [ ] `stages_complete` in `tui_status.json` never contains an entry labeled
      `scout` during or after a coder run.
- [ ] The pill row remains identical to pre-M114 behavior (no scout pill).
- [ ] The header shows `coder` continuously; never flips to `scout`.
- [ ] Python renderer treats missing `current_substage_label` /
      `current_substage_start_ts` as empty/0 without raising.
- [ ] `stages/architect.sh`'s `tui_stage_transition` call continues to work
      (unchanged — deferred to M116).
- [ ] All existing `tests/test_tui_stage_wiring.sh` tests still pass (tests 5
      & 6 exercise `tui_stage_transition` directly, not scout — they stay
      green).
- [ ] New renderer test cases in `test_tui_render_timings.py` all pass.
- [ ] Shellcheck clean for `stages/coder.sh`.

## Non-Goals

- Migrating rework or architect-remediation (M116).
- Retiring `tui_stage_transition` (M116).
- Retiring `current_operation` / `_TUI_OPERATION_LABEL` (M115).
- Adding substage prefixes to Recent events (M117).
- Introducing any new config flags.
