## Test Audit Report

### Audit Summary
Tests audited: 4 files, 13 test functions
Verdict: CONCERNS

### Findings

#### INTEGRITY: Assertion B in mcp_resolve_provider_guard always passes
- File: tests/test_mcp_resolve_provider_guard.sh:95-101
- Issue: Both branches of the if/else call `pass()`. Whether or not the fake
  claude is invoked when PROVIDER=claude, the test records PASS. The comment
  explicitly concedes this: "B not failing does not imply B passed." This is
  equivalent to `assertTrue(True)` — the positive-case assertion is inert and
  will never catch a regression where _cli_supports_mcp_config ignores
  PROVIDER=claude and always skips the probe (over-broad guard). After m20 is
  implemented, this masked assertion gives false confidence that the "allow
  claude when PROVIDER=claude" branch works.
- Severity: HIGH
- Action: Replace the else-branch body (lines 100-101) with:
  `fail "B: claude NOT invoked despite PROVIDER=claude — guard may be over-broad"`
  If PATH miss is a real concern, also set `export FAKE_CLAUDE_INVOKED_FILE=...`
  outside the subshell so the variable is inherited (currently set inside the
  export block at line 87, which is correct — just verify PATH includes WORK_DIR).

#### COVERAGE: Positive case (PROVIDER=claude) has no meaningful assertion
- File: tests/test_mcp_resolve_provider_guard.sh:83-103
- Issue: Follows from the above. Even after fixing assertion B, there is no
  check that _cli_supports_mcp_config returns a meaningful value when PROVIDER=claude.
  The suite verifies the negative case (codex → no probe) but not the affirmative
  contract (claude → probe runs, caching works). Half the guard's contract is untested.
- Severity: MEDIUM
- Action: Once B is made fallible, add a separate assertion checking that the
  function's return code when PROVIDER=claude is not forced to 1 by the guard
  (i.e., the guard does not also block the claude path).

#### EXERCISE: test_plan_batch_provider_boundary.sh sources agent_shim.sh with no comment
- File: tests/test_plan_batch_provider_boundary.sh:121
- Issue: lib/agent_shim.sh is sourced before calling _call_planning_batch, but
  the current implementation (plan_batch.sh:88) calls claude directly — it uses
  no agent_shim function. The sourcing is forward-looking (post-m20, the function
  will route through the shim), but is unexplained. A reader auditing this file
  will not understand why the dependency is pre-loaded, and the sourcing
  silently masks any errors in agent_shim.sh during sourcing.
- Severity: LOW
- Action: Add a comment at line 121 explaining the forward-compatibility intent:
  `# sourced for post-m20 compatibility — _call_planning_batch will delegate through agent_shim`

#### ISOLATION: test_audit_raw_claude.sh live tree scan reads mutable lib/ directory
- File: tests/test_audit_raw_claude.sh:160-161
- Issue: `_run_audit "${TEKHTON_HOME}/lib/"` passes the live lib/ directory to
  the audit script. As a CI gate this is intentional, but it means the test's
  result depends on the mutable project tree state. A contributor who adds a
  raw claude call to any lib/ file (for a legitimate reason that hasn't been
  allowlisted yet) will see this test fail without understanding why. The test
  also assumes the audit script accepts a directory argument — that contract is
  untested until scripts/audit-raw-claude.sh exists.
- Severity: LOW
- Action: No change required for the live-tree CI gate intent. When
  scripts/audit-raw-claude.sh is implemented, add a fixture-directory test case
  (a temp dir with multiple files) to verify that the directory-walk behavior is
  tested independently of the live tree, before the live scan assertion.

### Notes on Tester Honesty

TESTER_REPORT.md accurately describes outcomes. The 4 pre-m20 failing assertions
are correctly attributed to absent implementation, not test defects. The 2 passing
assertions (mcp_resolve_provider_guard B and common_usage_threshold_guard C) are
real: C correctly passes because check_usage_threshold returns early at the
USAGE_THRESHOLD_PCT=0 guard before reaching the `claude usage` call (common.sh:169-171).
B passes vacuously — that is the only integrity concern. The tester did not mask
failures or over-assert to produce green results; the 4 failing tests are
genuinely detecting absent m20 implementation.
