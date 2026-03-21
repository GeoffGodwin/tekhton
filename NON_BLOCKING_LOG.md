# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-21 | "Implement Milestone 21: Agent-Assisted Project Synthesis"] `stages/init_synthesize.sh:256` — `section_name="${section_name### }"` is still a no-op (carry-over from prior report, not a regression). The `sed 's/^## //'` in the process substitution already strips the prefix before the loop reads it. Safe to remove.
- [ ] [2026-03-21 | "Implement Milestone 21: Agent-Assisted Project Synthesis"] `stages/init_synthesize.sh:247` — Thin section detection only fires when `section_count < 5`. A document with 6+ sections but several thin ones passes as "completeness OK" without inspecting individual section depth. The `PLAN_INCOMPLETE_SECTIONS` logic is unreachable for any document that reaches the minimum section count. Low risk today; worth revisiting if synthesis quality proves inconsistent.

## Resolved
