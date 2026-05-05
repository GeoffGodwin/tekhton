## Planned Tests
- [x] `cmd/tekhton/state_test.go` — Go unit tests: applyField reflection, lookupField, parseFieldPairs, resolveStatePath, state write subcommand stdin→file, state read exit-code mapping
- [x] `tests/test_state_cli_exit_codes.sh` — Bash test driving tekhton CLI: exit 1 for missing file, exit 2 for corrupt file, exit 0 for valid read

## Test Run Results
Passed: 500  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `cmd/tekhton/state_test.go`
- [x] `tests/test_state_cli_exit_codes.sh`
