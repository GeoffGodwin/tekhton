## Test Audit Report

### Audit Summary
Tests audited: 2 files, 9 test functions (A–H in test_plan_batch_emit_tail.sh; A–E in test_no_claude_e2e.sh)
Verdict: CONCERNS

---

### Findings

#### INTEGRITY: Test H breaks the test suite permanently until BUG-001 is fixed
- File: `tests/test_plan_batch_emit_tail.sh:238–246`
- Issue: Test H asserts that `_plan_batch_emit_tail` decodes `"foo\\nbar"` as a literal backslash-n. The tester explicitly documents this as a deliberate expected-failure confirming BUG-001 (wrong awk unescape order in `lib/plan_batch.sh:173–176`). However, the test hard-fails via the global `FAIL` counter, so `test_plan_batch_emit_tail.sh` exits 1 on every run until BUG-001 is resolved. `tests/run_tests.sh:376–378` treats any `FAIL > 0` as a CI failure — there is no XFAIL mechanism. This permanently turns the test suite from green to red, which will mask future regressions.
- Severity: HIGH
- Action: Wrap test H in a skip guard so it does not count toward CI failures:
  ```bash
  if [[ "${TEKHTON_CONFIRM_BUGS:-0}" == "1" ]]; then
      # BUG-001 confirmation: run with TEKHTON_CONFIRM_BUGS=1 to surface
      ... test H body ...
  else
      echo "SKIP H: BUG-001 confirmation skipped (set TEKHTON_CONFIRM_BUGS=1 to enable)"
  fi
  ```
  The bug citation and root-cause explanation in the existing comment block (lines 219–227) should be preserved.

#### COVERAGE: Sabotage assertion exercises review stage only — coder stage zero-claude guarantee is untested
- File: `tests/test_no_claude_e2e.sh:199–243`
- Issue: Assertion E uses `PROVIDER_REVIEW=claude` because `PROVIDER_CODER=claude` is ineffective — BUG-002 (`internal/stages/coder/orchestrator.go:newOrchestrator` has `deps.RunAgent` nil, so the coder stage never dispatches through any provider). The comment at lines 204–209 is transparent about the limitation. The effect is that the test confirms claude is not invoked during a codex run (assertion D covers this broadly), but it does not confirm that the coder stage's provider dispatch is wired at all — only the review stage's dispatch is exercised by the sabotage.
- Severity: MEDIUM
- Action: Add a TODO comment adjacent to the sabotage block (after line 209) noting: "When BUG-002 is fixed (deps.RunAgent wired in coder orchestrator), add a PROVIDER_CODER=claude sabotage variant here." Do not implement it now — the fix belongs in the coder orchestrator, not the test. Tests follow code.

#### COVERAGE: Assertion C verifies hello.txt via hardcoded shim path — Go provider WorkingDir routing is not tested
- File: `tests/test_no_claude_e2e.sh:107–131` (codex shim) and `183–187` (assertion C)
- Issue: The fake codex shim writes hello.txt to `TARGET="${WORK_DIR}"` hardcoded at test-script creation time, bypassing BUG-003 (`internal/provider/codex/flags.go:buildExecArgs` passes `os.Getwd()` as `--cd` instead of `req.WorkingDir`). Assertion C passes because of the hardcoded shim path, not because the Go provider correctly routes the working directory. A deployment using the real codex binary would write files to `TEKHTON_HOME`, but this test would still pass. The comment at lines 95–101 acknowledges BUG-003.
- Severity: MEDIUM
- Action: Add a comment adjacent to assertion C explicitly stating that it verifies the codex shim delivered the coder artifact, not that the Go provider correctly passes WorkingDir. When BUG-003 is fixed, the shim should be updated to parse `--cd` from its argv and write to that path instead of a hardcoded TARGET, so assertion C exercises the actual routing.

#### NAMING: Test header comment not updated to include tests G and H
- File: `tests/test_plan_batch_emit_tail.sh:9–16`
- Issue: The header comment lists coverage A–F only. Test G (empty array, pre-existing) and test H (backslash-n ordering, added this run) are absent. A reader relying on the header to understand coverage will not find G or H.
- Severity: LOW
- Action: Extend the header comment to add:
  ```
  #   G — empty stdout_tail array: no output, returns 0
  #   H — JSON \\n ordering: literal backslash-n must not become a newline
  #         (BUG-001 confirmation; gated on TEKHTON_CONFIRM_BUGS=1)
  ```
