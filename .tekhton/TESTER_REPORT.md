## Planned Tests
- [x] `tests/test_causal_log.sh` — add `causal status` direct-invocation section (Go binary path + bash fallback path)
- [x] `cmd/tekhton/causal_test.go` — Go unit tests for `newCausalInitCmd` (creates dirs, no-truncate, missing-path error); run via `go test ./cmd/tekhton/...` (Go toolchain not in this sandbox)

## Test Run Results
Passed: 499  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_causal_log.sh`
- [x] `cmd/tekhton/causal_test.go`
