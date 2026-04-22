# Coder Summary

## Status: COMPLETE

## What Was Implemented

M116 — Migrating rework + architect-remediation onto the M113 substage API,
then deleting the `tui_stage_transition` helper and its M110 wiring tests.

- **Rework migration (`stages/review.sh`).** Both rework call sites (the
  complex-blocker branch and the simple-blocker branch) now open rework via
  `tui_substage_begin "rework" "$model"` and close it via
  `tui_substage_end "rework" ""`. The enclosing review `tui_stage_begin`/end
  pair is untouched, so review remains the sole pipeline-stage lifecycle
  owner for each review cycle. Rework is now a breadcrumb, not a timeline
  entry — no more `rework` entries in `stages_complete`.
- **Architect-remediation migration (`stages/architect.sh`).** Replaced the
  `tui_stage_transition "architect" "architect-remediation"` call with
  `tui_substage_begin "architect-remediation" "$architect_model"`. The
  architect stage now stays open for the entire audit: it is opened once at
  the top, closed once at the bottom, and architect-remediation is a
  substage that records as a breadcrumb inside it. The BUILD_BROKEN early
  return now closes the substage first (with a verdict) and then also closes
  the enclosing architect stage — previously the transition had already
  closed architect, so only the substage needed closing; now architect is
  the open pipeline stage and must be closed on that path too.
- **`tui_stage_transition` deletion (`lib/tui_ops.sh`).** Removed the
  function entirely after all callers migrated (scout in M114, run_op in
  M115, rework + architect-remediation in M116). `grep -rn
  tui_stage_transition lib/ stages/ tests/ tekhton.sh` returns empty. The
  historical milestone docs under `.claude/milestones/` still reference the
  name, which is permitted by the acceptance criteria.
- **M110-5 and M110-6 test deletion (`tests/test_tui_stage_wiring.sh`).**
  Removed the two tests that directly exercised `tui_stage_transition`.
  Every other test in the file (lifecycle-id allocation, stage_begin/end
  invariants, rework cycle counting, out_reset_pass, ring-buffer event
  typing, intake-at-end regression guard) continues to pass.

## Root Cause (bugs only)

N/A — refactor milestone, not a bug fix.

## Files Modified

| File | Change |
|------|--------|
| `stages/review.sh` | Two `tui_stage_begin/end "rework"` pairs → `tui_substage_begin/end "rework"`. |
| `stages/architect.sh` | `tui_stage_transition "architect" "architect-remediation"` → `tui_substage_begin "architect-remediation"`; BUILD_BROKEN early return now closes substage + architect stage (instead of only architect-remediation); end-of-function close now clears substage first, then architect. |
| `lib/tui_ops.sh` | Removed `tui_stage_transition` function (lines ~239–297 in pre-M116). |
| `tests/test_tui_stage_wiring.sh` | Removed Tests M110-5 and M110-6 (the two that called `tui_stage_transition` directly). |
| `.tekhton/CODER_SUMMARY.md` | This file. |

## Acceptance Criteria Self-Check

- [x] `tui_stage_transition` absent from all `.sh` files under `lib/`,
      `stages/`, `tekhton.sh`, and `tests/` (milestone docs under
      `.claude/milestones/` retain historical references, permitted by AC).
- [x] Rework in review: `tui_substage_begin/end` pair per cycle; no pill
      allocation; no `rework` record in `stages_complete` (the policy in
      `pipeline_order_policy.sh` already declared rework as `sub|no|yes|yes|review`
      — this now flows through the substage API that doesn't touch
      `_TUI_STAGES_COMPLETE`).
- [x] Architect-remediation: one architect `tui_stage_begin/end` pair owns
      the pipeline-stage lifecycle; remediation flows through
      `tui_substage_begin/end` and does not append to `stages_complete`.
- [x] All three architect-remediation call sites (formerly at lines 151,
      155/217, 392) now use the substage API with matched begin/end.
- [x] `tests/test_tui_stage_wiring.sh` passes after M110-5 and M110-6 removal
      (49 passed / 0 failed when run standalone).
- [x] Shellcheck clean: `stages/review.sh`, `stages/architect.sh`,
      `lib/tui_ops.sh` all produce zero warnings. (Pre-existing SC2034
      warnings in `tests/test_tui_stage_wiring.sh` are unchanged; they were
      already on HEAD before M116 and are out of scope.)
- [x] Non-goals respected: no changes to rework retry limits, review cycle
      caps, architect retry thresholds, label names, or
      `pipeline_order_policy.sh` records.

## Human Notes Status

No unchecked human notes passed to this run.
