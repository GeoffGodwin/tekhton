# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-21 | "M112"] `stages/coder_prerun.sh:69` and `stages/tester_fix.sh:164` — new dedup skip-event guards use `command -v emit_event &>/dev/null` while every other emit_event check in both files uses `declare -f emit_event &>/dev/null`. Both succeed for bash functions but `declare -f` is canonical and is the pattern used throughout the codebase. Align for consistency.
- [ ] [2026-04-21 | "M111"] `lib/milestone_split_dag.sh:78` — Security LOW (flagged by security agent, fixable): `echo "$sub_block" > "${milestone_dir}/${sub_file}"` relies solely on `_slugify` to strip path separators. Adding `[[ "$sub_file" == */* ]] && return 1` immediately before the write makes traversal safety unconditional regardless of future changes to `_slugify`.

## Resolved
