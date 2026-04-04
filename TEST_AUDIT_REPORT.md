## Test Audit Report

### Audit Summary
Tests audited: 2 files, 23 test assertions (11 in test_prompt_tempfile.sh, 12 in test_drift_resolution_verification.sh)
Verdict: PASS

### Findings

#### COVERAGE: _extract_template_sections() untested in extracted module
- File: tests/test_prompt_tempfile.sh (whole file)
- Issue: `plan_batch.sh` contains two exported functions: `_call_planning_batch` (lines 30–110) and `_extract_template_sections` (lines 124–170). `test_prompt_tempfile.sh` covers only `_call_planning_batch`. `_extract_template_sections` — a 46-line awk program — was extracted from plan.sh with no direct test coverage in either audited file.
- Severity: LOW
- Action: Add tests for `_extract_template_sections` in a future pass (verify section name, required flag, guidance, and phase parsing against a fixture template). Not required to unblock this milestone since the function's behavior was not changed by this task, only its file location.

#### COVERAGE: Structural grep tests are necessary but not sufficient for Test 5 dependency chain
- File: tests/test_prompt_tempfile.sh:145–154
- Issue: Test 5 sources `plan.sh` via `source "${TEKHTON_HOME}/lib/plan.sh" 2>/dev/null || true`. At source time, `plan.sh` calls `load_plan_config` immediately (line 67 of plan.sh), then sources three sub-modules (lines 100–102). If any sub-module fails to source, the `|| true` silences the error and `_call_planning_batch` will be undefined. The subsequent call at line 154 (`output=$(_call_planning_batch ...) || true`) would then silently fail with "command not found", leaving `received_prompt.txt` uncreated, and line 156's guard would correctly catch this as a test failure — but the failure message ("Mock claude never received prompt") does not distinguish a sourcing failure from a functional failure. Verified: `lib/plan_answers_flow.sh` is present in the repo (listed in `git status` as an untracked new file), so this is not currently broken.
- Severity: LOW
- Action: Consider adding a sourcing guard: assert `declare -f _call_planning_batch` returns 0 immediately after sourcing, and fail with "plan.sh sourcing failed" if not. This makes the diagnostic message actionable.

#### SCOPE: test_drift_resolution_verification.sh Tests 1–6 test live repo state
- File: tests/test_drift_resolution_verification.sh:35–103
- Issue: Tests 1–6 assert structural properties of the actual `DRIFT_LOG.md` at `PROJECT_DIR` (which equals `TEKHTON_HOME` here). Test 3 in particular fails if the unresolved section ever contains both real entries and a `(none)` marker simultaneously — a valid transient state when drift notes are being resolved mid-pipeline. This is pre-existing behavior (the test was not written by this task), but it is worth noting that these tests are repo-state tests, not code-behavior tests. They will fail in any repo state where `DRIFT_LOG.md` is temporarily inconsistent during a pipeline run.
- Severity: LOW
- Action: No change needed now; the existing pipeline ensures DRIFT_LOG.md is consistent at any milestone boundary. Document that these tests should not be run mid-pipeline.

#### EXERCISE: Test 7 pattern extraction fragile to function restructuring
- File: tests/test_drift_resolution_verification.sh:111–124
- Issue: Test 7 locates `_display_milestone_summary` by line number (via `grep -n`), then extracts a 30-line window and greps for the literal string `^#{2,4}`. This works today because the pattern appears at line 30 of `plan_milestone_review.sh`, within the 30-line window. If `_display_milestone_summary` is restructured or the grep pattern is moved further than 30 lines from the function header, the test would silently return empty `GREP_PATTERN` and fail with "pattern should be ^#{2,4} but found: " — a confusing diagnostic.
- Severity: LOW
- Action: Replace the windowed sed extraction with a direct grep on the file: `GREP_PATTERN=$(grep -o '\^#{2,4}' "${TEKHTON_HOME}/lib/plan_milestone_review.sh" | head -1)`. Simpler and immune to line-count drift.

### Integrity Assessment

All test assertions derive their expected values from actual implementation behavior:

- Tests 1–4 in `test_prompt_tempfile.sh` grep for patterns that correspond directly to code present in `lib/plan_batch.sh` (lines 65, 83, 88) and `lib/agent_monitor.sh`. No hard-coded magic values.
- Test 5 uses a mock `claude` to exercise the real `_call_planning_batch` code path end-to-end, verifying stdin delivery of a >128KB prompt. The 131072-byte threshold is the correct `MAX_ARG_STRLEN` boundary.
- Tests 7–8 in `test_drift_resolution_verification.sh` verify both the presence of the corrected regex in the implementation (`plan_milestone_review.sh:30`) and that the regex behaves correctly against a synthetic fixture. The fixture correctly encodes all three heading depths (##, ###, ####) and the expected match counts (3 and 2) are derived from the regex semantics, not hard-coded.

No weakening of existing tests was found. No orphaned tests were found (the deleted file `JR_CODER_SUMMARY.md` is not imported or referenced by either audited test file).
