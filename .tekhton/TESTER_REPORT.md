# Tester Report

## Planned Tests
- [x] `tests/test_run_tests_single_invocation.sh` — Verify single-invocation fix for run_test()
- [x] `tests/test_run_tests_output_capture.sh` — Verify output and exit code are captured correctly together

## Test Run Results
Passed: 374  Failed: 0
Python: 87 Passed

## Bugs Found
None

## Files Modified
- [x] `tests/test_run_tests_single_invocation.sh`
- [x] `tests/test_run_tests_output_capture.sh`

---

## Verification Summary

The fix for the double-invocation bug in `tests/run_tests.sh` has been thoroughly tested and verified:

### Existing Regression Test (`test_run_tests_single_invocation.sh`)
The coder's regression test validates that:
- Failing tests run exactly once (counter file incremented once)
- FAIL marker is reported correctly
- Debug output comes from the actual failing run (INVOCATION_1), not a re-run
- Passing tests still work correctly in a single invocation

**Result: 6/6 assertions passed**

### New Comprehensive Test (`test_run_tests_output_capture.sh`)
Additional test coverage verifies:
1. **Multiline output** — All lines captured in single invocation
2. **Mixed stdout/stderr** — Both streams captured together
3. **Exit code 0** — Produces PASS marker
4. **Non-zero exit codes (1, 2, 5, 127)** — All produce FAIL marker
5. **stdin isolation** — `< /dev/null` properly isolates test stdin from runner
6. **Special characters** — Shell metacharacters preserved in output
7. **Silent failures** — Empty output still reports FAIL
8. **FAILED_TESTS array** — Populated correctly on failure
9. **Counter updates** — PASS/FAIL counters increment correctly

**Result: 13/13 assertions passed**

### Full Test Suite
- **Shell tests:** 374 passed, 0 failed
- **Python tests:** 87 passed
- **Total:** 461 tests passed, 0 failed

### Implementation Quality
The fix is minimal and correct:
```bash
# Single invocation — capture output and exit code together
output=$(bash "$test_file" < /dev/null 2>&1) || rc=$?

if [ "$rc" -eq 0 ]; then
    # PASS: report and continue
else
    # FAIL: print captured output from the same run
    printf '%s\n' "$output" | sed 's/^/  /'
fi
```

Key implementation details:
- `< /dev/null` prevents stdin inheritance
- `|| rc=$?` prevents parent's `set -e` from aborting
- `printf '%s\n'` is safer than `echo` for arbitrary output
- Single `bash "$test_file"` invocation — no re-run

This eliminates the false-negative race condition where:
- Run 1 fails with `set -euo pipefail` abort (SIGPIPE, grep no-match, etc.)
- Run 2 starts clean and produces all-PASS output
- Runner reports "FAIL" with misleading "Passed: N  Failed: 0" debug output
