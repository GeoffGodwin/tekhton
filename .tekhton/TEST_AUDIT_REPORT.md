## Test Audit Report

### Audit Summary
Tests audited: 4 files (test_m84_tekhton_dir_complete.sh, test_m84_static_analysis.sh,
test_index_structured.sh, test_structured_index.sh), ~154 test assertions
Verdict: PASS

### Findings

#### COVERAGE: migration_apply git-mv code path not exercised
- File: tests/test_m84_tekhton_dir_complete.sh:171-225 (Suite 4)
- Issue: Suite 4 creates a temp directory with no git repo. When `migration_apply`
  calls `_move_preserving_history`, the `git ls-files --error-unmatch` check fails
  silently (no git repo), so the `mv` fallback is always taken. The `git mv` branch
  (for files tracked in a git repo) is never executed. If a project has tracked files
  at root when the migration runs, the `git mv` path runs in production and could
  fail silently while tests always pass.
- Severity: LOW
- Action: Add a second Suite 4 variant that runs `git init && git add && git commit`
  in the fixture directory before placing M84 files, so both branches of
  `_move_preserving_history` are exercised.

#### COVERAGE: migration_apply idempotency not tested
- File: tests/test_m84_tekhton_dir_complete.sh:190
- Issue: Suite 4 runs `migration_apply` once and verifies files moved. The function
  has a `[[ -e "$dst" ]] && continue` guard for idempotency, but calling it a second
  time (when destination files already exist) is never tested. A regression in the
  guard could cause mv to clobber content or error on a second run.
- Severity: LOW
- Action: After Suite 4's assertions, call `migration_apply "$s4_dir"` a second time
  and assert it returns 0 and file contents are unchanged (idempotency check).

#### ISOLATION: Suite 3 sources common.sh without logging stubs
- File: tests/test_m84_tekhton_dir_complete.sh:145
- Issue: Suite 3 calls `source "${TEKHTON_HOME}/lib/common.sh"` in the main test
  process without first defining no-op stubs for `log`, `warn`, `success`, `header`,
  and `error`. Every other test file that sources lib modules (test_dry_run.sh:20-25,
  test_crawler_budget.sh:18-22, test_artifact_handler_ops.sh:18-22, both index tests)
  defines these stubs before sourcing. If common.sh ever emits output on source (e.g.,
  a deprecation warning), Suite 3's stdout will be polluted and the test may fail or
  produce misleading output. Currently harmless — common.sh only defines functions and
  color variables — but inconsistent with established convention.
- Severity: LOW
- Action: Add the five standard no-op stubs before line 145, following the same
  pattern used by the other four test files in this suite.

### Detailed Rubric Assessment

**1. Assertion Honesty — PASS**

All assertions trace to real implementation behavior with no hard-coded values.

- test_m84_tekhton_dir_complete.sh Suites 1–2: spawn `env -i bash` subshells that
  source the actual `lib/config_defaults.sh`; captured stdout is compared against the
  exact strings produced by the real code. Cross-checked: config_defaults.sh lines
  80–86 confirm all 7 M84 `_FILE` defaults are exactly `${TEKHTON_DIR}/FILENAME.md`.
- test_m84_tekhton_dir_complete.sh Suite 3: reads raw text of `migrations/003_to_031.sh`
  and checks for filename strings. Cross-checked: migration script lines 48–49 confirm
  all 7 filenames appear in the `files` array.
- test_m84_tekhton_dir_complete.sh Suite 4: calls `migration_apply` on a temp fixture
  and checks actual filesystem state after the call. Assertions reflect what `mv` does
  in the fixture context.
- test_m84_static_analysis.sh: all suites use `grep` over actual source files in the
  live Tekhton repo. Verified against implementation: no literal M84 filenames exist
  in `lib/` (excluding config_defaults.sh and common.sh), `stages/`, `tekhton.sh`, or
  `prompts/`. The specialist findings pattern `TEKHTON_DIR.*SPECIALIST.*FINDINGS\.md`
  matches the actual construction in specialists.sh:111, 136, 166 and
  specialists_helpers.sh:18, 33.
- test_index_structured.sh and test_structured_index.sh: all assertions test real
  `crawl_project`, `rescan_project`, `generate_project_index_view`, and `read_index_*`
  function output against filesystem state. No tautological checks found.

**2. Edge Case Coverage — PASS**

