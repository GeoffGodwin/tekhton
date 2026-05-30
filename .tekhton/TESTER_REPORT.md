## Planned Tests
- [x] `tests/test_m33_milestone_structure.sh` — verify m33 parent AC: child files exist with correct meta, depends-on rows, proto file references, package references, split status, and MANIFEST rows
- [x] `internal/dashboard/coverage_test.go` — concurrent atomicity of WriteJSFile; EmitDiagnosis available=true path; EmitTeamState errEmptyTeamID sentinel and delegation path
- [x] `internal/dashboard/parse_runs_test.go` — add zero-byte and blank-lines-only metrics.jsonl cases: os.Open succeeds, scanner yields nothing, returns nil triggering RUN_SUMMARY fallback

## Test Run Results
Passed: 35  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_m33_milestone_structure.sh`
- [x] `internal/dashboard/coverage_test.go`
- [x] `internal/dashboard/parse_runs_test.go`
