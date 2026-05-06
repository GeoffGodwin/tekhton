## Planned Tests
- [x] `cmd/tekhton/manifest_test.go` — add missing-path tests for get/set-status/frontier commands (3 uncovered branches)

## Test Run Results
Passed: 3  Failed: 0

Full suite (bash tests/run_tests.sh): 495 shell passed, 0 failed; Python PASSED; all 8 Go packages ok.

Coverage: `internal/manifest` 88.0% (target ≥80% ✓); `cmd/tekhton` manifest.go functions 88–100% per function.

Parity check: `scripts/manifest-parity-check.sh` — all 6 fixtures + comment round-trip + atomicity gate PASS.

## Bugs Found
None

## Files Modified
- [x] `cmd/tekhton/manifest_test.go`
