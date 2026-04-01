## Test Audit Report

### Audit Summary
Tests audited: 4 files, ~161 test functions
(test_finalize_run.sh, test_human_workflow.sh, test_notes_acceptance.sh, test_notes_triage.sh)
Verdict: NEEDS_WORK

---

### Findings

#### INTEGRITY: Both branches of integration test call pass() — test can never fail
- File: tests/test_notes_acceptance.sh:222-229
- Issue: Suite 4 BUG acceptance integration test reads:
  ```bash
  run_note_acceptance
  if [[ "${NOTE_ACCEPTANCE_RESULT:-}" == *"warn_no_test"* ]]; then
      pass "run_note_acceptance sets NOTE_ACCEPTANCE_RESULT for BUG"
  else
      # May be pass if test files happen to exist
      pass "run_note_acceptance runs without error for BUG"
  fi
  ```
  Both `if` and `else` branches call `pass()`. The test unconditionally records a pass regardless
  of what `run_note_acceptance` actually does. Any behavior — including crash-and-recover,
  wrong result, or silent no-op — produces a green test. The comment "May be pass if test files
  happen to exist" suggests the author intended the else-branch as a fallback, but using `pass()`
  in both branches means the `if` condition is never load-bearing. The implementation under test
  (`lib/notes_acceptance.sh:run_note_acceptance`) sets `NOTE_ACCEPTANCE_RESULT`; the test never
  verifies this is non-empty or contains expected tokens on failure.
- Severity: HIGH
- Action: Decide what the test must guarantee. Option A — verify the specific warn code:
  ```bash
  run_note_acceptance
  if [[ "${NOTE_ACCEPTANCE_RESULT:-}" == *"warn_no_test"* ]]; then
      pass "run_note_acceptance sets warn_no_test for BUG with no test file change"
  else
      fail "run_note_acceptance should set warn_no_test for BUG (got: ${NOTE_ACCEPTANCE_RESULT:-<empty>})"
  fi
  ```
  Option B — if the environment makes the warn non-deterministic, set it up deterministically
  (no staged test file changes) and assert the expected code.

#### INTEGRITY: Special-characters test asserts echo 'ok' instead of claim_single_note result
- File: tests/test_human_workflow.sh:233-237
- Issue: The "special characters in note" test suppresses the real outcome and then asserts a
  no-op command:
  ```bash
  claim_single_note "$note" || true       # real result discarded
  # If it didn't error, that's good
  assert_exit_code "Special chars handled" 0 "echo 'ok'"  # always passes
  ```
  `echo 'ok'` always exits 0. The assertion provides zero coverage of `claim_single_note`'s
  behavior with special characters. The real question — does the function handle regex
  metacharacters without corrupting HUMAN_NOTES.md or erroring? — is never answered.
  If `claim_single_note` failed silently, panicked, or mangled the file, this test still passes.
- Severity: HIGH
- Action: Capture the real exit code and assert it, or test the file state:
  ```bash
  set +e; claim_single_note "$note"; _rc=$?; set -e
  assert_exit_code "Special chars: claim returns non-error" 0 "[ $_rc -eq 0 ] || [ $_rc -eq 1 ]"
  # and/or: assert file is not corrupted
  ```
  At minimum, remove `|| true` and assert the exit code directly.

#### SCOPE: Assertion 15.6 tests a removed function — vacuously true for all inputs
- File: tests/test_finalize_run.sh:830
- Issue: `assert "15.6 resolve_human_notes NOT called on failure"` checks that the mock for
  `resolve_human_notes` was not invoked when `finalize_run 1` is called. However, `resolve_human_notes`
  is not called anywhere in the current `lib/finalize.sh` implementation — it was removed as part
  of the M42 unified CLAIMED_NOTE_IDS path. The mock is registered at test line 108–111 but
  `_hook_resolve_notes` never calls it. The assertion is vacuously true for both success and
  failure exit codes, and provides no protection against future regressions that might
  accidentally re-introduce a `resolve_human_notes` call on the success path.
- Severity: MEDIUM
- Action: Remove assertion 15.6 (it tests a removed code path). If the intent is to guard against
  `resolve_human_notes` being called at any time, add a companion test that runs `finalize_run 0`
  and asserts the mock is still not called — but document the intent clearly. Alternatively,
  replace with an assertion that `resolve_notes_batch` IS called on success when `CLAIMED_NOTE_IDS`
  is non-empty, testing the live code path that replaced the old one.

#### WEAKENING: Net loss of 4 assertions — deferred without per-assertion documentation
- File: tests/test_finalize_run.sh (whole file)
- Issue: Shell pre-verification detected 6 assertions removed and 2 added (net −4). The TESTER_REPORT
  attributes the removals to HUMAN_MODE-branching paths eliminated in M42 and defers creating a
  per-assertion audit record. The justification is plausible — the unified CLAIMED_NOTE_IDS path
  did consolidate what were previously separate HUMAN_MODE branches. The new Suite 8b (8 test cases
  covering the unified path) likely covers equivalent behavioral surface. However, "likely covers"
  is not confirmed: the tester did not enumerate which specific assertions were removed or which
  8b cases map to them. Until that mapping exists, the net reduction cannot be verified as
  non-weakening.
- Severity: MEDIUM
- Action: Add a comment block in test_finalize_run.sh (or in TESTER_REPORT.md) listing each removed
  assertion by its former test ID/description and the M42 behavioral reason it no longer applies.
  Confirm that each removed behavioral guarantee is covered by a specific Suite 8b case.

#### EXERCISE: Section 10 flag-validation tests inline-reimplement logic from tekhton.sh
- File: tests/test_human_workflow.sh:634-688 (Section 10)
- Issue: Tests 10.1–10.4 validate `--human` flag rejection rules by simulating the validation
  logic locally using shell variables (`HUMAN_MODE`, `MILESTONE_MODE`, `MOCK_TASK`) rather than
  calling the real argument-parsing code in `tekhton.sh`. The comment added in this pass
  (lines 634–638) acknowledges the limitation. A breaking change to tekhton.sh flag handling
  would not be caught by these tests; they only verify the test's own inline simulation.
- Severity: LOW
- Action: The added acknowledgment comment is the minimum acceptable for now. Longer-term,
  extract the flag validation gate into a sourceable lib function (e.g., `lib/flags.sh`) so
  it can be directly exercised by the test suite without standing up a full pipeline.

---

### Prior Findings — Disposition

The following findings from the previous TEST_AUDIT_REPORT.md were addressed and are
considered RESOLVED in this pass:

- **INTEGRITY (test_finalize_run.sh:428)** — RESOLVED. Test 8.2 now captures actual exit
  code via `set +e; _hook_resolve_notes 0; _rc=$?; set -e` and asserts `$_rc -eq 0`.

- **INTEGRITY (NON_BLOCKING_LOG.md false "resolved" entry)** — RESOLVED. The log was
  reopened and split into five accurate resolved entries covering Tests 8.1, 8.2, 8.4,
  and two test_human_workflow.sh fixes.

- **NAMING (test_human_workflow.sh:779)** — RESOLVED. The assert message at line 783
  now reads "Orphan safety net marks [x]" consistent with the test_case description.

- **EXERCISE (test_human_workflow.sh:635-683)** — PARTIALLY RESOLVED. Acknowledgment
  comment added at lines 634–638. Coverage gap remains (LOW severity, see above).
