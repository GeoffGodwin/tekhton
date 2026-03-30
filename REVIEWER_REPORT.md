# Reviewer Report — M40: Human Notes Core Rewrite

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `notes_core.sh` is 399 lines — 33% over the 300-line soft ceiling. Code is correct and well-organized. Log for a future extract (rollback functions are the natural split point).
- `_hook_resolve_notes` in `finalize.sh` retains `HUMAN_MODE` branching despite the M40 spec (m40-notes-core-rewrite.md:219) stating the goal is "no HUMAN_MODE branch". The implementation is correct — the branch handles the CURRENT_NOTE_ID / CURRENT_NOTE_LINE legacy edge case — but it diverges from the spec's stated simplification. The bulk CLAIMED_NOTE_IDS path below it handles the same case correctly now that `claim_single_note()` registers the ID. Consider removing the branch in a follow-up.
- `extract_human_notes()` in `notes.sh` strips the checkbox prefix but not the HTML comment metadata (`<!-- note:nNN created:... -->`). Post-M40, all notes carry this comment, so agents receiving `HUMAN_NOTES_BLOCK` will see note IDs and creation dates in their prompts. Since resolution is now exit-code-based (agents no longer report note outcomes), this metadata is unintentional clutter. A `sed 's/ <!-- note:.*-->//'` pipe in `extract_human_notes()` would clean it up.
- `emit_dashboard_notes()` in `dashboard_emitters.sh` omits the `description` field from the TK_NOTES JSON output despite the milestone spec example (m40-notes-core-rewrite.md:204) showing it. Description lines (indented `>` blocks) are not collected by the emitter. The Notes tab table spec doesn't include a description column so this doesn't affect M40's stated UI, but M41 extends this emitter and will need descriptions. Worth pre-wiring now.

## Coverage Gaps
- Three test files are present on disk as untracked files (`tests/test_drain_pending_inbox.sh`, `tests/test_notes_migrate_no_heading.sh`, `tests/test_notes_rollback.sh`) but are not listed under "Files Modified" in CODER_SUMMARY.md. If they are M40 deliverables (which they appear to be — they test scope items 5, 4, and 6 respectively), they should be staged and listed. If not ready, they should be removed to avoid confusion in future runs.

## ACP Verdicts
None

## Drift Observations
- `notes.sh:claim_human_notes` (line 67) archives HUMAN_NOTES.md to `${LOG_DIR}/${TIMESTAMP}_HUMAN_NOTES.md` immediately before calling `claim_notes_batch()`, which performs the identical `cp` to the same destination internally (notes_core.sh:277-279). The double archive is harmless but dead — the first copy is always overwritten by the second. The archive logic should live exclusively in `claim_notes_batch()` and the duplicate `cp` in `claim_human_notes()` should be removed.
