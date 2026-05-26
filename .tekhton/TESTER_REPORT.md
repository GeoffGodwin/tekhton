## Planned Tests
- [x] `tests/test_audit_bash_env_coverage.sh` — binary-absent fallback path + inline single-quoted false-positive regression guard
- [x] `tests/testdata/audit_bash_env/07-single-quoted.sh` — fixture: inline `'${MILESTONE_MODE}'` (known false positive)

## Test Run Results
Passed: 2  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_audit_bash_env_coverage.sh`
- [x] `tests/testdata/audit_bash_env/07-single-quoted.sh`
