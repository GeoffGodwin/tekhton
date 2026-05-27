## Planned Tests
- [x] `tests/test_audit_bash_env_coverage.sh` — binary-absent fallback path + inline single-quoted false-positive regression guard
- [x] `tests/testdata/audit_bash_env/07-single-quoted.sh` — fixture: inline `'${MILESTONE_MODE}'` (known false positive)
- [x] `tests/test_m27_sweep_regression.sh` — m27.2 regression guard: audit-bash-env exits clean on full repo, inventory deleted, _strip_m27_defaults filter correct
- [x] m27.3 AC verification — parity test, fixture config validation, shellcheck gate, docs, VERSION, wedge-audit, full test suite

## Test Run Results
Passed: 491  Failed: 0

## Bugs Found
- BUG: [scripts/wedge-audit.sh:295] `# shellcheck source=scripts/wedge-audit-companions.sh` directive does not suppress SC1091 — `shellcheck tests/test_stage_env_setu.sh scripts/wedge-audit.sh` exits 1 (AC requires exit 0). Fix: change `# shellcheck source=scripts/wedge-audit-companions.sh` to `# shellcheck source=wedge-audit-companions.sh` (path must be relative to the script's own directory, not the repo root), or add `# shellcheck disable=SC1091` to the source line.

## Files Modified
- [x] `tests/test_audit_bash_env_coverage.sh`
- [x] `tests/testdata/audit_bash_env/07-single-quoted.sh`
- [x] `tests/test_m27_sweep_regression.sh`
