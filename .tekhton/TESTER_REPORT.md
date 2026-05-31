## Planned Tests
- [x] `internal/diagnose/engine_readers_test.go` — table-driven coverage of private JSON readers (extractJSONString, extractJSONInt, parseCauseBlock, extractKVLine) for malformed input, missing keys, and multi-value nested objects
- [x] `cmd/tekhton/diagnose_test.go` — CLI test materializing a populated LAST_FAILURE_CONTEXT.json fixture and driving `tekhton diagnose run --project-dir` through cmd.Execute()

## Test Run Results
Passed: all 27 Go packages PASS  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/diagnose/engine_readers_test.go`
- [x] `cmd/tekhton/diagnose_test.go`
