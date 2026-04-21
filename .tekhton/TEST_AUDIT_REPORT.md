## Test Audit Report

### Audit Summary
Tests audited: 2 files, ~103 test assertions
  - `tests/test_pipeline_order_m110.sh` — 53 assertions across 18 phases
  - `tests/test_tui_stage_wiring.sh` — 50 assertions across 18 test cases (6 legacy + 12 M110)
Verdict: PASS

### Findings

#### COVERAGE: tui_hold.py event-type partitioning not covered by any audited test file
- File: `tools/tui_hold.py` (implementation changed — Blocker 3 per CODER_SUMMARY.md)
- Issue: The coder split `recent_events` into `runtime_events` / `summary_events` in `_hold_on_complete`. Neither audited test file exercises Python-level rendering. Tests M110-9/10/11 confirm the bash ring buffer stores the `type` field correctly, but whether the hold view partitions and renders those events into the correct blocks is untested. `tools/tests/test_tui.py` was not listed as modified and is outside this audit's scope.
- Severity: MEDIUM
- Action: Add Python tests in `tools/tests/test_tui.py` for `_hold_on_complete` verifying that events with `"type":"runtime"` appear only in the `[bold]Event log:[/bold]` section and events with `"type":"summary"` appear only in the `[bold]Run summary:[/bold]` section, with timestamps suppressed in the summary block.

#### COVERAGE: preflight lifecycle FAILED branch not tested
- File: `tekhton.sh` (implementation changed — Blocker 4 per CODER_SUMMARY.md)
- Issue: The new `tui_stage_begin "preflight"` / `tui_stage_end "preflight"` wiring in `run_preflight_checks` is not exercised by the shell test files. The TUI protocol API is thoroughly tested in M110-1 through M110-6 and `get_stage_policy "preflight"` is asserted in Phase 4 of `test_pipeline_order_m110.sh`. The uncovered integration path is the failure branch: `tui_stage_end "preflight" "" "" "" "FAILED"` before `exit 1` is never triggered in these tests. If a regression dropped the `FAILED` verdict or omitted the `tui_stage_end` call on the failure path, no test would catch it.
- Severity: LOW
- Action: Add a test in `tests/test_tui_stage_wiring.sh` that calls `tui_stage_begin "preflight"` followed by `tui_stage_end "preflight" "" "" "" "FAILED"` and asserts the `stages_complete` record for preflight carries `"verdict":"FAILED"`.

#### NAMING: TESTER_REPORT assertion count inconsistent with test file content
- File: `.tekhton/TESTER_REPORT.md`
- Issue: TESTER_REPORT reports "Passed: 94  Failed: 0". Manual audit counts ~103 assertions in the current test files: 53 in `test_pipeline_order_m110.sh` and 50 in `test_tui_stage_wiring.sh`. The 9-assertion gap indicates the report was captured before the test files reached their current state. This is informational only; the assertion logic itself is sound.
- Severity: LOW
- Action: Re-run both test files and update TESTER_REPORT with the actual pass/fail counts.

#### SCOPE: Shell orphan detector false positives for builtins in test_tui_stage_wiring.sh
- File: `tests/test_tui_stage_wiring.sh`
- Issue: The pre-verified orphan list flags `:`, `awk`, `cat`, `cd`, `dirname`, `echo`, `mkdir`, `mktemp`, `pwd`, `set`, `source`, and `trap` as "not found in any source definition". All are POSIX shell builtins or standard system utilities, not user-defined functions. These are false positives from the symbol-level detector's inability to exclude builtins.
- Severity: LOW
- Action: No test changes required. The orphan detector should be enhanced to exclude POSIX builtins and well-known utilities (awk, grep, python3, mktemp, etc.) from its stale-symbol scan.

### Notes

**Assertion honesty — verified clean.** All expected values in both test files are derived from the actual implementation source, not hard-coded. Phase 1–3 of `test_pipeline_order_m110.sh` assert `get_stage_metrics_key` outputs against the exact `case` branches in `pipeline_order.sh:244–252`. Phase 4–6 assert `get_stage_policy` records against the exact `case` body in `pipeline_order.sh:267–281`. Phase 7–18 assert `get_run_stage_plan` by tracing the conditional assembly in `pipeline_order.sh:304–338`, including boundary conditions (drift count at/equal/below threshold in Phase 13, runs-since threshold in Phase 14) and flag combinations (Phase 18). Tests M110-1 through M110-12 assert in-memory TUI globals (`_TUI_STAGE_CYCLE`, `_TUI_CURRENT_LIFECYCLE_ID`, `_TUI_CLOSED_LIFECYCLE_IDS`, `_TUI_STAGES_COMPLETE`, `_TUI_RECENT_EVENTS`, `_OUT_CTX`) against live implementations in `tui_ops.sh:147–297` and `output.sh:44–48`. No tautologies or hard-coded magic values were found.

**No test weakening.** Tests 1–6 in `test_tui_stage_wiring.sh` are unchanged or strengthened relative to their pre-M110 form. Test 3 gained a new pill-count assertion (`rework_pill_count == 0`) enforcing the M110 sub-stage policy without removing the prior `stages_complete` count assertion. No removed assertions or broadened expected values were detected.

**Isolation — clean.** `tests/test_tui_stage_wiring.sh` creates a `mktemp -d` TMPDIR on entry and cleans it via `trap 'rm -rf "$TMPDIR"' EXIT`. The M110 sub-tests use `_activate_m110` with `_TUI_STATUS_FILE=""` to eliminate file I/O entirely. `tests/test_pipeline_order_m110.sh` operates purely in-process with no file I/O. Neither file reads from `.tekhton/`, `.claude/logs/`, or any mutable pipeline run artifact.

**Implementation exercise — real.** Both files source and invoke the actual implementation. `test_pipeline_order_m110.sh` sources `lib/common.sh` and `lib/pipeline_order.sh` directly. `test_tui_stage_wiring.sh` sources `lib/tui.sh` (which chains `tui_helpers.sh` and `tui_ops.sh`), `lib/pipeline_order.sh`, and `lib/output.sh`. No dependency mocking; all assertions reflect real function behavior.
