## Test Audit Report

### Audit Summary
Tests audited: 2 files, 11 test functions
(5 pre-existing in orchestrator_test.go + 6 new; 5 cases in bash test)
Verdict: CONCERNS

### Findings

#### ISOLATION: _coder_declared_files falls back to mutable project file
- File: tests/test_is_path_allowed_manifest.sh:35-47
- Issue: The subshell calls `unset CODER_SUMMARY_FILE` so that
  `_coder_declared_files` contributes nothing to the allowlist. However,
  with `CODER_SUMMARY_FILE` unset, the function's fallback path is
  `.tekhton/CODER_SUMMARY.md` relative to the working directory
  (`local f="${CODER_SUMMARY_FILE:-.tekhton/CODER_SUMMARY.md}"`). If that
  file exists (it is a normal pipeline output artifact — `.tekhton/stage_results/`
  is already present in the working tree, confirming the pipeline has run),
  any paths it contains will silently expand the allowlist. Tests 4
  (`random_file.txt` must be denied) and 5 (`.claude/milestones/OTHER.cfg`
  must be denied) both depend on the absence of that file from the live repo
  state. If `.tekhton/CODER_SUMMARY.md` is present and happens to list either
  path, both "deny" assertions flip to FAIL; conversely, if a future change
  makes those paths legitimately appear in coder summaries the tests silently
  stop exercising the guard they were added to cover. The test comment claims
  "only the bookkeeping globs contribute to the allowlist" — that claim is not
  enforced by the implementation.
- Severity: HIGH
- Action: Replace `unset CODER_SUMMARY_FILE` with
  `export CODER_SUMMARY_FILE=/dev/null` inside the subshell. The fallback
  `[ -f "$f" ] || return 0` in `_coder_declared_files` will then hit a
  non-existent path and return empty unconditionally, making the isolation
  guarantee explicit and independent of working-tree state.

#### COVERAGE: Header lists tests/ prefix but no test case exercises it
- File: tests/test_is_path_allowed_manifest.sh:16
- Issue: The file header enumerates four covered bookkeeping dirs:
  ".tekhton/, internal/, cmd/, tests/". The test body has cases 3a
  (.tekhton/), 3b (internal/), and 3c (cmd/), but no case 3d for `tests/`.
  The glob entry `tests/` in `_pipeline_bookkeeping_globs` is untested.
- Severity: LOW
- Action: Add a case 3d:
  `_is_allowed_in_subshell "tests/test_is_path_allowed_manifest.sh"`
  and assert the result is "allowed". Brings the implementation in line with
  the header comment and adds a non-redundant test vector.

#### COVERAGE: No-op smoke test has zero behavioral assertions
- File: internal/finalize/orchestrator_test.go:225-230
  (TestOrchestrator_FinalizeActiveSentinel_NoProjectDir)
- Issue: The test comment explicitly states "No assertion needed — failure is
  a panic or sentinel file appearing somewhere unexpected." The test cannot
  detect incorrect behavior such as the function silently writing the sentinel
  to a relative path inside the real working directory — the exact scenario
  the test name implies it guards against.
- Severity: LOW
- Action: Add a post-call assertion that
  `os.Stat(".tekhton/.finalize_active")` returns `os.ErrNotExist`,
  anchoring the "no file written to a relative CWD path" contract. The
  sentinel lives under `in.ProjectDir` so with an empty ProjectDir there
  is nowhere to write it — but pinning this with an explicit check protects
  against future refactors that change the write path.
