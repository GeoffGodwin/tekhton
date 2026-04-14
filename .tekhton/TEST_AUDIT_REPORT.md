## Test Audit Report

### Audit Summary
Tests audited: 2 files, 29 test assertions
Verdict: CONCERNS

### Findings

#### ISOLATION: Live M72 milestone file read in integration test
- File: tests/test_milestone_acceptance_lint.sh:97-108
- Issue: The test reads `.claude/milestones/m72-tidy-project-root-tekhton-dir.md`
  directly from the repo tree and asserts `wcount -ge 2` against its live content.
  This couples the test's pass/fail to the content of a mutable project file: if
  M72's criteria are ever revised to include behavioral keywords (e.g., as an
  errata fix), the `>=2` assertion breaks with no change to the linter or test.
  The M72 file is not a pipeline run artifact, but it is source-controlled project
  state that evolves independently of the linter under audit.
- Severity: HIGH
- Action: Snapshot the M72 acceptance criteria text into a fixture string inside
  TMPDIR (or as a heredoc in the test itself) rather than reading the live file.
  This preserves the intent of "M72-style all-structural criteria should trigger
  warnings" while decoupling pass/fail from future M72 edits. If a live-corpus
  smoke test is also desired, keep it as a separate, clearly labelled integration
  check that tolerates a SKIP when the file is absent or content has changed.

#### ISOLATION: Live M73-M83 milestone files read in false-positive loop
- File: tests/test_milestone_acceptance_lint.sh:113-129
- Issue: The false-positive sweep sources milestone files directly from
  `${TEKHTON_HOME}/.claude/milestones/m${mnum}-*.md` for milestones 73 through
  83. The test fails (not skips) if any file is missing. More importantly, if
  any of those 11 milestone files is edited to use only structural criteria (e.g.,
  during M87 TEKHTON_DIR work or future polish milestones), the test reports a
  false-positive as a failure in the linter, when in fact the linter is working
  correctly and the milestone criteria need improvement. The test's pass/fail is
  thus coupled to the current criterion quality of 11 files that evolve
  independently of the linter.
- Severity: HIGH
- Action: For the false-positive check, create purpose-built fixture files in
  TMPDIR that contain representative acceptance criteria text (behavioral keywords,
  refactor completeness lines, etc.) matching the patterns found in M73-M83 at
  the time of this milestone. These fixtures remain stable regardless of how the
  live milestone files evolve. The linter's correctness against "well-formed
  criteria" can then be verified deterministically. The current live-corpus test
  can be retained as an advisory integration check (non-blocking) if desired.

### No Further Findings

#### Assertion Honesty — PASS
All assertions test real outputs from real function calls. No hard-coded expected
values appear that are disconnected from implementation logic. The `wcount -ge 2`
assertion for M72 is connected to actual linter output (when supplied the real
M72 text), and the unit-level assertions use fixture inputs and check for
non-empty/empty output from the real functions.

#### Implementation Exercise — PASS
Both test files source `lib/common.sh` and `lib/milestone_acceptance_lint.sh`
and call the real implementation functions (`_lint_extract_criteria`,
`_lint_has_behavioral_criterion`, `_lint_refactor_has_completeness_check`,
`_lint_config_has_self_referential_check`, `lint_acceptance_criteria`). The
integration section in test_milestone_acceptance_lint.sh sources the real DAG,
milestone, and state libraries and calls `check_milestone_acceptance` with a
fixture manifest — no mocking of the linter path itself.

#### Test Weakening — PASS
These are entirely new test files. No prior tests were modified. There is no
weakening to evaluate.

#### Naming and Intent — PASS
Test names in the `pass()`/`fail()` calls are descriptive and encode both the
scenario and the expected outcome (e.g., "Second criterion (after code block)
is extracted", "Lint refactor warning appears in check_milestone_acceptance
output"). File names are also specific to their scope.

#### Scope Alignment — PASS
All tests target the newly created `lib/milestone_acceptance_lint.sh` and the
updated `lib/milestone_acceptance.sh`. No test imports or references a deleted
or renamed function. The code-block guard fix in `_lint_extract_criteria`
(ordering of the heading-break check vs. the in-block guard) is correctly
exercised by test_milestone_acceptance_lint_codeblockhash.sh.

The codeblockhash test fixture for `lint_acceptance_criteria` (lines 88-112)
is correctly sensitive to the code-block ordering bug: the behavioral keyword
("emits") appears only in the criterion after the code block. A broken extractor
that stops at the `##` heading inside the code block would drop that criterion,
trigger a spurious lint warning, and cause the test to fail. This is a correct
and well-targeted regression test for the specific defect described in the coder
summary.

#### Edge Case Coverage — LOW (non-blocking)
The following paths in `lint_acceptance_criteria` are not tested:
- Call with a nonexistent file (returns 0 at line 139) — trivial guard.
- Call with a file containing no `## Acceptance Criteria` section (returns 0
  at line 146) — trivial guard.
- `_lint_infer_categories` in isolation (covered indirectly via
  `lint_acceptance_criteria` integration but not unit-tested).
These omissions are low-risk given the simplicity of the code paths and the
comprehensive coverage of the primary logic branches.
