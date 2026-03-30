## Planned Tests
- [x] `tests/test_drain_pending_inbox.sh` — drain_pending_inbox() behavior: absent inbox, empty inbox, note processing, task/milestone skip, malformed notes, multi-note, tag preservation
- [x] `tests/test_notes_migrate_no_heading.sh` — migrate_legacy_notes() no-heading edge case: data preserved, v2 marker added, IDs assigned, backup created, idempotent, with-heading placement, absent file, no-notes file
- [x] `tests/test_notes_rollback.sh` — snapshot_note_states() and restore_note_states(): absent file, three-state capture, notes without IDs, restore reset, mid-run note preservation, empty snapshot, roundtrip

## Test Run Results
Passed: 222  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_drain_pending_inbox.sh`
- [x] `tests/test_notes_migrate_no_heading.sh`
- [x] `tests/test_notes_rollback.sh`
