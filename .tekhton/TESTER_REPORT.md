## Planned Tests
- [x] `internal/stages/cleanup/full_flow_test.go` — full agent-success path: report parsed, notes mutated [x]/[DEFERRED], document saved to disk, verdict=pass
- [x] `internal/stages/cleanup/full_flow_test.go` — subprocessBuildGate.Run: binary not found returns nil
- [x] `internal/stages/cleanup/full_flow_test.go` — subprocessBuildGate.Run: binary found, exits 0 → nil error
- [x] `internal/stages/cleanup/full_flow_test.go` — subprocessBuildGate.Run: binary found, exits 1 → non-nil error

## Test Run Results
Passed: 505 (501 shell + 4 new Go)  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/stages/cleanup/full_flow_test.go`
