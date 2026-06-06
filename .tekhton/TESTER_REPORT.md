## Planned Tests
- [ ] `internal/gates/completion_test.go` — verify 6 new m45 test cases (grace-period cancel, retry happy-path, retry both-fail, retry-delay cancel, retry-disabled, retry-skipped-with-baseline)
- [ ] `tests/test_completion_gate_retry.sh` — verify shim-boundary integration: flake-then-pass emits causal event, both-fail halts with no event

## Test Run Results
Passed: 0  Failed: 0

## Bugs Found
None

## Files Modified
- [ ] `internal/gates/completion_test.go`
- [ ] `tests/test_completion_gate_retry.sh`
