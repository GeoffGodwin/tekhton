## Planned Tests
- [x] `tests/test_semver_lt.sh` — _semver_lt() edge cases: equal versions, major-only bump, single-digit vs double-digit minor
- [x] `tests/test_update_check_disabled.sh` — check_for_updates respects TEKHTON_UPDATE_CHECK=false (no network, returns 1)
- [x] `tests/test_pin_version_validation.sh` — TEKHTON_PIN_VERSION semver validation: invalid value → warning + reset to empty

## Test Run Results
Passed: 24  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_semver_lt.sh`
- [x] `tests/test_update_check_disabled.sh`
- [x] `tests/test_pin_version_validation.sh`
