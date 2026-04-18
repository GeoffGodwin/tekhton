## Test Audit Report

### Audit Summary
Tests audited: 4 files, 41 test assertions
Verdict: PASS

### Findings

#### COVERAGE: No-jq fallback path misses two required-key checks
- File: tests/test_tui_no_dead_weight.sh:74-88
- Issue: The `jq`-based branch (lines 43-71) verifies four properties: `"stage"` key absent, `"stage_label"` present, `"stage_num"` present, `"stage_total"` present. The no-`jq` fallback at lines 74-88 only checks `"stage"` absent and `"stage_label"` present. In CI environments without `jq`, removal of `stage_num` or `stage_total` from `_tui_json_build_status` output would go undetected.
- Severity: LOW
- Action: Add `grep -q '"stage_num"'` and `grep -q '"stage_total"'` string checks to the fallback branch to mirror the `jq` path.

#### EXERCISE: Array export has no effect in command substitution subshell
- File: tests/test_tui_no_dead_weight.sh:26
- Issue: `export _TUI_RECENT_EVENTS` does not propagate the array into the subshell forked by `json_output=$(_tui_json_build_status 0)` — bash does not export arrays across fork boundaries. In the subshell `_TUI_RECENT_EVENTS` is effectively unset. The function handles this gracefully via `${_TUI_RECENT_EVENTS[@]:-}` and produces `[]`, consistent with the test making no assertions about `recent_events`. The test passes correctly and the output is still valid JSON. The `export` is however misleading: if a future test extends this file to assert on event content, the array will silently be empty.
- Severity: LOW
- Action: Remove the `export _TUI_RECENT_EVENTS` line and add a comment noting that scalar globals are subshell-exported but arrays are not; tests asserting on `recent_events` content must call the function in the same shell scope.

#### SCOPE: Audit metadata lists pre-existing test as "modified this run"
- File: tests/test_save_orchestration_state.sh
- Issue: The audit context includes this file under "Test Files Under Audit (modified this run)", but `git status` does not list it as modified or untracked — it is a pre-existing tracked test that was not changed in this run. The TESTER_REPORT.md correctly identifies it as "Pre-existing test (already passing)". No defect in the test content itself; this is a metadata inconsistency in the audit harness input.
- Severity: LOW
- Action: None required for the test. The audit harness may be conflating "files whose coverage is relevant to this run" with "files actually written or modified by the tester"; these lists should be kept distinct.

### Non-Findings

#### INTEGRITY (PASS)
All assertions derive expected values from real implementation calls or from fixture data written in the test itself. No hard-coded magic values disconnected from implementation logic, no always-true assertions, and no tests that mock every dependency and never exercise real code.

#### WEAKENING (PASS)
`test_save_orchestration_state.sh` (pre-existing) was not modified by the tester. The three new test files (`test_rule_max_turns_consistency.sh`, `test_tui_no_dead_weight.sh`, `test_archive_reports_behavior.sh`) add coverage; no prior assertions were removed or broadened.

#### ISOLATION (PASS)
All three test files that touch the filesystem create fixture data in a `$(mktemp -d)` directory guarded by `trap 'rm -rf "$TMPDIR"' EXIT`. All pipeline file path variables (`PIPELINE_STATE_FILE`, `REVIEWER_REPORT_FILE`, `TESTER_REPORT_FILE`, etc.) are redirected to TMPDIR. No live project files under `.tekhton/`, `.claude/`, or `logs/` are read directly. `test_tui_no_dead_weight.sh` performs no file I/O at all.

#### NAMING (PASS)
Assertion labels encode both scenario and expected outcome (e.g., `"A.1 no artifacts: resume_flags contains --start-at coder"`, `"Test 3: Missing section returns empty string (consistent)"`). File names match the notes they cover.

### Implementation Cross-Reference

| Test file | Implementation exercised | Key assertions verified |
|-----------|--------------------------|------------------------|
| `test_save_orchestration_state.sh` | `_save_orchestration_state` + `_choose_resume_start_at` (`lib/orchestrate_helpers.sh:188-283`) + `write_pipeline_state` (`lib/state.sh:30`) | Resume flags derive from `_RESUME_NEW_START_AT` per `orchestrate_helpers.sh:189-219`; `| Restored` Notes augmentation derives from `_RESUME_RESTORED_ARTIFACT` at `orchestrate_helpers.sh:260-261`; `## Resume Command` and `## Notes` sections confirmed in `state.sh:69-76`. All assertions match observed implementation behavior. |
| `test_rule_max_turns_consistency.sh` | `_read_diagnostic_context` (`lib/diagnose.sh:58`) + inline `awk` pattern from `_rule_max_turns` (`lib/diagnose_rules.sh:91`) | Both code paths use identical `awk '/^## Exit Reason$/{getline; print; exit}'`; confirmed at `diagnose.sh:85` and `diagnose_rules.sh:91`. Consistency assertion is meaningful: silent divergence would misroute diagnoses. |
| `test_tui_no_dead_weight.sh` | `_tui_json_build_status` (`lib/tui_helpers.sh:84`) | Implementation at `tui_helpers.sh:114-138` emits no `"stage":` key; `"stage_label"`, `"stage_num"`, `"stage_total"` all confirmed present. Assertions match observed output format. |
| `test_archive_reports_behavior.sh` | `archive_reports` (`lib/hooks.sh:14`) | Implementation at `hooks.sh:20-25`: iterates known file variables, `cp`s existing files, silently skips missing. Assertions for file presence, content fidelity, zero stdout/stderr output, and skip-on-missing all match implementation. |
