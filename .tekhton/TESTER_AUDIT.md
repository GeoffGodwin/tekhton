## Test Audit Report

### Audit Summary
Tests audited: 4 files, 17 test functions
Verdict: CONCERNS

---

### Findings

#### INTEGRITY: Known-failing test shipped without implementation fix
- File: tests/test_plan_batch_emit_tail.sh:196–213 (test G)
- Issue: Test G asserts that `_plan_batch_emit_tail` produces no output for an inline empty array `"stdout_tail": []`. This is the correct expected behavior, but the awk in `lib/plan_batch.sh:165–178` does not handle it. The opening awk pattern `/^[[:space:]]*"stdout_tail"[[:space:]]*:[[:space:]]*\[/` matches the whole line `  "stdout_tail": []` and executes `in_tail=1; next`, consuming the `[` and `]` on the same line. The closing pattern requires `]` on its own line — it never fires. The next line (`}`) is then processed by the in-tail block and emitted as output. The tester correctly identifies this in TESTER_REPORT.md ("Bugs Found") but leaves `lib/plan_batch.sh` unmodified. The test suite is known-failing at submission time and will block CI.
- Severity: HIGH
- Action: Fix the awk in `_plan_batch_emit_tail` to handle the inline-empty-array case before setting `in_tail`. For example:

  ```awk
  /^[[:space:]]*"stdout_tail"[[:space:]]*:[[:space:]]*\[\]/ { next }
  /^[[:space:]]*"stdout_tail"[[:space:]]*:[[:space:]]*\[/   { in_tail=1; next }
  ```

  Do NOT remove or defer test G — it correctly documents the expected contract and should turn green once the implementation is fixed.

---

#### COVERAGE: Individual caller sites not verified for correct label strings
- File: tests/test_plan_batch_label_routing.sh (overall file)
- Issue: The test file header states m22 "updates all callers (plan_interview, plan_generate, plan_followup_interview, replan, replan_brownfield, replan_midrun) to pass their stage-specific labels." Tests A–D only exercise `_call_planning_batch` itself — they verify the function threads `$5` to `_shim_write_request`, but no test verifies that each caller site actually passes the correct label. Inspection confirms the callers do pass labels (`"plan_interview"` at stages/plan_interview.sh:166, `"plan_generate"` at stages/plan_generate.sh:85, `"plan_interview"` at stages/plan_followup_interview.sh:183, `"replan"` at lib/replan_brownfield.sh:184, `"replan"` at lib/replan_midrun.sh:221), but a future regression where a caller omits or misspells the label would not be caught.
- Severity: MEDIUM
- Action: Add lightweight structural grep checks — one per caller file — asserting that the expected label string is present in the `_call_planning_batch` call. The test-E pattern already used in this file (source grep) is the right model. No new subshell execution needed.

---

#### SCOPE: Test E is a source-text grep, not a behavioral assertion
- File: tests/test_plan_batch_label_routing.sh:148–156 (test E)
- Issue: Test E greps for the literal string `${5:-planning}` in `lib/plan_batch.sh`. If the default mechanism is refactored (e.g. `local label; label=${5:-}; label=${label:-planning}`) while preserving identical behavior, test E fails falsely. The behavioral coverage is already provided by test D (no label → captured label == "planning"). Test E is redundant and couples tests to implementation syntax rather than contract.
- Severity: LOW
- Action: Remove test E or convert it to a comment explaining that test D covers the default. The behavioral guarantee from test D is sufficient.

---

### Passing Checks (no action required)

**Assertion Honesty** — All assertions across all four files derive from real function calls through the real implementations (`_cli_supports_mcp_config`, `check_usage_threshold`, `_plan_batch_emit_tail`, `_call_planning_batch`). No hard-coded magic values or tautologies (assertTrue(True), assertEqual(x,x)) found anywhere.

**Implementation Exercise** — All four test files source the real implementation file and call the real function under test. Stubs are targeted: logging functions, external binaries (`claude`, `tekhton`), and shim helpers (`_shim_resolve_binary`, `_shim_write_request`, `_shim_field`). The function under test itself is never mocked.

**Test Weakening** — The tester strengthened existing tests across the board: added the B2 return-code check to `test_mcp_resolve_provider_guard.sh`; added a post-source log re-stub and test D (positive path: PROVIDER=claude + 99% usage → invoked + returns 1) to `test_common_usage_threshold_guard.sh`; added test G to `test_plan_batch_emit_tail.sh`. No existing assertions were loosened or removed.

**Test Naming** — All tests use scenario-and-outcome labels ("A: claude NOT invoked by check_usage_threshold when PROVIDER=codex", "D2: check_usage_threshold returns 1 (usage 99% exceeds threshold 50%)"). Consistent with project convention and pass the intent-readability check.

**Test Isolation** — All four files create fixtures inside `$(mktemp -d)` with `trap "rm -rf ..." EXIT`. No test reads live pipeline logs, config state files, or run artifacts. The fake `claude` binary and fake `tekhton` binary are written into the temp dir and removed on exit. Isolation is clean across all cases.

**Skip Guards** — Both provider-guard tests include self-skip logic that exits 0 when the guard has not yet been implemented. The skip conditions were verified against the current implementation:
- `test_mcp_resolve_provider_guard.sh:22-26`: pattern `PROVIDER.*claude` matches `lib/mcp_resolve.sh:158` (`local provider_spec="${PROVIDER:-codex,claude}"`). Guard detected → tests run. ✓
- `test_common_usage_threshold_guard.sh:21-24`: awk range extraction of `check_usage_threshold()` body + grep for `PROVIDER` matches `lib/common.sh:173`. Guard detected → tests run. ✓
