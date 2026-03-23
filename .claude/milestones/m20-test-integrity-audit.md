#### Milestone 20: Test Integrity Audit
Add a dedicated test audit pass within the review stage that independently
evaluates the quality, honesty, and relevance of tests written or modified
by the tester agent. Prevents the "agent cheating at tests" problem where
the tester writes trivial, hard-coded, or orphaned tests that provide false
confidence.

The core principle: **the entity that writes the tests must never be the sole
entity that judges them.** The tester writes, the audit evaluates.

This also addresses test scope drift: when the coder removes or refactors
features, existing tests may become orphaned or impossible to pass. The audit
detects these and recommends removal rather than forcing ghost code to satisfy
dead tests.

**Bootstrap consideration:** Tekhton runs on itself. Tests written by earlier
versions (M01-M19) were never audited against this rubric. The ongoing audit
only scans tests touched in the current run, so legacy tests won't trigger
findings until someone modifies them. To establish a clean baseline, this
milestone also adds a `tekhton --audit-tests` standalone command that runs the
full audit against ALL test files in the project (not just the current diff).
After M20 is implemented, a one-time `--audit-tests` run on the Tekhton repo
validates and cleans up legacy tests as a bootstrap step.

Files to create:
- `prompts/test_audit.prompt.md` — Test audit prompt for the reviewer:
  Instructs the reviewer to evaluate test files with a specific rubric.
  The audit receives: (1) test files written/modified by the tester (from
  TESTER_REPORT.md or git diff of test directories), (2) CODER_SUMMARY.md
  (what implementation files changed), (3) the implementation files those
  tests are supposed to exercise.

  **Six-point audit rubric:**

  1. **Assertion honesty:** Are assertions testing real behavior or hard-coded
     values? Flag: `assert result == 42` where 42 appears nowhere in the
     implementation logic. Flag: assertTrue(True), assertEqual(x, x).
     Good: assertions that verify outputs from actual function calls with
     meaningful inputs.

  2. **Edge case coverage:** Do tests cover boundary conditions, error paths,
     empty inputs, null/None handling, overflow, and off-by-one scenarios?
     Not every test needs every edge case, but a test suite with ONLY happy
     paths is a red flag. Score: ratio of error-path tests to happy-path tests.

  3. **Implementation exercise:** Do tests actually call the implementation
     code? Flag: tests that mock every dependency and never call the real
     function. Flag: tests that only test the mock. Good: tests that use
     real implementations with minimal, targeted mocking.

  4. **Test weakening detection:** If the tester MODIFIED existing tests
     (not just added new ones), did the modification weaken them? Compare
     git diff of test files: removed assertions, broadened expected values
     (e.g., `assertEqual(x, 5)` → `assertTrue(x > 0)`), removed edge case
     tests. Any weakening without clear justification in TESTER_REPORT.md
     is flagged as suspicious.

  5. **Test naming and intent:** Are test names descriptive of what they
     verify? `test_1()`, `test_thing()`, `test_it_works()` are red flags.
     Good: `test_login_fails_with_expired_token()`,
     `test_empty_list_returns_404()`. Names should encode the scenario AND
     the expected outcome.

  6. **Scope alignment:** Do tests still align with the current codebase?
     Cross-reference test imports/references against CODER_SUMMARY.md:
     - If the coder DELETED a module and tests still import it → orphaned test
     - If the coder RENAMED a function/class and tests reference the old name → stale test
     - If the coder REMOVED a feature and tests exercise that feature → dead test
     - If the coder REFACTORED behavior (changed return type, altered contract)
       and tests assert old behavior → misaligned test
     For each detected case: recommend removal or update, NOT implementation
     changes to satisfy the test. **Tests follow code, not the other way around.**

  **Output format:** TEST_AUDIT_REPORT.md with:
  ```markdown
  ## Test Audit Report

  ### Audit Summary
  Tests audited: 12 files, 47 test functions
  Verdict: NEEDS_WORK | PASS | CONCERNS

  ### Findings

  #### INTEGRITY: Hard-coded assertion
  - File: tests/test_calculator.py:34
  - Issue: `assert result == 42` — value 42 not derived from any calculation
  - Severity: HIGH
  - Action: Rewrite to test actual computation output

  #### SCOPE: Orphaned test
  - File: tests/test_legacy_handler.py
  - Issue: Tests import `src.api.legacy_handler` which was deleted by coder
  - Severity: HIGH
  - Action: Remove test file (feature was intentionally removed)

  #### COVERAGE: Missing error path
  - File: tests/test_auth.py
  - Issue: Tests only cover successful login. No tests for: expired token,
    invalid credentials, locked account, rate-limited login
  - Severity: MEDIUM
  - Action: Add error path tests

  #### WEAKENING: Assertion broadened
  - File: tests/test_api.py:78
  - Issue: Changed `assertEqual(status, 200)` to `assertTrue(status < 500)`
  - Severity: HIGH
  - Action: Restore specific assertion or justify in TESTER_REPORT.md
  ```

  **Verdicts:**
  - PASS: No HIGH findings. Proceed.
  - CONCERNS: 1-2 HIGH findings. Log to SECURITY_NOTES.md (if security enabled)
    and NON_BLOCKING_LOG.md. Proceed but flag for human attention.
  - NEEDS_WORK: 3+ HIGH findings or any integrity violation. Route back to
    tester for rework (bounded by TEST_AUDIT_MAX_REWORK_CYCLES).

