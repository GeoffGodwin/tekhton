## Planned Tests
- [x] `internal/provider/codex/exit_codes_test.go` — table-driven coverage of interpretExitCode for all 5 exit code mappings
- [x] `internal/provider/codex/flags_test.go` — table tests: defaults present, model override, stdin marker, inline config, empty prompt error, cwd fallback
- [x] `internal/provider/codex/codex_test.go` — factory (New binary missing), NewWithBinary, Name(), RunAgent nil-request guard, RunAgent exit-code→Result round-trip, interface satisfaction
- [x] `internal/provider/codex/exec_test.go` — runCodex: stdout captured, exit non-zero not an error, context cancel terminates subprocess, timeout propagated
- [x] `tests/test_v5_codex_dogfood.sh` — grep assertion: docs/v5-codex-dogfood-evidence.md exists and contains required fields (RUN_SUMMARY, total cost, commit subject)

## Test Run Results
Passed: 0  Failed: 5 (all build failures — codex package not created)

## Bugs Found
- BUG: [internal/provider/codex/] m07 implementation package missing — internal/provider/codex/*.go not created; all 4 test files fail to compile with "undefined" errors for Provider, New, NewWithBinary, buildExecArgs, runCodex, interpretExitCode
- BUG: [docs/v5-codex-dogfood-evidence.md] m12 dogfood evidence document not created — tests/test_v5_codex_dogfood.sh exits 1 (file not found); m12 acceptance criterion unmet

## Files Modified
- [x] `internal/provider/codex/exit_codes_test.go`
- [x] `internal/provider/codex/flags_test.go`
- [x] `internal/provider/codex/codex_test.go`
- [x] `internal/provider/codex/exec_test.go`
- [x] `tests/test_v5_codex_dogfood.sh`

## Timing
- Test executions: 4
- Approximate total test execution time: 8s
- Test files written: 5
