## Planned Tests
- [x] `internal/diagnose/engine_readers_test.go` — table-driven coverage of private JSON readers (extractJSONString, extractJSONInt, parseCauseBlock, extractKVLine) for malformed input, missing keys, and multi-value nested objects
- [x] `cmd/tekhton/diagnose_test.go` — CLI test materializing a populated LAST_FAILURE_CONTEXT.json fixture and driving `tekhton diagnose run --project-dir` through cmd.Execute()
- [x] `internal/diagnose/rules/resilience_test.go` — add source 2 (PREFLIGHT_REPORT.md header + fail word) and source 3a (PrimarySignal match) to TestPreflightInteractiveConfig_Match

## Test Run Results
Passed: all 29 Go packages PASS  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/diagnose/engine_readers_test.go`
- [x] `cmd/tekhton/diagnose_test.go`
- [x] `internal/diagnose/rules/resilience_test.go`
