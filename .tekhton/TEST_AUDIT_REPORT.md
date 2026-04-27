## Test Audit Report

### Audit Summary
Tests audited: 3 files, 30 test functions (16 in test_m132_run_summary_enrichment.sh,
4 in test_finalize_summary_tester_guard.sh, 10 in test_m62_fixes_integration.sh)
Verdict: PASS

### Findings

#### COVERAGE: Two remaining hard-coded line-number lookups not converted by M132 maintenance
- File: tests/test_m62_fixes_integration.sh:82 and tests/test_m62_fixes_integration.sh:89
- Issue: M132 maintenance converted Test 8's `sed -n '165p'` to a `grep -q` pattern
  lookup. Tests 9 and 10 still use `sed -n '138p' lib/timing.sh` and
  `sed -n '41p' stages/review.sh` respectively. Neither `timing.sh` nor `review.sh`
  was modified by M132, so both tests currently pass. However, any future insertion or
  removal of lines before line 138 in timing.sh (or line 41 in review.sh) will silently
  test the wrong line or fail on a vacuous non-match — the exact fragility that prompted
  the Test 8 fix. The coder addressed the immediate breakage without completing the
  pattern fix across the whole file.
- Severity: MEDIUM
- Action: Replace `sed -n '138p' "${TEKHTON_HOME}/lib/timing.sh"` (Test 9) with:
  `grep -q 'if \[\[ "$_spk" == "${_pfx}"\* \]\]; then' "${TEKHTON_HOME}/lib/timing.sh"`
  Replace `sed -n '41p' "${TEKHTON_HOME}/stages/review.sh"` (Test 10) with:
  `grep -q 'global.*tested externally' "${TEKHTON_HOME}/stages/review.sh"`
  Both assertions are already pattern-based; only the line-number coupling needs removal.

#### NAMING: Silent-skip pattern hides dependent test outcomes on guard-line failure
- File: tests/test_finalize_summary_tester_guard.sh:32, :42, :52
- Issue: Tests 2, 3, and 4 are wrapped in `if [[ -n "$guard_line" ]]; then ... fi`
  with no `else` branch. If Test 1 fails to locate the guard line, Tests 2–4 execute
  neither `pass` nor `fail` — they are silently skipped. The final tally would report
  1 failure (from Test 1) rather than 4, obscuring which assertions did not run. In the
  current codebase this cannot trigger because the guard pattern exists, but if a
  future refactor renames the condition and Test 1 fails, the dependent test count
  will be invisible.
- Severity: LOW
- Action: Add a short-circuit after Test 1 — e.g., `[[ -n "$guard_line" ]] ||
  { fail "guard not found — cannot run Tests 2-4"; exit 1; }` — so the full
  impact of a missed guard is explicit in the summary.

#### COVERAGE: Dashboard parser sed-fallback path not covered by M132 tests
- File: tests/test_m132_run_summary_enrichment.sh (absent coverage for fallback)
- Issue: T10 validates the `_hook_emit_run_summary` output and the python3 JSON-parse
  path. The `lib/dashboard_parsers_runs_files.sh` sed-fallback branch (lines 82–89)
  — which extracts `recovery_route` and `build_fix_outcome` when python3 is
  unavailable — has no corresponding test. This fallback uses bracket-expression sed
  patterns that differ from the python3 extraction logic and could diverge silently.
  The CODER_SUMMARY explicitly identifies this fallback as part of Goal 9 scope.
- Severity: LOW
- Action: Add a T11 case that writes a RUN_SUMMARY_*.json fixture to a tmpdir and
  calls `_parse_run_summaries_from_files` with python3 shadowed by a stub that returns
  empty, then asserts `recovery_route` and `build_fix_outcome` extract correctly via
  the sed path. Not blocking for M132 but recommended before M134 consumes these fields.

### Notes
- The STALE-SYM warnings for `cd`, `dirname`, `echo`, `grep`, `pwd`, `sed`, `set` are
  shell builtins and POSIX utilities, not source-file-defined functions. They are false
  positives from the symbol-level orphan detector and require no action.
- `test_m132_run_summary_enrichment.sh` is well-structured: proper tmpdir isolation
  with trap cleanup, a mock `_load_failure_cause_context` that mirrors the real
  contract without overriding it (sourced collectors only call it via `declare -f`
  guard), and assertions that check values derived from actual function output. T3's
  sentinel check `{"schema_version":0}` matches the exact literal returned by
  `_collect_causal_context_json` when the context file is absent — a spec-defined
  sentinel documented in the CODER_SUMMARY, not a hard-coded magic value. T7's
  exact-match `'["ENVIRONMENT/test_infra"]'` correctly verifies the no-duplicate
  invariant by asserting array length via string equality.
- The `_load_failure_cause_context` mock in the test (lines 71–128) is a faithful
  reconstruction of the real implementation in `orchestrate_recovery_causal.sh:64`.
  Both share the same v2 block-parser and v1 flat-sed fallback logic, and both honor
  `ORCH_CONTEXT_FILE_OVERRIDE`. The mock does not weaken the contract under test.
- `test_finalize_summary_tester_guard.sh` correctly uses `grep -n` dynamic line
  lookup after M132 shifted file offsets. The upgrade from hard-coded `sed -n '165p'`
  to offset-arithmetic is the right approach and cleanly handles future line shifts.
