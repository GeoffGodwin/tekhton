# Reviewer Report — M63 Test Baseline Hygiene

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `stages/tester.sh:180,344` — `TEST_BASELINE_ENABLED` guard uses `:-false` fallback, but `lib/test_baseline.sh` and `config_defaults.sh` both default it to `true`. No production impact (config_defaults.sh always sets it before stages run), but the fallback is inconsistent and could silently skip baseline summary injection in isolated unit tests.
- `lib/test_baseline.sh` — 388 lines, over the 300-line soft ceiling. New content (~50 lines) pushed it over threshold. Consider extracting `cleanup_stale_baselines` and `get_baseline_exit_code` into a `test_baseline_cleanup.sh` sidecar in a future cleanup pass.

## Coverage Gaps
- None

## Drift Observations
- None

---

### Review Notes

All six scopes from the milestone spec are addressed and correct:

1. **run_id freshness** (`_should_capture_test_baseline`): Logic is sound — no baseline → capture; same run_id → skip; different run_id → re-capture; missing run_id → stale (backward compat). Atomic JSON write via tmpfile+mv matches the existing pattern.

2. **Tester baseline summary**: Injected correctly before `render_prompt("tester")`. The `{{IF:TEST_BASELINE_SUMMARY}}` block is positioned before the Context section in the prompt, which is appropriate — it sets agent expectations before the task description. The guard correctly skips injection when `exit_code == 0` (no pre-existing failures to warn about).

3. **Completion gate test enforcement**: `COMPLETION_GATE_TEST_ENABLED` default is `true` in config_defaults.sh. The gate correctly uses `compare_test_with_baseline` with a has-baseline guard, so it can't block on pre-existing failures. Falls back to blocking if no baseline exists, which is the safe default.

4. **Stuck detection hardening**: `get_baseline_exit_code()` is used correctly — checks `"0"` string match on the grep output before blocking auto-pass. The causal event `stuck_test_detected` with `clean_baseline_block` detail is emitted for observability.

5. **Baseline cleanup hook**: Registered at index 0 (first hook), which is the right placement — stale files are cleaned before any other finalization logic reads or archives them. The `SC2034` disable for `exit_code` is appropriate since the hook runs unconditionally regardless of pipeline outcome.

6. **Tester fix baseline check**: Uses `compare_test_with_baseline "$_failure_output" "1"` — the failure output is extracted from the log rather than a fresh test run, so the hash match may be approximate. This is acceptable: worst case is a false `new_failures` result, which causes the fix agent to run unnecessarily (safe). A false `pre_existing` result (skipping a real fix) is only possible if the log fragment exactly matches the baseline hash, which is unlikely for genuinely new failures.

Test coverage in `test_test_baseline.sh` (suites 8–11) is thorough and matches the implementation. Hook order in `test_finalize_run.sh` is correctly updated — 21 hooks with `_hook_baseline_cleanup` at index 0 and all prior hooks shifted by one index.
