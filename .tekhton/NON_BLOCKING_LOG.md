# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-14 | "M84"] `lib/milestone_progress.sh:159-165` — pre-existing LOW security finding (not introduced by M84): `_diagnose_recovery_command` embeds `$milestone` and `$task` verbatim into a displayed command string; double-quotes in those fields would produce a syntactically broken suggestion. No injection risk (output is echoed, not eval'd). Fix in a cleanup pass: `milestone="${milestone//"/\"}"`.
- [ ] [2026-04-13 | "M83"] `_vc_is_noop_cmd()` regex `': $'` won't match bare `:` (colon without trailing space). Minor edge case unlikely to bite in practice. Carried from cycle 1.
- [ ] [2026-04-13 | "M82"] `_render_progress_bar` (milestone_progress_helpers.sh:176–180) still forks a subshell for every bar character — 40+ forks per render. Correct, low priority given display-only context; a `printf -v` approach would be faster.

## Resolved
