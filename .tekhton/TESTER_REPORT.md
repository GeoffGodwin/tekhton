## Planned Tests
- [x] `tests/test_state_writer_resume_fields.sh` — bash fallback + Go-path writer emit milestone_id from env chain (m40.2 Scenarios C and D; 14 assertions total covering C1/C2/C3 and D1/D2/D3)
- [x] `internal/runner/resume_test.go` — fixture-driven round-trip: milestone_id present → RunModeMilestone; absent → fallback to task/resume mode (TestRequestFromSnapshotMilestoneIDFixture + TestRequestFromSnapshotMilestoneIDAbsentFallsThrough)

## Test Run Results
Passed: 2  Failed: 0

Full suite: Shell 1/1 targeted passed; `go test ./internal/runner/...` all passed; full `bash tests/run_tests.sh` shell+Go clean.

## Bugs Found
None

## Files Modified
- [x] `tests/test_state_writer_resume_fields.sh`
- [x] `internal/runner/resume_test.go`
