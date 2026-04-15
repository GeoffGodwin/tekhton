# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-14 | "M87"] `tests/test_tekhton_dir_root_cleanliness.sh` hardcodes the literal string `.tekhton/` in its pattern check rather than using a dynamic `${TEKHTON_DIR}` reference. If TEKHTON_DIR is ever changed to a non-default value, the test would produce false failures. Low probability in practice, but the fragility is worth noting.
- [ ] [2026-04-14 | "M87"] CODER_SUMMARY.md was deleted (old M86 content) but not regenerated for M87. The review proceeded from git diff and the milestone spec. Not a code defect, but the missing summary is a process gap.
- [ ] [2026-04-14 | "M87"] `tests/test_tekhton_dir_root_cleanliness.sh:62` — The `NOT_PATHS` exclusion of `POLISH_LOGIC_FILE_PATTERNS` is dead code: the variable name ends in `_PATTERNS`, not `_FILE`, so `grep '_FILE$'` never matches it. The exclusion entry does no harm but is misleading.
- [ ] [2026-04-14 | "M87"] `tests/test_tekhton_dir_root_cleanliness.sh:75` — The pass condition `[[ "$value" == .tekhton/* ]]` compares against the literal string `.tekhton/` rather than `${TEKHTON_DIR}/`. If TEKHTON_DIR is ever customized to a non-default value this would produce false negatives, but the test's intent (check defaults, not runtime config) makes this acceptable.
- [ ] [2026-04-14 | "M84"] `lib/milestone_progress.sh:159-165` — pre-existing LOW security finding (not introduced by M84): `_diagnose_recovery_command` embeds `$milestone` and `$task` verbatim into a displayed command string; double-quotes in those fields would produce a syntactically broken suggestion. No injection risk (output is echoed, not eval'd). Fix in a cleanup pass: `milestone="${milestone//"/\"}"`.
- [ ] [2026-04-13 | "M83"] `_vc_is_noop_cmd()` regex `': $'` won't match bare `:` (colon without trailing space). Minor edge case unlikely to bite in practice. Carried from cycle 1.
- [ ] [2026-04-13 | "M82"] `_render_progress_bar` (milestone_progress_helpers.sh:176–180) still forks a subshell for every bar character — 40+ forks per render. Correct, low priority given display-only context; a `printf -v` approach would be faster.

## Resolved
