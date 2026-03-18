# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-18 | "Continue Implementing Milestone 11: Pre-Flight Milestone Sizing And Null-Run Auto-Split"] `stages/coder.sh` integration paths (pre-flight gate, null-run auto-split with re-scout, turn-limit minimal-output path) have no test coverage in `tests/test_milestone_split.sh` — only the library functions are tested. The coder stage wiring is the highest-risk code and would benefit from integration-style tests that stub `run_agent`, `split_milestone`, and `init_milestone_state`.
- [ ] [2026-03-18 | "Continue Implementing Milestone 11: Pre-Flight Milestone Sizing And Null-Run Auto-Split"] `_replace_milestone_block` (milestone_archival.sh) always returns 0, including when the milestone heading is not matched in CLAUDE.md. The caller (`split_milestone`) validates the block exists first via `_extract_milestone_block`, so it's safe, but the silent non-error from `_replace_milestone_block` is a latent footgun if it's reused elsewhere. Consider returning 1 when in_block never fires.
- [ ] [2026-03-18 | "Continue Implementing Milestone 11: Pre-Flight Milestone Sizing And Null-Run Auto-Split"] Lazy sourcing of `plan.sh` inside `split_milestone()` (lines 130–138) is necessary given `plan.sh` is not loaded in the normal execution path, but this is an unusual pattern in the codebase. A comment explaining WHY this is lazy (not available via `tekhton.sh` normal flow) would prevent future developers from moving it eagerly.
- [ ] [2026-03-18 | "Continue Implementing Milestone 11: Pre-Flight Milestone Sizing And Null-Run Auto-Split"] The export of `MILESTONE_DEFINITION`, `SCOUT_ESTIMATE`, `TURN_CAP`, `PRIOR_RUN_HISTORY` inside `split_milestone()` adds these to the process environment for all child processes. These variables contain potentially large strings (full milestone definitions). This follows the established project pattern but contributes to environment bloat in milestone-mode runs.
- [ ] [2026-03-18 | "Implement Milestone 11: Pre-Flight Milestone Sizing And Null-Run Auto-Split"] `lib/milestone_archival.sh` is still not listed under "Files Modified" in CODER_SUMMARY.md despite being modified in this cycle (git status confirms it changed). This is the third cycle in a row with this omission. Not a correctness issue, but makes change tracking difficult.
- [ ] [2026-03-18 | "Implement Milestone 11: Pre-Flight Milestone Sizing And Null-Run Auto-Split"] Em-dash (`—`, U+2014) in regex character classes (`[:.��-]`) remains unaddressed in `milestone_archival.sh` at lines 34, 79, 99, 161, and 223 — portability concern noted in Cycle 1. Still non-blocking, but now a persistent observation across three cycles.
(none)

## Resolved
- [x] [2026-03-17] Coder scope drift — audited all items instead of task-specified quantity. Resolved by adding scope-adherence directive to `prompts/coder.prompt.md` and softening the "address what you can" language in `stages/coder.sh` non-blocking injection to defer to task scope.
- [x] [2026-03-17] (consolidated) `milestones.sh` exceeded the 300-line guideline. Resolved by extracting acceptance checking, commit signatures, and auto-advance helpers into `lib/milestone_ops.sh`. `milestones.sh` is now ~312 lines, `milestone_ops.sh` ~260 lines.
- [x] [2026-03-17] Three duplicate "milestones.sh too long" entries consolidated into a single resolved entry above.
