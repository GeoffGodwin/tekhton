## Planned Tests
- [x] `tests/test_quota_roundtrip.sh` — enter_quota_pause timeout path, mock-claude success round trip, and _ORCH_ATTEMPT reset-on-success

## Test Run Results
Passed: 17  Failed: 0

## Bugs Found
- BUG: [tests/test_milestone_split.sh:409] `MILESTONE_MAX_SPLIT_DEPTH=3` set at line 176 is inherited by the config-defaults subshell at line 392; the `:=6` default in config_defaults.sh is never applied because the variable is already set, so the assertion "defaults to 6" always fails

## Files Modified
- [x] `tests/test_quota_roundtrip.sh`
