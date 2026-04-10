## Test Audit Report

### Audit Summary
Tests audited: 3 files, 16 test functions
Verdict: PASS

---

### Findings

#### NAMING: Test 2 label claims ratio=51 but exercises ratio=100
- File: tests/test_dep_ratio_boundary.sh:70
- Issue: The test echo and comment both say "Ratio 51 scores 20 (just above boundary)" but
  the fixture uses 2 deps / 2 source files → ratio = (2×100)/2 = 100. The assertion is
  correct (ratio=100 falls in the `elif [[ "$ratio" -gt 50 ]]` tier → dep_ratio_score=20),
  but the label promises ratio=51 which cannot be produced with integer dep/file counts.
  The lengthy inline comment (lines 79–102) acknowledges the discrepancy but leaves the
  misleading test name intact. A failure message would cite "ratio 51" while the actual
  input that failed was ratio=100.
- Severity: MEDIUM
- Action: Rename the test echo/comment header to "Ratio 100 (>50) scores 20" and remove
  the misleading "51" references at lines 68, 70. The long explanatory comment block can
  be reduced to a one-line note: "integer arithmetic can't produce ratio=51 with small
  file/dep counts; ratio=100 is the nearest >50 achievable here."

#### ISOLATION: `cd` calls mutate working directory for all subsequent tests
- File: tests/test_health_greenfield_baseline.sh:31,51,69,95,124
- Issue: Each test runs `cd "$TESTn_DIR" && git init -q`, leaving the process CWD as
  $TEST2_DIR by the time tests 3–5 execute. All health functions accept an explicit
  `proj_dir` argument and use it consistently, so no current test fails due to this.
  However, the silent CWD mutation creates an order dependency: any future refactor that
  introduces a relative path or bare `git init` (without `-C`) would cause tests 3–5 to
  operate on test 2's directory with no error message indicating why.
- Severity: MEDIUM
- Action: Replace `cd "$TESTn_DIR" && git init -q` with `git -C "$TESTn_DIR" init -q`
  in all five locations. The `make_git_repo` helper in test_dep_ratio_boundary.sh already
  follows this pattern correctly and can serve as a template.

#### COVERAGE: No test for CLAUDE.md Project Identity with zero recognized language names
- File: tests/test_detect_claude_md_fallback.sh (missing case)
- Issue: All five tests verify that recognized languages ARE extracted. There is no test
  for the case where CLAUDE.md has a valid `### 1. Project Identity` section whose content
  contains only non-language terms (e.g., "PostgreSQL", "AWS S3", "Nginx"). In detect.sh
  lines 114–116, both grep passes would return empty, leaving `_detected_output` empty.
  Without a test, a future regex change that leaks unrecognized names into output would
  go undetected.
- Severity: LOW
- Action: Add a Test 6 that creates a CLAUDE.md whose Project Identity section lists only
  "PostgreSQL", "AWS", "Nginx" and asserts the result is empty (no output).

#### COVERAGE: Trap chain grows linearly and is fragile to paths with single quotes
- File: tests/test_detect_claude_md_fallback.sh:23,49,78,102,118
- Issue: Each successive test appends its temp directory to the EXIT trap string by
  re-issuing `trap "rm -rf '$T1' '$T2' ..." EXIT`. This works when mktemp produces paths
  without single quotes (always true on Linux), but the pattern is unusually brittle: a
  path containing a single quote would silently break cleanup. The pattern also obscures
  intent — the final trap at line 118 is the only one that matters for cleanup.
- Severity: LOW
- Action: Declare a single `TEMP_DIRS=()` array at the top, push each new dir onto it, and
  set `trap 'rm -rf "${TEMP_DIRS[@]}"' EXIT` once at the top of the file. This is the
  standard pattern used by the rest of the test suite.

---

### No issues found for the following rubric categories
- **INTEGRITY**: All expected values (dep_ratio scores 25/20/15/10/5, language outputs
  `typescript|low|CLAUDE.md`, score=0 for empty dirs) are derived directly from
  implementation logic — not hard-coded guesses.
- **EXERCISE**: All tests call real implementation functions with real fixtures. No
  excessive mocking.
- **WEAKENING**: No existing tests were modified in ways that relax prior assertions.
  test_dep_ratio_boundary.sh was rewritten to extract the `dep_ratio` sub-score from the
  JSON detail field rather than the overall score, which is strictly more precise.
- **ISOLATION (live artifacts)**: None of the three test files read live pipeline artifacts
  (CODER_SUMMARY.md, REVIEWER_REPORT.md, BUILD_ERRORS.md, .claude/logs/*, etc.). All
  fixtures are created in mktemp directories.
- **SCOPE**: No orphaned, stale, or dead tests. All three test files exercise functions
  present in the current implementation.

---

### Implementation cross-reference verification
- `typescript|low|CLAUDE.md` — matches detect.sh:124 exactly (`_detected_output+="${_lower}|low|CLAUDE.md"$'\n'`)
- C# → csharp alias — matches detect.sh:123 (`[[ "$_lower" == "c#" ]] && _lower="csharp"`)
- dep_ratio scores (25/20/15/10/5) — match health_checks_infra.sh:103–108 tier logic exactly
- `extract_dep_ratio` targets `"dep_ratio":[0-9]+` — matches the JSON key in health_checks_infra.sh:139
- "Pre-code baseline" string — matches health.sh:285 verbatim
- Greenfield composite < 35 — verified: empty repo yields env_safety=20 (only sub-score
  with a non-zero default when .env is absent), composite = ⌊(20×15)/100⌋ = 3
- `_check_code_quality` score=0 for empty dir — confirmed: linter_score=0 (no linter
  configs), precommit_score=0, todo_score=0 (no sample files → outer `if` at
  health_checks.sh:176 skips the block), remaining sub-scores all file-presence-based = 0
