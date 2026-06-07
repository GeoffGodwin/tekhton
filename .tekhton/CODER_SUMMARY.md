# Coder Summary

## Status: COMPLETE

## What Was Implemented

Milestone **m46 — Replan Detector Body-Grep + Auto-Advance Commit-Skip Cascade**.
Two narrow fixes that together restore auto-advance commit cadence in the
face of the 2026-06-06 m37.2 false-positive that silently squashed ~10h of
auto-advance work (m37.2, m38.1, m38.2, m38.3) into one manual commit.

### Goal 1 — Heading-anchored `detect_replan_required`

Replaced `lib/replan_midrun.sh::detect_replan_required`'s body-grep
(`grep -qi "REPLAN_REQUIRED" "$file"`) with an awk-based heading-anchored
verdict extractor. The new logic mirrors `internal/review/parser.go::extractVerdictFromAccum`:

- Handles both `## Verdict\nVALUE` (heading + next-non-blank-line) and
  `## Verdict VALUE` (inline) shapes.
- Case-insensitive on the value (matches the Go parser's
  `strings.ToUpper` normalization).
- Body-text mentions of REPLAN_REQUIRED in `## Non-Blocking Notes`,
  `## Drift Observations`, `## Coverage Gaps`, etc., no longer trigger
  the override dialog — fixes the 2026-06-06 false-positive at its root.

### Goal 2 — Operator override clears the commit-skip sentinels

- Added `_clear_commit_skip_sentinels()` to `lib/replan_midrun.sh`. Removes
  `.tekhton/.final_check_result`, `.tekhton/.final_check_reason`, and
  `.tekhton/.commit_decision`. Idempotent (returns 0 even if no sentinels
  exist) so the dispatcher never fails on a clean state.
- Extracted the inline case dispatch from `trigger_replan` into a new
  testable `handle_replan_choice CHOICE [RATIONALE]` function. Every
  non-replan branch (`r`, `s`, `c`, `a`) now calls
  `_clear_commit_skip_sentinels` before returning — so the operator's
  intent ("ignore the false-positive verdict, proceed") implies "and
  clear the sentinel that the false-positive set."
- Added two new `warn` calls in `lib/finalize_commit.sh::_hook_commit`
  — one at each silent-skip site (`exit_code != 0` branch and
  FINAL_CHECK_RESULT-non-zero branch). Both warns contain the literals
  `_hook_commit` and `skip` so the next failure of this shape surfaces
  in operator-visible log output rather than taking ~10h to notice.

### Goal 3 — Regression guards

- **`tests/test_replan_detector_verdict_only.sh`** (new, 218 lines): Seven
  scenarios exercising the heading-anchored detector — heading-then-value,
  inline same-line, false-positive body mentions, missing verdict heading,
  lowercase verdict, APPROVED baseline, REPLAN_ENABLED=false suppression.
  Scenario 2 is the explicit regression guard for the 2026-06-06 bug.
- **`tests/test_autoadvance_commit_after_override.sh`** (new, 188 lines):
  Six scenarios driving the override-then-sentinel-clear path —
  `[c]` lowercase, `[C]` uppercase, `[s]` Split, `[a]` Abort,
  `_final_check_result_read` returning 0 after clear, and idempotent
  clear when no sentinels exist.
- **`tests/test_replan_detect.sh`** (modified, one scenario): flipped the
  "REPLAN_REQUIRED in body should trigger" greedy-match scenario to
  assert the opposite — the new heading-anchored detector ignores body
  mentions.

## Root Cause (bugs only)

**Bug 1 — Body-grep false-positive.** `lib/replan_midrun.sh:22`'s
`grep -qi "REPLAN_REQUIRED" "$report_file"` was a case-insensitive
substring search against the full report body. The 2026-06-06 m37.2
reviewer report had verdict `APPROVED_WITH_NOTES` but mentioned
`REPLAN_REQUIRED` three times in `## Non-Blocking Notes` (the reviewer
was discussing the replan handler implementation). Substring-only match
collapsed verdict-declaration semantics into body-mention semantics,
falsely tripping the override dialog.

**Bug 2 — Commit-skip sentinel survives operator override.** The dialog
trigger upstream of `trigger_replan` wrote `1` to
`.tekhton/.final_check_result`. The operator's `[c] Continue` was
intended to override the verdict, but the dispatcher returned 0 without
clearing the sentinel. On every subsequent auto-advance iteration,
`lib/finalize_commit.sh::_hook_commit` (line 186) read the persisted
sentinel via `_final_check_result_read`, hit `_write_commit_decision
"skipped"` at line 196, and returned 0 with no operator-visible signal.
Four full pipeline cycles ran cleanly (causal log records `pipeline_end
exit_code=0` for each), but zero commits landed — 9,139 lines of new Go
accumulated in the working tree until the operator manually squashed.

## Files Modified

- `lib/replan_midrun.sh` — replace body-grep with awk heading-anchored
  extractor; add `_clear_commit_skip_sentinels` helper; extract
  `handle_replan_choice` from `trigger_replan` and add
  `_clear_commit_skip_sentinels` call to every non-replan branch
  (`r`, `s`, `c`, `a`).
- `lib/finalize_commit.sh` — add `warn` at both `_hook_commit` skip
  sites (exit_code-nonzero branch and FINAL_CHECK_RESULT-nonzero branch).
- `tests/test_replan_detector_verdict_only.sh` (NEW) — 7-scenario
  regression guard for the heading-anchored detector.
- `tests/test_autoadvance_commit_after_override.sh` (NEW) — 6-scenario
  guard for the operator-override sentinel-clear path.
- `tests/test_replan_detect.sh` — flipped the body-text scenario to
  match the new heading-anchored semantics (one scenario inverted; the
  other 20 scenarios still pass unchanged).

## Docs Updated

None — no public-surface changes in this task. `_clear_commit_skip_sentinels`,
`handle_replan_choice`, and `detect_replan_required` are all internal
bash helpers; the operator-facing CLI surface is unchanged. The behavioral
fix (false-positive replan dialogs no longer surface, commit-skip cascade
no longer happens) is the user-observable change but is not a documented
contract.

## Human Notes Status

No actionable human notes were attached to this task. The CLARIFICATIONS.md
content shown in the run context contains only stale clarification
sessions from prior unrelated runs (Watchtower dashboard, NON_BLOCKING_LOG,
brownfield --init flow) that the human had self-answered with restatements
of the questions. None applied to m46.
