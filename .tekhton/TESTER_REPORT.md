## Planned Tests
- [x] `tests/test_diagnose_rules_resilience.sh` — T1–T12 covering all four new rules and upgraded _rule_max_turns
- [x] `tests/test_diagnose.sh` — Updated rule-count (18) and ordering assertions

## Test Run Results
Passed: 465  Failed: 0

`tests/test_diagnose_rules_resilience.sh`: 26/26 pass (all T1–T12 scenarios).
`tests/test_diagnose.sh`: 74/74 pass via harness (suites 17/19 are pre-existing
env-dependent failures when run standalone; confirmed on main before M133).
Full suite via `bash tests/run_tests.sh`: 465 shell / 247 Python — all pass.

## Bugs Found
None

## Files Modified
- [x] `tests/test_diagnose_rules_resilience.sh`
- [x] `tests/test_diagnose.sh`
