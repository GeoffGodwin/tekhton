# Reviewer Report — M121

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/validate_config.sh:138` — comment reads "Check 6: DESIGN_FILE exists on disk" but is now logically check 7 since 6a and 6b were inserted immediately before it; the numbering is misleading but not functional.
- `lib/replan_brownfield.sh` — 347 lines, 47 over the 300-line ceiling; pre-existing before M121 and correctly called out in CODER_SUMMARY as out-of-scope to split here.
- `stages/plan_generate.sh:123` — write to `CLAUDE.md` (`printf '%s\n' "$claude_md_content" > "$claude_md"`) is unchecked; intentionally out of scope for M121 (only `DESIGN_FILE` write path was in spec), but a future hardening opportunity analogous to what was done in `plan_interview.sh`.

## Coverage Gaps
- None

## Drift Observations
- `lib/milestone_split_dag.sh:81` — pre-existing: the `*/*` path-traversal guard does not explicitly reject the degenerate `..` case (no slash); OS-level safety means no actual traversal is possible, but the defensive intent would be cleaner with an explicit `|| [[ "$sub_file" == ".." ]]`. Not introduced by M121 — surfaces here from the security agent's low-severity finding.
