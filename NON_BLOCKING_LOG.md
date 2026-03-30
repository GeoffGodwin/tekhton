# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-30 | "M40"] `notes_core.sh` is 399 lines — 33% over the 300-line soft ceiling. Code is correct and well-organized. Log for a future extract (rollback functions are the natural split point).
- [ ] [2026-03-30 | "M40"] `_hook_resolve_notes` in `finalize.sh` retains `HUMAN_MODE` branching despite the M40 spec (m40-notes-core-rewrite.md:219) stating the goal is "no HUMAN_MODE branch". The implementation is correct — the branch handles the CURRENT_NOTE_ID / CURRENT_NOTE_LINE legacy edge case — but it diverges from the spec's stated simplification. The bulk CLAIMED_NOTE_IDS path below it handles the same case correctly now that `claim_single_note()` registers the ID. Consider removing the branch in a follow-up.
- [ ] [2026-03-30 | "M40"] `extract_human_notes()` in `notes.sh` strips the checkbox prefix but not the HTML comment metadata (`<!-- note:nNN created:... -->`). Post-M40, all notes carry this comment, so agents receiving `HUMAN_NOTES_BLOCK` will see note IDs and creation dates in their prompts. Since resolution is now exit-code-based (agents no longer report note outcomes), this metadata is unintentional clutter. A `sed 's/ <!-- note:.*-->//'` pipe in `extract_human_notes()` would clean it up.
- [ ] [2026-03-30 | "M40"] `emit_dashboard_notes()` in `dashboard_emitters.sh` omits the `description` field from the TK_NOTES JSON output despite the milestone spec example (m40-notes-core-rewrite.md:204) showing it. Description lines (indented `>` blocks) are not collected by the emitter. The Notes tab table spec doesn't include a description column so this doesn't affect M40's stated UI, but M41 extends this emitter and will need descriptions. Worth pre-wiring now.
(none)

## Resolved
