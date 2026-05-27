## Planned Tests
- [x] `tests/test_audit_bash_env_coverage.sh` — binary-absent fallback path + inline single-quoted false-positive regression guard
- [x] `tests/testdata/audit_bash_env/07-single-quoted.sh` — fixture: inline `'${MILESTONE_MODE}'` (known false positive)
- [x] `tests/test_m27_sweep_regression.sh` — m27.2 regression guard: audit-bash-env exits clean on full repo, inventory deleted, _strip_m27_defaults filter correct

## Test Run Results
Passed: 490  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_audit_bash_env_coverage.sh`
- [x] `tests/testdata/audit_bash_env/07-single-quoted.sh`
- [x] `tests/test_m27_sweep_regression.sh`
