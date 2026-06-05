## Test Audit Report

### Audit Summary
Tests audited: 1 file, 5 assertions (procedural bash — 3 scenarios + 1 AC grep + 1 regression guard)
Verdict: PASS

### Findings

#### EXERCISE: Export-chain integration gap
- File: tests/test_commit_subject_fallback.sh:214–223
- Issue: The Goal 2 path is split across two separate checks that do not compose into an end-to-end verification. Scenario 2 (line 185) passes `"44"` as `$2` directly to `generate_commit_message`, confirming the downstream milestone-title logic works. The AC grep (line 217) confirms the three `export` lines exist in `orchestrate_save.sh`. Neither check verifies the full chain: `_orch_record_save_state` exports → `finalize_run 1` spawns subprocess → `_hook_commit` reads env → forwards to `generate_commit_message` as `$2`. An adversarial implementation could export the variables to a different scope or after the `finalize_run 1` call and both existing checks would still pass. The CODER_SUMMARY explicitly acknowledges this tradeoff ("The export → env-inheritance → $2 chain is bash-local and tested separately via the grep assertion") and justifies the design on test speed grounds — acceptable for a bash-level regression test.
- Severity: MEDIUM
- Action: No immediate action required — the tradeoff is sound and documented. A future shim-boundary integration test (following the `test_state_writer_resume_fields.sh` pattern) that drives `_orch_record_save_state` end-to-end with a real finalize invocation would close this gap. Defer to a follow-on milestone.

#### INTEGRITY: AC grep does not verify ordering relative to `finalize_run 1`
- File: tests/test_commit_subject_fallback.sh:217–223
- Issue: `grep -cE "^[[:space:]]*export (TASK|_CURRENT_MILESTONE|MILESTONE_MODE)" lib/orchestrate_save.sh` counts occurrences of the three export lines anywhere in the file. An implementation that placed the exports *after* `finalize_run 1` (line 36 of orchestrate_save.sh) would pass this assertion while being functionally broken — the subprocess spawned by `finalize_run 1` would not inherit the variables. The current implementation places them correctly at lines 32–34, so this is not a current defect, only a future fragility.
- Severity: LOW
- Action: Acceptable as-is. If a future refactor moves the exports, the behavioral gap would surface in production before this check catches it. A more precise assertion would use `awk` to verify the exports precede `finalize_run 1` in the file; worth considering if `orchestrate_save.sh` is heavily modified in a future milestone.

#### COVERAGE: No test for empty-diff path after m44 sort logic
- File: tests/test_commit_subject_fallback.sh (no specific line)
- Issue: No scenario exercises `generate_commit_message` when `git diff HEAD --stat` produces no output (e.g., immediately after a commit with a clean working tree). In that case, `subject` remains `"${prefix}: changes pending"` and the sort-by-lines branch at hooks.sh:187–195 never fires. This is a pre-existing coverage gap — the m44 change only touches the non-empty diff branch — and the `"changes pending"` stub was present before m44 and is unchanged.
- Severity: LOW
- Action: No action required for m44. If the `"changes pending"` stub subject appears in production, add a scenario to a follow-on test.

### No findings in these categories
- **ISOLATION**: The three git-repo scenarios each create and use independent throwaway repos under `$_TEST_TMPDIR` (line 31) with `trap 'rm -rf "$_TEST_TMPDIR"' EXIT` (line 32). No pipeline artifacts (`.tekhton/*.md`, `.claude/logs/*`) are read without fixture isolation. The AC grep reads `lib/orchestrate_save.sh` — a source file under test, not a pipeline-state artifact — consistent with the shim-boundary integration test pattern documented in CLAUDE.md.
- **WEAKENING**: No existing tests were modified. The TESTER_REPORT notes a TMPDIR shadowing rename — a non-weakening refactor with no assertion changes.
- **SCOPE**: The deleted file `.tekhton/stage_results/stage_tester_r1_b0.json` is not referenced in the new test. No orphaned imports or stale symbol references found.
- **NAMING**: Bash procedural style — no test function names to evaluate. Scenario comments and pass/fail messages are specific and encode both the scenario and expected outcome (e.g., "scenario 1: subject picks the most-changed file", "scenario 1 AC: subject does not contain 'project_version.cfg'").
- **ASSERTION HONESTY**: All assertions derive their expected values from inputs supplied to the function under test or from the fixture data seeded in the temp repo. The project_version.cfg exclusion guard (line 169) is a meaningful negative assertion verifying the fix, not a tautology. The milestone-title assertion (line 188) checks for a string that was seeded into the temp CLAUDE.md, not a hard-coded magic value.
