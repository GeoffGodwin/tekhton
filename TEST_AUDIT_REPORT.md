## Test Audit Report

### Audit Summary
Tests audited: 2 files, 11 test functions (Tests 1–9 in test_build_gate_timeouts.sh, Tests 10–11 in test_ui_server_hardening.sh)
Verdict: PASS

---

### Findings

#### COVERAGE: Test 4 treats both gate outcomes as passing
- File: tests/test_build_gate_timeouts.sh:133–138
- Issue: Both branches of `if run_build_gate "test-analyze-timeout"` call `pass`. The implementation contracts that ANALYZE_CMD timeout (exit 124) is treated as pass, so `run_build_gate` should return 0. As written, a regression where the gate returns 1 on analyze timeout still marks the test green — only the elapsed-time assertion detects a hang, not a wrong return code.
- Severity: MEDIUM
- Action: Remove the two-pass dual-branch. Assert `run_build_gate` returns 0, adding `fail` to the else branch. Separate the timing check as it is now.

#### COVERAGE: Test 9 timing threshold equals the implementation's own internal timeout
- File: tests/test_build_gate_timeouts.sh:273–276
- Issue: `_check_npm_package` internally wraps `npm ls` with `timeout 10`. Test 9 asserts `elapsed -lt 10`. On a system where npm takes the full 10s to time out and the wall clock rounds up, the assertion fails spuriously. There is no slack between the implementation ceiling and the test limit.
- Severity: MEDIUM
- Action: Change the assertion to `elapsed -lt 15` to give the implementation's 10s timeout room to complete and return without flakiness.

#### COVERAGE: Tests 5 and 8 discard the return code for timeout scenarios
- File: tests/test_build_gate_timeouts.sh:159, 247
- Issue: Both use `|| true`, verifying only that execution finishes in time. The implementation contracts that BUILD_CHECK_CMD timeout and constraint-validation timeout are both treated as pass (return 0). A regression changing either to return 1 on timeout would go undetected.
- Severity: LOW
- Action: Capture the exit code and add a pass/fail assertion that it equals 0, matching the documented "timeout = pass" contract for both phases.

#### SCOPE: CODER_SUMMARY.md deleted but silently referenced by sourced implementation functions
- File: tests/test_build_gate_timeouts.sh (sources lib/gates.sh and lib/ui_validate.sh)
- Issue: CODER_SUMMARY.md was intentionally deleted by the coder. `lib/gates.sh` (`_warn_summary_drift`, `run_completion_gate`) and `lib/ui_validate.sh` (`_detect_ui_targets`, `_should_self_test_watchtower`) all reference it. The M30 test functions are not affected: they run inside a clean TMPDIR (file absent), and every path that reads CODER_SUMMARY.md has an `[[ -f … ]] || return 0` guard. No test breaks today, but four implementation functions silently no-op on the missing-file path without any test coverage.
- Severity: LOW
- Action: No action required for these tests. Raise a follow-on ticket to add tests for the absent-file branch of `_warn_summary_drift` and `run_completion_gate` (outside M30 scope).

---

### No findings in the following categories

**INTEGRITY (hard-coded values) — PASS.** All assertions derive from real implementation behavior. The "Gate Timeout" string in Test 6 (`grep -q "Gate Timeout" BUILD_ERRORS.md`) maps exactly to the `## Gate Timeout` heading written by `_gate_check_timeout` in `lib/gates.sh:57`. No magic numbers appear that are absent from the implementation.

**EXERCISE — PASS.** Tests source and directly invoke the actual functions under test (`_check_headless_browser`, `run_build_gate`, `_check_npm_package`, `_start_ui_server`, `_stop_ui_server`). Stubs are limited to out-of-scope dependencies (`run_ui_validation`, `emit_event`). No function under test is mocked.

**WEAKENING — PASS.** Both test files are newly created (untracked in git). No existing test files were modified.

**NAMING — PASS.** Test descriptions are descriptive of both the scenario and the expected outcome (e.g., "Browser detection completed in Xs (< 35s limit)", "Overall gate timeout returned non-zero exit", "10b. _start_ui_server completed in Xs — curl probe timeout enforced").

**REGRESSION SIGNAL — PASS.** TESTER_REPORT.md confirms both files correctly fail against pre-M30 code via git stash. This is the key integrity signal that tests are genuinely M30-specific and not written to pass unconditionally.
