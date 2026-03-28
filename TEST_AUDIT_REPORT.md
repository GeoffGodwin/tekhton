## Test Audit Report

### Audit Summary
Tests audited: 2 files, 13 test functions (7 in test_agent_counter.sh, 9 phases in test_agent_fifo_invocation.sh)
Verdict: CONCERNS

---

### Findings

#### INTEGRITY: Tautological assertion in success branch (4.2)
- File: `tests/test_agent_fifo_invocation.sh:139-143`
- Issue: `assert_eq "4.2 log file has JSON output" "0" "0"` compares the literal string "0" to itself — this assertion always passes regardless of what `grep` found. The `if grep -q ...; then assert_eq "..." "0" "0"` pattern is intended to register a pass, but the assert call itself verifies nothing. The actual failure detection lives in the `else` branch (`FAIL=1`), so the test would still fail if `grep` didn't match — but the assertion on the success path is a dead no-op that communicates false rigour.
- Severity: HIGH
- Action: Replace `assert_eq "4.2 ..." "0" "0"` with a direct `echo "PASS: 4.2 ..."` statement (and add a PASS counter — see NAMING finding). Do not leave an always-true `assert_eq` in the success branch.

#### INTEGRITY: Tautological assertion in success branch (6.3)
- File: `tests/test_agent_fifo_invocation.sh:196-201`
- Issue: Identical pattern to finding above. `assert_eq "6.3 log contains ACTIVITY TIMEOUT message" "0" "0"` is always true regardless of the `grep` result. Same reasoning and risk apply.
- Severity: HIGH
- Action: Same as 4.2 — replace the tautological `assert_eq "..." "0" "0"` with a `echo "PASS: ..."` statement.

#### SCOPE: lib/agent.sh modified but not reported in TESTER_REPORT.md
- File: `lib/agent.sh:130`, `TESTER_REPORT.md`
- Issue: `git diff lib/agent.sh` reveals an unstaged working-tree change: a `&& command -v get_mcp_config_path &>/dev/null` guard was added to the MCP config block inside `run_agent()`. TESTER_REPORT.md states "Implementation Files Changed: none." The change is defensive and correct (prevents calling an undefined function), and is the likely fix for one or both of the originally failing tests. The omission from the report means the implementation change is undocumented and unreviewed.
- Severity: MEDIUM
- Action: Update TESTER_REPORT.md to list `lib/agent.sh` under "Implementation Files Changed" and describe the change. Stage the file so it is included in the next commit alongside the test fixes.

#### NAMING: No PASS counter in test_agent_fifo_invocation.sh
- File: `tests/test_agent_fifo_invocation.sh:44-68`
- Issue: `FAIL` is tracked but `PASS` is not. The test exits correctly on failure but produces no pass-count summary. Silent success paths make it harder to confirm that all assertion branches actually executed — particularly relevant given the tautological assertions in 4.2 and 6.3 that print "PASS" without incrementing any counter.
- Severity: LOW
- Action: Add `PASS=0` and increment it in `assert_eq`, `assert_ge`, and `assert_file_exists`/`assert_file_not_exists` on success. Print a summary line at the end matching the `test_agent_counter.sh` style.

---

### Tests That Pass Audit

**test_agent_counter.sh** — No findings. This test:
- Correctly overrides `_run_with_retry` after sourcing `agent.sh`, allowing `run_agent()` to execute all pre-call code including the `TOTAL_AGENT_INVOCATIONS` increment at `lib/agent.sh:88`.
- Asserts derived values (1, 2, 3, 11) that reflect actual accumulation logic, not unrelated magic numbers.
- Covers: basic increment (Suite 1), accumulation from non-zero baseline (Suite 2), independence of `TOTAL_AGENT_INVOCATIONS` from `TOTAL_TURNS` (Suite 3).
- Sets `TEKHTON_TEST_MODE=1` to correctly suppress the spinner before calling `run_agent()`.

**test_agent_fifo_invocation.sh — honest assertions** — Phases 1, 2, 3, 4 (a/b/c/d/e), 5, 6.1/6.2, 7, 8, and 9 all use real mock claude binaries through the actual FIFO infrastructure in `lib/agent.sh`. Assertions are derived from mock output (e.g. `"num_turns":5` → `LAST_AGENT_TURNS=5`) and real agent.sh logic (null-run threshold at line 297, activity-timeout exit code 124 at line 277). These are honest tests of real behavior.
