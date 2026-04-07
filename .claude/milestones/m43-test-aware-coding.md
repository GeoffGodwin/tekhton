# Milestone 43: Test-Aware Coding
<!-- milestone-meta
id: "43"
status: "done"
-->

## Overview

50% of milestone runs fail self-tests at the end of the pipeline, triggering
expensive full pipeline reruns. Root cause analysis reveals a fundamental gap:
**no agent is responsible for updating existing tests when code changes break
them.** Scout doesn't identify test files. Coder runs tests but has no mandate
to fix what it breaks. Tester is explicitly forbidden from modifying existing
tests. The result: test breakage is discovered only at the pre-finalization gate,
where it triggers the most expensive recovery path (full Coder→Reviewer→Tester
retry).

This milestone closes the gap by making Scout identify affected test files and
making Coder responsible for maintaining tests it breaks — without adding any
new agents or pipeline stages.

Depends on Milestone 42 (Tag-Specialized Execution Paths) for the tag-aware
coder prompt structure that this milestone extends with test context.

## Scope

### 1. Scout Test File Discovery

**File:** `prompts/scout.prompt.md`

Add `## Affected Test Files` section to the SCOUT_REPORT.md output format.
Scout identifies test files that exercise the files-to-modify using:

- **Naming conventions:** `test_foo.sh` → `foo.sh`, `foo_test.go` → `foo.go`,
  `test_foo.py` → `foo.py`, `foo.spec.ts` → `foo.ts`
- **Repo map cross-references:** When `REPO_MAP_CONTENT` is available,
  tree-sitter shows imports/calls — test files that reference changed functions
  are discoverable
- **Serena LSP:** When `SERENA_ACTIVE`, use `find_referencing_symbols` to find
  test functions that call symbols in changed files

The Scout report output format gains:

```
## Affected Test Files
- tests/test_foo.sh — tests functions in lib/foo.sh (naming convention)
- tests/test_bar.sh — calls validate_config() which is modified (cross-reference)
```

### 2. Coder Test Maintenance Mandate

**File:** `prompts/coder.prompt.md`

Add explicit instruction after the existing "Run TEST_CMD" step:

> **Test maintenance:** If your changes cause existing tests to fail, you MUST
> update those tests to match your new implementation — unless the failing test
> reveals a bug in YOUR code, in which case fix your code instead. Do not skip,
> delete, or weaken test assertions. The Scout report below identifies test files
> likely affected by your changes — check these first.

Inject two new context blocks:
- `AFFECTED_TEST_FILES` — extracted from Scout's `## Affected Test Files` section
- `TEST_BASELINE_SUMMARY` — pre-change test baseline showing what was passing
  before (already captured by `lib/test_baseline.sh`, just not currently injected)

### 3. Coder Stage — Extract Affected Test Files

**File:** `stages/coder.sh`

After Scout report is parsed, extract the `## Affected Test Files` section and
export it as `AFFECTED_TEST_FILES` for prompt template rendering. Also export
`TEST_BASELINE_SUMMARY` from the baseline captured at run start.

### 4. Tester Prompt — Allow Intentional API Updates

**File:** `prompts/tester.prompt.md`

Change the existing rule from:
> Do NOT weaken existing tests to make them pass. If a test fails because the
> implementation changed, REPORT THE BUG — do not fix the test.

To:
> If existing tests fail due to intentional API/behavior changes that the Coder
> already implemented correctly, update the tests to match the new behavior.
> If they fail because the implementation is wrong, report as BUG. Never weaken
> assertions or delete test coverage — update expectations to match correct new
> behavior.

## Acceptance Criteria

- Scout report includes `## Affected Test Files` section with file paths and
  reasoning for each
- Coder prompt includes test maintenance mandate and affected file list
- Coder receives pre-change test baseline summary in prompt context
- Tester can update existing tests for intentional API changes without reporting
  them as bugs
- No new agents added; no new pipeline stages
- No increase in Scout or Coder turn budgets (the work fits within existing budgets)
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n` and `shellcheck` pass on all modified files

Tests:
- Scout report parser correctly extracts `## Affected Test Files` section
- `AFFECTED_TEST_FILES` is populated when Scout report contains the section
- `AFFECTED_TEST_FILES` is empty when Scout report lacks the section (graceful)
- `TEST_BASELINE_SUMMARY` is injected when baseline exists
- Template rendering includes test context blocks when populated

Watch For:
- Scout is on Haiku — the test file discovery must be simple enough for a
  cheaper model. Don't over-engineer the cross-reference analysis; naming
  conventions alone catch 80% of cases.
- The Coder might over-correct and start modifying tests unnecessarily. The
  prompt must be clear: only fix tests YOUR changes broke, don't refactor
  unrelated tests.
- `TEST_BASELINE_SUMMARY` could be large. Truncate to a summary (pass count,
  fail count, list of passing test names) rather than injecting full output.
- The tester prompt relaxation must not allow weakening assertions. The
  distinction is: update expected values for intentional changes vs. deleting
  or loosening assertions to hide bugs.

Seeds Forward:
- Milestone 44 (Jr Coder Test-Fix Gate) is the safety net for whatever this
  milestone doesn't catch
- Milestone 46 (Instrumentation) will measure the reduction in test failures
  at the pre-finalization gate