- `lib/test_audit.sh` — Test audit orchestration:
  **Pre-audit file collection** (`_collect_audit_context()`):
  - Parse TESTER_REPORT.md for test files written/modified
  - Parse CODER_SUMMARY.md for implementation files changed/deleted
  - Run `git diff --name-status` to detect: test files added (A), modified (M),
    deleted (D) during this pipeline run
  - For modified test files: extract the diff to detect weakened assertions
  - Build a mapping: test file → implementation file it exercises (by import
    analysis or naming convention: test_foo.py → foo.py)

  **Orphan detection** (`_detect_orphaned_tests()`):
  Pure shell logic, no agent needed:
  - For each test file modified/existing in test directories:
    - Extract import statements (grep for `import`, `from ... import`, `require`)
    - Cross-reference against files deleted by coder (from CODER_SUMMARY.md)
    - If a test imports a deleted module → mark as orphaned
  - For renamed/moved files: check if test still references old path
  - Output: list of orphaned test files with reason

  **Weakening detection** (`_detect_test_weakening()`):
  Pure shell logic on git diff:
  - For each modified test file (not newly created):
    - Count assertions removed vs added
    - Detect pattern changes: specific → generic (assertEqual → assertTrue,
      exact match → range check, etc.)
    - Detect removed test functions (entire tests deleted)
  - Output: list of potentially weakened tests with diff context

  **Audit invocation** (`run_test_audit()`):
  1. Collect audit context
  2. Run orphan detection (shell-only, instant)
  3. Run weakening detection (shell-only, instant)
  4. If orphans or weakening found, inject findings into audit prompt context
  5. Invoke reviewer agent with test_audit.prompt.md (SHORT turn budget —
     this is a focused review, not a full coding session)
  6. Parse TEST_AUDIT_REPORT.md for verdict
  7. Route based on verdict: PASS → continue, CONCERNS → log + continue,
     NEEDS_WORK → tester rework

  **Rework routing:**
  When verdict is NEEDS_WORK, route back to tester with a
  `test_audit_rework.prompt.md` that includes:
  - The specific findings from TEST_AUDIT_REPORT.md
  - The instruction: "Fix the flagged tests. Do NOT modify implementation code.
    Do NOT weaken assertions. If a test is orphaned because the feature was
    removed, DELETE the test."
  - Bounded by TEST_AUDIT_MAX_REWORK_CYCLES (default 1 — if the tester can't
    fix it in one pass, escalate to human)

- `prompts/test_audit_rework.prompt.md` — Tester rework prompt for audit findings.
  Structured like security_rework.prompt.md: read the finding, read the test,
  fix it. Explicit instruction: "Removing an orphaned test IS the correct fix.
  You are not required to make every test pass. You are required to make every
  test HONEST and RELEVANT."

Files to modify:
- `stages/tester.sh` — After the tester completes and tests pass, call
  `run_test_audit()` before proceeding to finalization. The audit is a
  sub-stage of the test phase, not a separate pipeline stage. This keeps
  the stage count at 4 (Coder, Security, Review, Test) while adding the
  audit within the test stage.

- `tekhton.sh` — Add `--audit-tests` flag. When set:
  1. Discover ALL test files in the project (using test directory conventions
     and M12 test framework detection when available)
  2. Run the full 6-point audit against every test file (not just the diff)
  3. Generate TEST_AUDIT_REPORT.md with findings across the full suite
  4. Print summary to terminal (same format as --diagnose output)
  5. Exit (do not run pipeline)
  This is the "bootstrap" command for projects adopting M20 on existing
  test suites. Run once to establish a clean baseline, then ongoing audits
  handle incremental changes.

- `stages/review.sh` — NO changes. The reviewer's scope remains implementation
  code quality. Test quality is handled by the audit within the test stage.
  This maintains clear separation of concerns.

- `lib/config_defaults.sh` — Add:
  TEST_AUDIT_ENABLED=true (opt-out, enabled by default),
  TEST_AUDIT_MAX_TURNS=8 (short — focused review, not coding),
  TEST_AUDIT_MAX_REWORK_CYCLES=1 (one chance to fix, then escalate),
  TEST_AUDIT_ORPHAN_DETECTION=true (shell-based orphan detection),
  TEST_AUDIT_WEAKENING_DETECTION=true (shell-based weakening detection),
  TEST_AUDIT_REPORT_FILE=TEST_AUDIT_REPORT.md.

- `lib/config.sh` — Validate TEST_AUDIT_* keys.

