## Planned Tests
- [x] `tests/test_milestone_archival.sh` — archival functions: archive [DONE] milestone, idempotency, decimal milestone 0.5, _get_initiative_name detection

## Test Run Results
Passed: 37  Failed: 1

## Bugs Found
- BUG: [lib/milestones.sh:131] get_milestone_title returns empty string for decimal milestones (e.g. "0.5") because parse_milestones regex `([0-9]+)` only captures the integer part "0", so the awk lookup `$1 == "0.5"` never matches — archive_completed_milestone writes `#### [DONE] Milestone 0.5: ` with a blank title for decimal milestones

## Files Modified
- [x] `tests/test_milestone_archival.sh`
