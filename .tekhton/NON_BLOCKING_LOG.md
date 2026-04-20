# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [x] [2026-04-20 | "M106"] `lib/agent_spinner.sh` and `tools/tui_render_logo.py` are new files not listed in CLAUDE.md's repository layout section or in the architecture description of `lib/agent.sh`. Both should be added so the layout stays accurate.
- [ ] [2026-04-20 | "M106"] `get_stage_display_label`'s `*` fallback uses underscore-to-hyphen replacement (`${1//_/-}`) while `get_display_stage_order`'s `*` case passes internal names unmodified. A future stage added only to the pipeline order will produce different labels from each function until explicitly mapped in both.

## Resolved
