# Reviewer Report — Milestone 4: Mid-Run Clarification And Replanning (Cycle 2)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `prompts/clarification.prompt.md` (carry-over from cycle 1): file exists and was created as part of this milestone, but `render_prompt "clarification"` is never called anywhere in the codebase. The post-clarification coder re-run uses `render_prompt "coder"` which already has the `{{IF:CLARIFICATIONS_CONTENT}}` block. Either remove the file or add a header comment explaining when it is intended to be used.
- `lib/replan.sh` is 294 lines — just within the 300-line limit. If `_apply_replan_delta` grows with future multi-file merge logic, it will breach the cap. Worth noting for future milestones.

## Coverage Gaps
- No tests for `detect_clarifications()` (blocking vs non-blocking parse, empty section, missing file)
- No tests for `handle_clarifications()` (user input flow, abort path, CLARIFICATIONS.md write format)
- No tests for `detect_replan_required()` and `trigger_replan()` menu routing
- No tests for post-clarification coder re-run null-run detection in `stages/coder.sh`

## ACP Verdicts
- ACP: lib/clarify.sh sourced in execution pipeline — **ACCEPT** — Milestone 4 is part of v2.0 Adaptive Pipeline, not the planning initiative. Backward compatible: zero behavioral change when no agent emits `## Clarification Required`.

## Drift Observations
- `ARCHITECTURE.md` Layer 3 library list and File Ownership table still do not include `lib/clarify.sh`, `lib/replan.sh`, or `CLARIFICATIONS.md`. Both the coder and previous review cycle noted this — it should be a follow-up task.

---

## Blocker Verification

**Simple Blocker 1 (300-line limit):** RESOLVED. `lib/clarify.sh` is now 181 lines. Replan functions (`detect_replan_required`, `trigger_replan`, `_run_replan`, `_apply_replan_delta`) were extracted into `lib/replan.sh` (294 lines). Both files are under the 300-line cap. `tekhton.sh` sources both at lines 264–265. Functions referenced in `stages/review.sh` (`detect_replan_required`, `trigger_replan`) resolve correctly from `lib/replan.sh`.

**Simple Blocker 2 (null run detection):** RESOLVED. `stages/coder.sh:326–338` now calls `was_null_run()` immediately after `run_agent "Coder (post-clarification)"`. A null post-clarification run saves pipeline state with reason `null_run_post_clarification` and exits with error. The stale-`CODER_SUMMARY.md` false-negative issue is fixed.