- Config defaults: default TEKHTON_DIR, custom TEKHTON_DIR, negative check (no bare
  root-relative default for SCOUT_REPORT_FILE, PROJECT_INDEX_FILE).
- Migration: all 7 M84 files moved, CLAUDE.md preserved at root (positive + negative
  file existence checks for all 8 files involved).
- Static analysis: all 7 M84 filenames checked across 4 surfaces (lib, stages,
  tekhton.sh, prompts), specialist findings prefix, and common.sh defaults.
- Structured index: full crawl, budget compliance at 4 sizes, rescan-add, rescan-delete,
  rescan-dep-change, forced full crawl, legacy migration (no .claude/index/), empty
  project, special-character JSON escaping, Cargo.toml detection (Rust ecosystem).
- Two LOW findings above: git-mv branch and idempotency not covered (see Findings).

**3. Implementation Exercise — PASS**

All four test files source real implementation modules and call real functions.
Mocking is limited to no-op logging stubs (log/warn/success/header/error), which
are output-only functions with no logic to verify. The `env -i` subshells in Suites
1–2 of test_m84_tekhton_dir_complete.sh prevent environment contamination while still
loading real code.

**4. Test Weakening Detection — PASS**

Two pre-existing test files were modified (test_index_structured.sh,
test_structured_index.sh). In both cases the changes were additive only:
- Lines 25–35 and 26–35 respectively: added `:= default` guards for the 7 M84 `_FILE`
  vars so tests self-initialize when run standalone without inheriting pipeline env state.
- A corresponding `mkdir -p "${PROJ}/.tekhton"` was added where needed so
  `generate_project_index_view` can write to the new default path.

No assertions were removed, no expected values were broadened, and no edge-case tests
were deleted in either file.

**5. Test Naming and Intent — PASS**

Assertion labels encode both scenario and expected outcome throughout:
- "1.1 SCOUT_REPORT_FILE defaults under .tekhton/" — variable + expected location
- "2.8 SCOUT_REPORT_FILE not at project root" — variable + expected absence of behavior
- "4.12 CLAUDE.md stays at root" — file + expected non-migration
- "5.1 specialists_helpers.sh: no TEKHTON_DIR prefix in findings path" — file + failure message
- Suite echo headers (e.g., "--- Suite 2: custom TEKHTON_DIR respected for M84 variables ---")
  provide context for the assertions that follow.

No anonymous or meaningless test names found.

**6. Scope Alignment — PASS**

M84's task is completing TEKHTON_DIR migration: 7 new transient `_FILE` vars defaulted
under `${TEKHTON_DIR}/`, literal references eliminated from lib/stages, migration script
updated, and common.sh defensive defaults added. The tests exercise exactly these four
surfaces:
- config_defaults.sh: Suites 1–2 of test_m84_tekhton_dir_complete.sh
- migrations/003_to_031.sh: Suites 3–4 of test_m84_tekhton_dir_complete.sh
- lib/ and stages/ regression guard: all 4 suites of test_m84_static_analysis.sh
- common.sh defaults: Suite 6 of test_m84_static_analysis.sh
- Downstream consumers (crawler, index view, rescan): test_index_structured.sh,
  test_structured_index.sh M84 placement assertions

No orphaned tests detected. The deleted `.tekhton/JR_CODER_SUMMARY.md` file does not
appear in any test file under audit. `JR_CODER_SUMMARY_FILE` variable and its default
in config_defaults.sh remain present and untouched; only the physical file was removed.

**7. Test Isolation — PASS (with LOW findings above)**

All four test files create their own `mktemp -d` fixtures with `trap 'rm -rf ...' EXIT`
cleanup. No test reads live pipeline output files (CODER_SUMMARY.md, TESTER_REPORT.md,
BUILD_ERRORS.md, DRIFT_LOG.md, etc.) from the project directory.

The `env -i bash` subshells in Suites 1–2 of test_m84_tekhton_dir_complete.sh are
hermetically isolated — only TEKHTON_DIR is passed in Suite 2, and nothing is inherited
in Suite 1. Suite 4's git-free fixture prevents side effects on the actual Tekhton repo
while `migration_apply` runs. The static analysis tests read only static source files,
not mutable pipeline state.

The logging-stub inconsistency (LOW finding above) is a convention gap, not a
data-isolation failure.
