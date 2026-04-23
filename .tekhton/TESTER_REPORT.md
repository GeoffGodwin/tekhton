## Planned Tests
- [x] `tests/test_quota_sleep_chunked.sh` — _quota_sleep_chunked chunk math: correct loop count, tui_update_pause calls, edge cases (zero total, invalid chunk, absent helper)
- [x] `tests/test_agent_retry_pause.sh` — _retry_pause_spinner_around_quota: happy path (namrefs updated), failure path (no resume), absent spinner module; _pause_agent_spinner with live/empty PIDs

## Test Run Results
Passed: 27  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_quota_sleep_chunked.sh`
- [x] `tests/test_agent_retry_pause.sh`
