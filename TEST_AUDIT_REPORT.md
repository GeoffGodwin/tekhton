## Test Audit Report

### Audit Summary
Tests audited: 3 files, 25 test functions
Verdict: PASS

Note: `CODER_SUMMARY.md` was absent at audit time. Implementation files were
verified directly from source: `lib/orchestrate_helpers.sh`, `lib/config_defaults.sh`,
`stages/coder.sh`, and `lib/agent.sh`. The audit context's claim "Implementation
Files Changed: none" is inconsistent with the git status — `stages/coder.sh`,
`lib/orchestrate_helpers.sh`, and `lib/config_defaults.sh` are all modified.
Assertions were cross-referenced against the actual modified source.

---

### Findings

#### EXERCISE: Suites 1 and 2 in test_scout_repo_map_tools.sh test an inline reimplementation, not the real code
- File: tests/test_scout_repo_map_tools.sh:43-113
- Issue: Neither Suite 1 (SCOUT_NO_REPO_MAP flag) nor Suite 2 (tool allowlist
  reduction) sources or calls `stages/coder.sh`. Instead, both suites duplicate the
  conditional logic from `stages/coder.sh:198-207` verbatim inside the test body and
  then verify their own copy of that logic. A bug in the real implementation — wrong
  variable name, wrong comparison operator, wrong branch — would not be detected.
  These tests would pass regardless. Suite 3 (config default) is unaffected; it
  correctly sources `lib/config_defaults.sh`.
- Severity: MEDIUM
- Action: Delete Suites 1 and 2 from `tests/test_scout_repo_map_tools.sh`. The
  behavior they claim to verify is fully exercised by `test_coder_scout_tools_integration.sh`
  which calls the real `run_stage_coder()`. Retaining weaker duplicates alongside a
  stronger integration test creates false confidence.

#### COVERAGE: run_repo_map failure path is untested in integration test
- File: tests/test_coder_scout_tools_integration.sh (gap — no suite covers this path)
- Issue: The mock `run_repo_map()` always returns 0 and always populates
  `REPO_MAP_CONTENT`. In `stages/coder.sh:191-193`, the real call is guarded:
  `if run_repo_map "$TASK"; then` — if it returns non-zero, `REPO_MAP_CONTENT`
  stays empty and the full tool set is used. This fallback (indexer available but
  map generation fails) is a distinct code path from Suite 3 (`INDEXER_AVAILABLE=false`)
  and is untested.
- Severity: MEDIUM
- Action: Add a Suite 4 that sets `INDEXER_AVAILABLE=true`, overrides `run_repo_map`
  to `return 1`, and asserts `_captured_scout_tools = "$AGENT_TOOLS_SCOUT"`.

#### SCOPE: AGENT_TOOLS_SCOUT value in integration test is stale relative to lib/agent.sh
- File: tests/test_coder_scout_tools_integration.sh:53
- Issue: The test hardcodes
  `AGENT_TOOLS_SCOUT="Read Glob Grep Bash(find:*) Bash(head:*) Bash(wc:*) Bash(cat:*) Bash(ls:*) Write"`,
  which is missing `Bash(tail:*)` and `Bash(file:*)` relative to the authoritative
  definition in `lib/agent.sh:38`. Tests 2.1 and 3.1 check
  `_captured_scout_tools = "$AGENT_TOOLS_SCOUT"`, so they are internally consistent
  but test a value that differs from what production would use. If `lib/agent.sh`
  adds or removes a tool, these tests will silently validate a stale string.
- Severity: LOW
- Action: Import the real value by sourcing `lib/agent.sh` before running the test
  suite, or add an inline comment acknowledging the value is a deliberate test
  fixture and must be kept in sync with `lib/agent.sh:38`.

#### COVERAGE: Test 1.2 in integration test uses a weakly bounded assertion
- File: tests/test_coder_scout_tools_integration.sh:210-214
- Issue: Test 1.2 asserts `_run_agent_call_count -ge 1`. The counter increments for
  ALL `run_agent` calls (both Scout and Coder). If the Scout invocation were somehow
  skipped but the Coder ran, 1.2 would still pass — even though 1.1 already captures
  the real invariant (correct tools on the Scout call). The test adds noise rather
  than signal.
- Severity: LOW
- Action: Replace the `_run_agent_call_count -ge 1` check with
  `[[ -n "$_captured_scout_tools" ]]` (non-empty capture confirms the Scout branch
  executed), or remove 1.2 entirely — a passing 1.1 already proves the Scout ran.

#### COVERAGE: No test for PREFLIGHT_FIX_MAX_ATTEMPTS=1 boundary in test_preflight_fix.sh
- File: tests/test_preflight_fix.sh (gap — all attempt-count tests use value 2)
- Issue: Every test of the exhaustion path uses `PREFLIGHT_FIX_MAX_ATTEMPTS=2`.
  The value 1 exercises a distinct boundary: the while loop body runs exactly once
  and exits, with no second-chance path. This is a minimal-iteration edge case
  for the loop in `orchestrate_helpers.sh:89`.
- Severity: LOW
- Action: Add a test with `PREFLIGHT_FIX_MAX_ATTEMPTS=1` and
  `_MOCK_FIX_ON_ATTEMPT=-1`, asserting `local_result=1` and
  `_MOCK_RUN_AGENT_CALLS=1`.

---

### Findings: None for the following categories

#### None (Assertion Honesty / INTEGRITY)
All assertions derive their expected values from the real implementation.
- The reduced tool string `"Read Glob Grep Write"` appears verbatim in
  `stages/coder.sh:206` — not invented by the test.
- Config default assertions (PREFLIGHT_FIX_ENABLED=true, PREFLIGHT_FIX_MAX_ATTEMPTS=2)
  are verified against `lib/config_defaults.sh:309-310` — exact match.
- Regression detection in Suite 7 of `test_preflight_fix.sh` uses initial_count=1
  (one "FAIL:" in the seed string) and produces new_count=8 (eight "FAIL:" lines in
  the test command output). The threshold in `orchestrate_helpers.sh:135` is
  `_pf_initial_fail_count + 2` = 3. 8 > 3 fires correctly — no hard-coded magic.
- No tautological assertions (`assertTrue(True)`, `assertEqual(x, x)`) found.

#### None (Test Weakening / WEAKENING)
All three test files are new (untracked). No existing tests were modified.

#### None (Naming)
All test descriptions encode both scenario and expected outcome. Examples:
"returns 0 when fix succeeds on attempt 2", "returns 1 when disabled",
"aborted after 1 attempt (regression detected, not all 3)".

#### None (Scope Alignment / SCOPE — orphaned tests)
No orphaned, stale, or dead tests detected. All asserted functions
(`_try_preflight_fix`, `run_stage_coder`, config defaults) are present
and modified in the implementation files. No deleted or renamed symbols
are referenced.