- `lib/prompts.sh` — Register template variables: TEST_AUDIT_CONTEXT
  (collected file mappings, orphan findings, weakening findings),
  CODER_DELETED_FILES (list of files deleted by coder, for scope alignment).

- `prompts/tester.prompt.md` — Add explicit anti-cheating instructions:
  ```
  ## CRITICAL: Test Integrity Rules
  - Write tests that verify REAL behavior, not hard-coded expected values.
  - Every assertion must test output from an actual function/method call.
  - Do NOT mock everything — mock only external dependencies (network, DB, filesystem).
  - Do NOT weaken existing tests to make them pass. If a test fails because
    the implementation changed, REPORT THE BUG — do not fix the test.
  - If a test is impossible to pass because the feature was INTENTIONALLY
    removed (per CODER_SUMMARY.md), mark it for removal: `- ORPHAN: [file] reason`
  - Your tests WILL be independently audited. Write them as if a skeptical
    senior engineer will review every assertion.
  ```

- `lib/dashboard.sh` — Add `emit_dashboard_test_audit()`. Include audit
  verdict and findings in `data/reports.js` under the test stage section.

- `lib/hooks.sh` or `lib/finalize.sh` — Include TEST_AUDIT_REPORT.md in
  archive and RUN_SUMMARY.json.

- `lib/diagnose_rules.sh` — Add diagnostic rule `_rule_test_audit_failure()`
  for when the audit verdict is NEEDS_WORK after max rework cycles:
  Suggestions: "Test audit found integrity issues the tester couldn't fix.
  Review TEST_AUDIT_REPORT.md and fix tests manually."

Acceptance criteria:
- Test audit runs after tester completes, within the test stage
- Audit rubric covers all 6 points: assertion honesty, edge cases,
  implementation exercise, test weakening, naming, scope alignment
- Orphan detection correctly flags tests that import deleted modules
- Weakening detection flags tests where assertions were broadened or removed
- NEEDS_WORK verdict routes back to tester for rework (bounded by 1 cycle)
- CONCERNS verdict logs findings but does not block pipeline
- PASS verdict proceeds without delay
- Tester prompt includes anti-cheating instructions
- Tester prompt includes ORPHAN marking instruction for dead tests
- Rework prompt explicitly allows test REMOVAL as a valid fix
- Audit is opt-out (TEST_AUDIT_ENABLED=true by default)
- When TEST_AUDIT_ENABLED=false, audit is cleanly skipped
- Orphan and weakening detection work without agent calls (pure shell)
- Agent-based audit uses short turn budget (8 turns max)
- Pipeline does not get stuck in test-hell: orphaned tests can be removed,
  not patched with ghost code
- `tekhton --audit-tests` scans ALL test files (not just current diff) and
  produces a full-suite audit report
- `--audit-tests` works as a standalone command (no pipeline run required)
- After M20 implementation, `--audit-tests` run on the Tekhton repo itself
  produces a clean report (bootstrap validation step)
- Watchtower reports include audit verdict and findings
- Diagnostic rule provides recovery guidance on audit failure
- All existing tests pass
- `bash -n lib/test_audit.sh` passes
- `shellcheck lib/test_audit.sh` passes
- New test file `tests/test_audit.sh` covers: orphan detection against
  fixture projects, weakening detection against mock diffs, verdict
  routing, rework cycle bounds

Watch For:
- Import analysis in shell is language-dependent. Python uses `import`/`from`,
  JS uses `require`/`import`, Go uses package paths. Start with the top 3-4
  patterns and skip files with unrecognized import syntax. The agent-based
  audit catches what the shell misses.
- The "weakening detection" diff analysis must distinguish between intentional
  test updates (changing expected value because the implementation contract
  changed) and malicious weakening (broadening assertions to hide failures).
  The shell can flag candidates; the agent makes the judgement call.
- Test file location conventions vary: `tests/`, `test/`, `__tests__/`,
  `*_test.go`, `*.spec.ts`, `*.test.js`. Use the same detection patterns
  from M12's test framework detection.
- The rework cycle limit of 1 is intentionally low. If the tester can't fix
  integrity issues in one pass, it's likely a fundamental approach problem
  that needs human intervention. Don't waste turns on repeated failures.
- "Removing an orphaned test IS the correct fix" must be prominently stated
  in the rework prompt. Agents have a strong bias toward adding code, not
  removing it. The prompt must overcome this bias explicitly.
- The audit should NOT run when no tests were written (tester produced no
  test files). Only audit what the tester actually touched this run.

Seeds Forward:
- Health scoring (M15) test dimension can use audit results for a more
  accurate test quality score (not just file count, but audit pass rate)
- V4 tech debt agent uses accumulated CONCERNS findings as a backlog:
  "Improve edge case coverage in tests/test_auth.py"
- The audit rubric is extensible: V4 adds coverage measurement dimension
  when test coverage tooling is integrated
- The orphan detection pattern is reusable for dead code detection in general
  (modules that nothing imports)
- V4 parallel execution: audit runs in parallel with the security agent
  (both are post-coder, pre-finalize quality gates)
