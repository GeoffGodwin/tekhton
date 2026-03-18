# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
## Resolved
- [x] [2026-03-18] `split_milestone()` in `lib/milestone_split.sh` — changed `export` to plain shell variable assignment for `MILESTONE_DEFINITION`, `SCOUT_ESTIMATE`, `TURN_CAP`, `PRIOR_RUN_HISTORY`. `render_prompt()` reads these via `${!var_name}` indirect expansion in the same shell scope, so export was unnecessary environment bloat.
- [x] [2026-03-18] `lib/milestone_archival.sh` now explicitly listed in CODER_SUMMARY.md Files Modified section. Process tracking issue resolved.
- [x] [2026-03-18] Em-dash (U+2014) removed from all 5 regex character classes in `lib/milestone_archival.sh` (lines 35, 80, 101, 163, 225). Replaced `([:.\ -]|—)` with portable `[^[:alnum:]]` which matches any non-alphanumeric delimiter.
- [x] [2026-03-18] Recursion depth log line added to null-run auto-split path in `stages/coder.sh` at lines 348-350 and 470-473: `warn "Auto-split complete — re-running coder stage for milestone ... (depth N/M)..."`.
- [x] [2026-03-18] Comment added to `_switch_to_sub_milestone` in `stages/coder.sh` lines 21-22 explaining `get_milestone_title` fallback behavior when split agent uses a non-matching heading format.
- [x] [2026-03-18] `MILESTONE_SPLIT_MAX_TURNS` hard cap of 50 documented in `templates/pipeline.conf.example` line 285: "Hard cap: 50 (values above 50 are clamped automatically)".
- [x] [2026-03-18] Integration tests added to `tests/test_milestone_split.sh` covering 3 coder stage wiring paths: pre-flight sizing gate (split + re-scout), null-run auto-split (handle_null_run_split + recursive coder), and turn-limit minimal-output auto-split. Tests stub `run_agent`, `split_milestone`, `init_milestone_state`, and verify call sequences.
- [x] [2026-03-18] `lib/milestone_split.sh:42` — Split `local threshold=$((...))` into separate declaration and assignment to avoid SC2155.
- [x] [2026-03-18] `lib/milestone_archival.sh:250` — Dead `local awk_rc=$?` code path already resolved in prior run: `_replace_milestone_block` now uses `|| { rm -f ...; return 1; }` pattern which catches awk failure before `set -e` fires.
- [x] [2026-03-18] `lib/milestone_archival.sh:252` — `$rep_file` cleanup already resolved in prior run: the `|| { }` block now cleans up both `$tmp_file` and `$rep_file` on awk failure.
- [x] [2026-03-18] `handle_null_run_split()` `git diff HEAD` comment already present in prior run at lines 233-237 explaining intentional use of `git diff HEAD` vs bare `git diff`.
- [x] [2026-03-17] Coder scope drift — audited all items instead of task-specified quantity. Resolved by adding scope-adherence directive to `prompts/coder.prompt.md` and softening the "address what you can" language in `stages/coder.sh` non-blocking injection to defer to task scope.
- [x] [2026-03-17] (consolidated) `milestones.sh` exceeded the 300-line guideline. Resolved by extracting acceptance checking, commit signatures, and auto-advance helpers into `lib/milestone_ops.sh`. `milestones.sh` is now ~312 lines, `milestone_ops.sh` ~260 lines.
- [x] [2026-03-17] Three duplicate "milestones.sh too long" entries consolidated into a single resolved entry above.
