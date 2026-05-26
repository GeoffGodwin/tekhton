## Test Audit Report

### Audit Summary
Tests audited: 1 primary file (`internal/notes/acceptance_test.go`), 3 freshness-sample files
(`cmd/tekhton/commit_bookkeeping_test.go`, `cmd/tekhton/state_test.go`,
`cmd/tekhton/supervise_test.go`), 13 test functions in primary file.
Verdict: CONCERNS

---

### Findings

#### COVERAGE: Regex-bug acceptance test accommodates rather than exposes the defect
- File: `internal/notes/acceptance_test.go:143–167`
- Issue: The tester correctly identified that `rootCauseRE` (`(?i)^##\s+Root Cause`) lacks the
  `(?m)` flag, so `^` matches only start-of-text rather than start-of-line. The test then works
  around the bug by constructing a CODER_SUMMARY.md that opens with `## Root Cause\n...` (line
  165) so the regex matches at position 0. The comment at lines 148–153 documents this explicitly.
  The problem: real Tekhton CODER_SUMMARY.md files always open with `## Status: COMPLETE` (see
  the live `.tekhton/CODER_SUMMARY.md` in this repo). That means every production BUG note whose
  CODER_SUMMARY.md contains a valid `## Root Cause` section on any line other than the first will
  spuriously fire `warn_no_rca`. No test case covers this production-realistic layout, so the bug
  will not be caught by the suite once the regex is eventually fixed — and the current suite gives
  no signal that the bug is even firing in CI. A passing test whose summary input matches only the
  degenerate (position-0) form provides no regression protection.
  Fix: add a sub-case to `TestBugAcceptance` where `coderSummary` is
  `"## Status: COMPLETE\n\n## Root Cause\n\nBad pointer.\n"` and `wantCode == "pass"`. That case
  will FAIL against the current code (confirming the known bug) and PASS after the `(?im)` fix,
  giving the suite the regression guard it currently lacks.
- Severity: HIGH
- Action: Add the test case described above. Do NOT change the regex to make the existing test
  pass — tests follow code. The regex fix belongs in a separate commit with the new test as its
  acceptance criterion.

---

#### COVERAGE: FEAT placement check has no test for root-level new files
- File: `internal/notes/acceptance_test.go:204–291` (FEAT sub-tests)
- Issue: `checkFeatAcceptance` explicitly skips new files whose `filepath.Dir(f) == "."` (files
  at the repo root), at `acceptance.go:207`. No test verifies that a root-level untracked
  non-test file like `newfile.go` does not trigger `warn_file_placement`. If the skip were
  accidentally removed the existing FEAT suite would still pass.
- Severity: LOW
- Action: Add a sub-case to `TestFeatAcceptance` that adds an untracked `.go` file at the repo
  root and asserts `wantCode == "pass"`.

---

### Freshness Sample — No Issues Found

`cmd/tekhton/commit_bookkeeping_test.go`, `cmd/tekhton/state_test.go`, and
`cmd/tekhton/supervise_test.go` were reviewed for staleness against the deletion list.

- None import any of the 16 deleted `lib/notes_*.sh` bash modules (they are pure Go tests with
  no bash dependencies).
- Assertions in all three files are grounded in real implementation calls with meaningful inputs.
- Isolation: all three use `t.TempDir()` fixtures; none read mutable project state files.
- No orphaned references, no weakened assertions, no naming issues.

These files are healthy. No action required.

---

### Passing Rubric Points (primary file)

**Assertion Honesty — PASS**
Every assertion checks the outcome of a real `RunAcceptance` call against fixtures created by
the test. `res.Code` is compared to `wantCode` derived from documented acceptance logic;
`res.Warnings` length is checked against `wantWarnCount`; warning text is verified against
the file paths the implementation actually names. No assertion tests a hard-coded value
independent of implementation logic.

**Implementation Exercise — PASS**
Tests call `RunAcceptance` → `checkBugAcceptance` / `checkFeatAcceptance` /
`checkPolishAcceptance` against real temporary git repositories created by `makeGitRepo`. Real
`git diff`, `git ls-files`, and `git add` commands execute. The only injectable seam is
`AcceptanceOptions.CoderSummaryFile`, which is the documented extension point.

**Test Weakening Detection — N/A**
`acceptance_test.go` is a new file. No existing tests were modified or assertions broadened.

**Test Naming and Intent — PASS**
All sub-test names encode both the scenario and the expected outcome
(`warn_no_test_no_summary`, `pass_test_and_rca`, `warn_logic_modified_staged`, etc.).

**Scope Alignment — PASS**
The deleted bash files (`lib/notes_acceptance.sh`, `lib/notes_acceptance_helpers.sh`) are the
implementations being replaced. The new Go tests target their Go replacements in
`internal/notes/acceptance.go`. No orphaned imports or references to deleted symbols.

**Test Isolation — PASS**
All tests use `t.TempDir()` and `makeGitRepo`. No test reads live pipeline artifacts, build
reports, or project-level state files. `TestUnknownTagPass` and `TestEmptyTagPass` do not even
require a git repo — they use a bare temp directory. Pass/fail outcomes are fully independent
of pipeline state.
