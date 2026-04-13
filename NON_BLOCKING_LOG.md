# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in ${REVIEWER_REPORT_FILE}.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-13 | "M80"] `prompts/draft_milestones.prompt.md:34-35` — Empty `{{IF:DRAFT_SEED_DESCRIPTION}}...{{ENDIF:DRAFT_SEED_DESCRIPTION}}` block is still present (dead code, likely a copy-paste residue). Remove for clarity.
- [ ] [2026-04-13 | "M80"] `lib/draft_milestones.sh:87` — `head -"$count"` where `$count` comes from `DRAFT_MILESTONES_SEED_EXEMPLARS`. `_clamp_config_value` enforces an upper bound but does not enforce the value is an integer. A non-integer config value passes through to `head` as a malformed flag. Add `[[ "$count" =~ ^[0-9]+$ ]] || count=3` before the pipeline.
- [x] [2026-04-13 | "M80"] `tests/test_draft_milestones_next_id.sh:33` — `source ... 2>/dev/null || true` silently suppresses errors when loading `draft_milestones.sh`. A syntax error in that file would produce confusing "command not found" failures downstream. Remove the suppression so source errors surface clearly.
<!-- Items added here by the pipeline. Mark [x] when addressed. -->

## Resolved
