## Planned Tests
- [x] `tests/test_checkpoint_rollback_safety.sh` — rollback_last_run safety check: rejects when current_head != commit_sha and other edge cases
- [x] `tests/test_checkpoint_age_display.sh` — show_checkpoint_info age calculation degrades to "unknown" when date -d unavailable (BSD/macOS)

## Test Run Results
Passed: 13  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_checkpoint_rollback_safety.sh`
- [x] `tests/test_checkpoint_age_display.sh`
