# Coder Summary
## Status: COMPLETE

## Root Cause Analysis
`tests/run_tests.sh` `run_test()` ran each failing test **twice** in two
independent `bash "$test_file"` invocations:

1. Line 77 — silent first run inside an `if` to determine PASS/FAIL exit code.
2. Line 85 — second run, with output piped through `sed` for the debug section
   that's printed only when the first run failed.

When the first run aborts under `set -euo pipefail` for a reason that does not
recur on a clean re-run — SIGPIPE from a downstream consumer of `$(cmd | head)`,
a bare `grep` returning 1 on zero matches, a process-substitution race — the
second run can produce all-PASS output. The user then sees the runner report
`FAIL` followed by debug output that contains "Passed: N  Failed: 0", which is
both confusing and actively misleading: it makes the failure look like a runner
artifact when it is actually a real `set -e` abort in the test.

The fix captures stdout/stderr and the exit code from a **single** invocation
and only prints the captured output when the captured exit code is non-zero.
Because `output=$(...)` would otherwise trigger `set -e` in the parent on a
failing test, the failure is rerouted via `|| rc=$?`, leaving `rc=0` on success.

## What Was Implemented
- Refactored `run_test()` to invoke each test exactly once and reuse the
  captured output for the FAIL debug section.
- Added a regression test (`tests/test_run_tests_single_invocation.sh`) that
  builds a stateful fixture (counter file, exits 1 on first run and 0 on
  subsequent runs) and asserts: FAIL marker present, debug section contains
  `INVOCATION_1` (not `INVOCATION_2`), counter file ends at `1`, plus a passing
  fixture sanity check. The test fails on the pre-fix code and passes on the
  fixed code (verified by reverting and re-running).

## Files Modified
- `tests/run_tests.sh` — `run_test()` refactored to single-invocation.
- `tests/test_run_tests_single_invocation.sh` — new regression test.

## Verification
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — clean (exit 0).
- `shellcheck tests/run_tests.sh tests/test_run_tests_single_invocation.sh` —
  only pre-existing SC2155 on `run_tests.sh` line 11 (unchanged by this work).
- `bash tests/run_tests.sh` — 373 shell tests pass, 87 Python tests pass.
- Reverting the `run_tests.sh` fix and re-running the new test produces
  3 of 6 assertion failures, confirming the test exercises the fixed behavior.

## Human Notes Status
- COMPLETED: [BUG] `tests/run_tests.sh` `run_test()` runs each failing test **twice** — exit code from Run 1 (silent) determines PASS/FAIL, but the debug output shown is from an independent Run 2 (re-run). If `set -euo pipefail` aborts Run 1 early (e.g. SIGPIPE from `head -20` inside a `$()` capture, or a bare `grep` with no match), Run 2 starts clean and can produce all-PASS output, yielding a false "FAIL ... Passed: N  Failed: 0" in the log. Fix: capture output and exit code in one run — `output=$(bash "$test_file" < /dev/null 2>&1); rc=$?` — then branch on `$rc` and print `$output` only when non-zero. Remove the second `bash "$test_file"` invocation entirely. File: `tests/run_tests.sh`, function `run_test()`.
