## Test Audit Report

### Audit Summary
Tests audited: 3 files, 32 test cases
Verdict: PASS

### Findings

#### COVERAGE: `_docs_extract_public_surface()` and `_docs_changed_files_match_surface()` are never called directly
- File: tests/test_docs_agent_skip_path.sh (all tests)
- Issue: Both internal helpers are tested only through `docs_agent_should_skip()`. There is no direct unit test verifying glob-style pattern matching (`*.sh`), multi-line pattern deduplication, or the fallback when the CLAUDE.md section exists but contains no extractable patterns (empty `ext_matches`, `path_matches`, `dir_matches`). An incorrect regex in the glob expansion path (`sed 's/\./\\./g; s/\*/.*/g'`) would not be caught by the existing tests since none of the fixtures use extension globs as changed files.
- Severity: LOW
- Action: Add one test case to `test_docs_agent_skip_path.sh` that uses a CLAUDE.md section with `*.sh` pattern and verifies that a changed `.sh` file is treated as a public-surface hit.

#### COVERAGE: `git diff --cached` (staged changes) fallback path is not exercised
- File: tests/test_docs_agent_skip_path.sh (all tests)
- Issue: `docs_agent_should_skip()` checks `git diff --name-only HEAD` first, then falls back to `git diff --cached --name-only`. All eight test cases use only unstaged modifications (`echo ... > file` without `git add`). The cached-only path (files staged but not yet committed, which is the state immediately after a coder agent runs) is untested. If the fallback branch were broken (e.g., wrong flag), no test would catch it.
- Severity: LOW
- Action: Add a test that stages a doc file with `git add` without committing and verifies that `docs_agent_should_skip()` returns 1 (run).

#### COVERAGE: `_docs_prepare_template_vars()` exports are invoked but never asserted
- File: tests/test_docs_agent_stage_smoke.sh:116–164 (Tests 3, 5)
- Issue: When the agent is called (Tests 3 and 5), `_docs_prepare_template_vars()` runs and exports `CODER_SUMMARY_CONTENT`, `DOCS_GIT_DIFF_STAT`, `DOCS_SURFACE_SECTION`, `DOCS_README_FILE`, `DOCS_DIRS`, `DOCS_AGENT_REPORT_FILE`. None of these are asserted post-call. If the function silently failed or exported empty strings for all variables, `run_stage_docs()` would still pass. The non-blocking design means this silent failure would go undetected.
- Severity: LOW
- Action: After a successful `run_stage_docs()` call in Test 3, assert that `DOCS_GIT_DIFF_STAT` is non-empty (the test repo has an unstaged README.md change) and that `DOCS_README_FILE` equals `"README.md"`.

#### COVERAGE: `PIPELINE_ORDER=standard + DOCS_AGENT_ENABLED=false` not tested
- File: tests/test_docs_agent_pipeline_order.sh:78
- Issue: Test 1.3 covers `test_first + DOCS_AGENT_ENABLED=false` (standard order is the implicit fallback), but `PIPELINE_ORDER=standard + DOCS_AGENT_ENABLED=false` is never explicitly asserted. The standard-disabled path is the default production configuration, so any regression in the base `PIPELINE_ORDER_STANDARD` constant would go undetected by this file.
- Severity: LOW
- Action: Add `PIPELINE_ORDER=standard DOCS_AGENT_ENABLED=false` → assert `get_pipeline_order` returns `"scout coder security review test_verify"`.

#### COVERAGE: `should_run_stage "docs" "docs"` (self-resume) not tested
- File: tests/test_docs_agent_pipeline_order.sh:126–159
- Issue: Phases 4 and 5 test docs skipping and running relative to other stages, but never test `--start-at docs` (i.e., `should_run_stage "docs" "docs"`). This maps to `stage_pos(3) >= start_pos(3)` → true. While the implementation handles it correctly by the generic position comparison, this resume scenario is undocumented by any test.
- Severity: LOW
- Action: Add one `assert_true "should_run_stage: docs runs when start_at=docs"` case to both Phase 4 and Phase 5.

#### COVERAGE: `PIPELINE_ORDER=auto` fallback with docs not tested
- File: tests/test_docs_agent_pipeline_order.sh:56
- Issue: `get_pipeline_order()` falls through to the `standard` branch for `auto` (and any unrecognized value). No test verifies that `PIPELINE_ORDER=auto + DOCS_AGENT_ENABLED=true` correctly inserts the docs stage. If the `auto` case were accidentally made a `;;` break instead of a fall-through, it would silently omit docs insertion.
- Severity: LOW
- Action: Add `PIPELINE_ORDER=auto DOCS_AGENT_ENABLED=true` → assert `get_pipeline_order` returns `"scout coder docs security review test_verify"`.

### No Issues Found In These Categories

**INTEGRITY:** All 32 assertions derive expected values directly from implementation constants
(`PIPELINE_ORDER_STANDARD`, `PIPELINE_ORDER_TEST_FIRST`, config defaults) and documented
logic. No hard-coded magic values detached from implementation logic were found. The
`run_agent` stub in the smoke test captures `"$1|$2|$3"` (name|model|turns), and the
assertions verify these match the config variables in scope — not hard-coded strings.

**EXERCISE:** All three test files source and call the real implementation functions with no
mocking of the functions under test. `run_agent` in the smoke test is legitimately stubbed
because the audit scope is stage orchestration behavior, not agent invocation fidelity.
`log/warn/success/error/header` stubs are appropriate — they are logging side effects, not
behavioral output. `docs_agent_should_skip()` is called with a real git repo and real
CLAUDE.md fixtures, not mocked.

**ISOLATION:** No test reads mutable project state. All three files create their own
fixtures in `mktemp -d` temp directories with `trap 'rm -rf "$TEST_TMPDIR"' EXIT` cleanup.
The pipeline_order test uses only variable assignments — no filesystem reads beyond
sourcing the implementation files. No `.tekhton/` reports, `.claude/logs/`, or pipeline
run artifacts are accessed by any test.

**WEAKENING:** All three test files are new (untracked per git status at audit time). No
pre-existing test assertions were removed or broadened. N/A.

**NAMING:** All 32 test cases encode both the scenario and the expected outcome. Examples:
`"=== Test 4: internal-only changes → skip ==="`,
`"4.1 should_run_stage: docs skipped when start_at=security (standard+docs)"`,
`"returns 0 even when agent fails (non-blocking)"`. No opaque names detected.

**SCOPE:** All functions under test exist in the implementation files as modified for M75:
`docs_agent_should_skip()` in `lib/docs_agent.sh`, `run_stage_docs()` in `stages/docs.sh`,
`get_pipeline_order/get_stage_count/get_stage_position/should_run_stage()` in
`lib/pipeline_order.sh`. No orphaned or stale references found.
