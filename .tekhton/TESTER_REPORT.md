## Planned Tests
- [x] `cmd/tekhton/gate_test.go` — completionGateFromEnv M92/M105/M86 assembler coverage (5 new unit tests)
- [x] `tests/test_gates_parity.sh` — parity scenarios 9–11: M92 flag-read, M86 no-status branch, M105 dedup-nil doc
- [x] `internal/gates/ui_test.go` — add TestUIPhase_RemediationRetryAllFail: 3-run path where Remediator fires, remediation rerun fails, generic retry also fails → terminal failure with 3 runner.calls and failure artifacts written

## Test Run Results
Passed: internal/gates PASS, cmd/tekhton PASS (all 26 Go packages PASS)  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `cmd/tekhton/gate_test.go`
- [x] `tests/test_gates_parity.sh`
- [x] `internal/gates/ui_test.go`
