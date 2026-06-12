## Test Audit Report

### Audit Summary
Tests audited: 4 files, 17 test functions (A–F across files)
Verdict: CONCERNS

---

### Findings

#### INTEGRITY: Test B in mcp_resolve_provider_guard always passes — assertion is inert
- File: tests/test_mcp_resolve_provider_guard.sh:105-112
- Issue: Both branches of the if/else in test B call `pass()`. Whether or not the
  fake claude is invoked when PROVIDER=claude, the test records PASS. The comment
  at lines 109–111 concedes this explicitly: "B not failing does not imply B passed."
  This is equivalent to `assertTrue(True)` — the positive-case assertion never catches
  a regression where `_cli_supports_mcp_config` ignores PROVIDER=claude and always
  skips the probe (over-broad guard). The guard is exercised by test A (negative path)
  but the affirmative path — that the probe IS allowed when claude is in the spec — is
  never actually verified.
- Severity: HIGH
- Action: Replace the else-branch unconditional pass (lines 109–112) with:
  `fail "B: claude NOT invoked despite PROVIDER=claude — guard may be over-broad"`
  The `FAKE_CLAUDE_INVOKED_FILE` is correctly exported inside the subshell's env block
  (line 73), and `PATH` prepends `WORK_DIR` (line 74), so the fake binary should be
  reachable. If this proves fragile in headless CI, add a pre-flight check
  (`command -v claude >/dev/null || { echo "SKIP: fake claude not on PATH"; exit 0; }`)
  at the top of test B rather than silently converting failure to pass.

#### COVERAGE: No meaningful assertion on return value when PROVIDER=claude
- File: tests/test_mcp_resolve_provider_guard.sh:89-113
- Issue: Even after test B is made fallible, neither test case checks what
  `_cli_supports_mcp_config` returns when PROVIDER=claude. The fake claude outputs
  no `--mcp-config` line, so the function should return 1 and set
  `_CLI_MCP_CONFIG_SUPPORTED=0`. A separate assertion on the function's return code
  would confirm the guard does not force rc=1 for claude-containing providers.
- Severity: MEDIUM
- Action: After fixing B, capture the subshell exit code and assert it is not forced
  to 1 by the provider guard path (i.e., the probe ran and the result came from the
  `claude --help` grep, not the guard short-circuit).

#### COVERAGE: No test for empty stdout_tail array
- File: tests/test_plan_batch_emit_tail.sh (case absent)
- Issue: Case B covers `"stdout_tail": null` (no array bracket). The awk for the empty
  array `"stdout_tail": []` takes a different code path: `in_tail` is set to 1 on the
  `[` match then immediately cleared on `]`, producing no output. This edge case is
  distinct from null and not covered.
- Severity: LOW
- Action: Add case G with `"stdout_tail": []` and assert empty output and rc 0.

#### EXERCISE: Log-function stubs not restored after sourcing common.sh
- File: tests/test_common_usage_threshold_guard.sh:51-62
- Issue: `log`, `warn`, `error` etc. are stubbed before sourcing common.sh (lines 51–56),
  but `source "${TEKHTON_HOME}/lib/common.sh"` redefines them via output.sh
  (common.sh:65-70). Unlike `test_clear_commit_skip_sentinels.sh` which explicitly
  re-stubs these functions after sourcing (lines 56–60), this test does not. In
  environments where `_out_emit` has unmet dependencies or writes to a TUI context,
  this can produce spurious output or fail in ways unrelated to `check_usage_threshold`.
- Severity: LOW
- Action: After line 62 (`source "${TEKHTON_HOME}/lib/common.sh"`), add re-stubs for
  `log`, `warn`, `error`, `success`, `header` matching the pattern used in
  `test_clear_commit_skip_sentinels.sh:56-60`.

#### COVERAGE: Positive-path invocation of `claude usage` not tested
- File: tests/test_common_usage_threshold_guard.sh (case absent)
- Issue: Tests A/B/C all verify early-return paths (provider guard, threshold=0). No
  test verifies the path where `claude usage` IS called (PROVIDER=claude, threshold>0)
  and the output is parsed. The fake claude at line 46 already outputs
  "Session usage: 99%", making a positive-path case straightforward.
- Severity: LOW
- Action: Add case D: `PROVIDER=claude`, `USAGE_THRESHOLD_PCT=50`, fake claude outputs
  99%. Assert (1) fake claude WAS invoked and (2) function returns 1 (threshold
  exceeded). This covers the `grep -oE '[0-9]+(\.[0-9]+)?%'` extraction in common.sh:192.

---

### Tests That Are Clean

**test_plan_batch_emit_tail.sh** — All six cases (A–F) exercise the real awk logic in
`_plan_batch_emit_tail` with fixture files created in `WORK_DIR`. Assertions correctly
match implementation output: escaped-quote unescaping (D1), escaped-backslash (D2),
section isolation (E), null vs array detection (B), missing-file early-return (C).
Isolation is complete (mktemp + trap). Stub setup prevents agent_shim.sh from loading.

**test_clear_commit_skip_sentinels.sh** — Five cases exercise `_clear_commit_skip_sentinels`
across absolute path, missing files, relative path join, and bystander-file preservation.
The decoy PROJECT_DIR in case C correctly verifies the `[[ "$dir" != /* ]]` guard at
replan_midrun.sh:44. Re-stub pattern after sourcing common.sh is correctly applied.

**test_mcp_resolve_provider_guard.sh, Test A** — Correctly verifies that the PROVIDER
guard in `_cli_supports_mcp_config` (mcp_resolve.sh:158–163) short-circuits before
invoking the fake claude binary. The self-skip guard (lines 22–26) correctly detects
the pre-m20 state and exits 0, keeping the suite green before the implementation lands.

**test_common_usage_threshold_guard.sh, Tests A/B/C** — Test A verifies the provider guard
short-circuit; test B independently checks the return code from the same call; test C
correctly exercises the threshold=0 early-return path, which is distinct from the
provider guard (the threshold check fires first at common.sh:169).
