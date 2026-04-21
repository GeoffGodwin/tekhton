# M116 - Rework + Architect-Remediation Migration; Retire `tui_stage_transition`

<!-- milestone-meta
id: "116"
status: "pending"
-->

## Overview

M114 migrated scout (the first sub-stage) onto the M113 substage API. M115
migrated `run_op` (the second parallel mechanism). M116 migrates the two
remaining sub-stages — **rework** (inside review) and **architect-remediation**
(inside architect) — and then deletes the now-unused `tui_stage_transition`
helper and its M110 wiring tests.

After M116, the codebase has a single lifecycle mechanism for sub-stages: the
M113 substage API. `tui_stage_transition` is gone. Every `tui_stage_begin` in
the pipeline matches a `tui_stage_end` for a true pipeline stage; every
sub-stage uses `tui_substage_begin` / `tui_substage_end`.

## Design

### Goal 1 — Migrate rework

`stages/review.sh` opens rework stages via `tui_stage_begin "rework"` at two
call sites (around lines 266 and 305, covering separate review cycles). Per
`get_stage_policy`, rework is declared `sub|no|yes|yes|review`: no pill,
parent = review.

Migrate both call sites to the substage API:

```bash
# Before
tui_stage_begin "rework" "${CLAUDE_JR_CODER_MODEL:-}"
# rework agent runs
tui_stage_end "rework" "$verdict"

# After
tui_substage_begin "rework" "${CLAUDE_JR_CODER_MODEL:-}"
# rework agent runs
tui_substage_end "rework" "$verdict"
```

The outer review `tui_stage_begin` / `tui_stage_end` pair stays untouched;
rework becomes a breadcrumb within review. Rework no longer appears in
`stages_complete`, and review's live-row timer runs continuously across rework
cycles.

### Goal 2 — Migrate architect-remediation

`stages/architect.sh:151` uses `tui_stage_transition "architect"
"architect-remediation"` to swap from architect to architect-remediation, then
issues further `tui_stage_begin/end` calls for architect-remediation at lines
155, 217, 392.

New flow: architect remains a pipeline stage with a single begin/end pair;
architect-remediation becomes a substage inside it.

```bash
# Before (line 151 pattern)
tui_stage_transition "architect" "architect-remediation" "$architect_model"
# architect-remediation work
tui_stage_end "architect-remediation" "$verdict"

# After
tui_substage_begin "architect-remediation" "$architect_model"
# architect-remediation work
tui_substage_end "architect-remediation" "$verdict"
```

The enclosing architect `tui_stage_begin`/`tui_stage_end` pair stays as the
stage-level lifecycle owner. All three architect-remediation call sites (155,
217, 392) are reviewed and updated to maintain matched substage begin/end
invariants.

### Goal 3 — Delete `tui_stage_transition`

After Goals 1 and 2 land and all callers are migrated, delete the function
from `lib/tui_ops.sh` (lines ~237–297). A final grep must return zero matches
across `lib/`, `stages/`, and `tekhton.sh` before deletion.

### Goal 4 — Remove M110 wiring tests for the deleted helper

`tests/test_tui_stage_wiring.sh` contains two tests that directly exercise
`tui_stage_transition`:

- Test M110-5: "tui_stage_transition — FROM closed, TO open, no label gap"
  (line ~385)
- Test M110-6: "tui_stage_transition adds FROM completion record" (line ~411)

These tests validated a mechanism that no longer exists. Delete both test
blocks. Other tests in the file (stage lifecycle IDs, stage_begin/end
invariants) remain.

### Goal 5 — Preserve policy records

`get_stage_policy` in `lib/pipeline_order_policy.sh` already declares rework
and architect-remediation as `sub|...`. No policy changes needed. The metrics
key and display-label resolvers (`get_stage_metrics_key`,
`get_stage_display_label`) are similarly unchanged.

## Files Modified

| File | Change |
|------|--------|
| `stages/review.sh` | Replace two `tui_stage_begin/end "rework"` pairs with `tui_substage_begin/end "rework"` |
| `stages/architect.sh` | Replace `tui_stage_transition` + trailing begin/end with `tui_substage_begin/end "architect-remediation"` at call sites 151, 155, 217, 392 |
| `lib/tui_ops.sh` | Delete `tui_stage_transition` function |
| `tests/test_tui_stage_wiring.sh` | Remove tests M110-5 and M110-6 |

## Acceptance Criteria

- [ ] `tui_stage_transition` does not appear in any `.sh` file under `lib/`,
      `stages/`, `tekhton.sh`, or `tests/` (historical milestone docs under
      `.claude/milestones/` are allowed to reference it).
- [ ] During a review cycle with rework, `stages_complete` in
      `tui_status.json` contains exactly one `review` entry per cycle and NO
      `rework` entries.
- [ ] The stage-timings live row reads `review » rework` while the jr-coder
      rework agent runs; the timer is continuous across rework entry/exit.
- [ ] During an architect audit with remediation, `stages_complete` contains
      exactly one `architect` entry and NO `architect-remediation` entry.
- [ ] The stage-timings live row reads `architect » architect-remediation`
      during remediation.
- [ ] All architect-remediation call sites (155, 217, 392) use the substage
      API with matched begin/end; no dangling calls.
- [ ] `tests/test_tui_stage_wiring.sh` passes after M110-5 and M110-6 are
      removed; remaining tests are unchanged and still green.
- [ ] Existing review cycle counting, rework budget tracking, and architect
      remediation retry logic behave identically — M116 changes TUI plumbing
      only, not control flow.
- [ ] Shellcheck clean for `stages/review.sh`, `stages/architect.sh`,
      `lib/tui_ops.sh`.

## Non-Goals

- Changing rework retry limits, review cycle caps, or architect remediation
  retry thresholds.
- Renaming `rework` or `architect-remediation` labels.
- Adjusting the policy records in `lib/pipeline_order_policy.sh`.
- Recent Events attribution prefixing (M117).
- Preflight/intake timing fix (M118).
