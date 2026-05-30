## Test Audit Report

### Audit Summary
Tests audited: 3 files, 14 test functions (5 in coverage_test.go, 9 in parse_runs_test.go, 28 bash assertions in test_m33_milestone_structure.sh)
Verdict: CONCERNS

---

### Findings

#### ISOLATION: Milestone structure test reads live project state files
- File: tests/test_m33_milestone_structure.sh:54-57
- Issue: The test reads `.claude/milestones/m33-dashboard-port.md`, `.claude/milestones/m33.1-dashboard-emitters.md`, `.claude/milestones/m33.2-dashboard-parsers.md`, and `.claude/milestones/MANIFEST.cfg` directly without creating fixture copies in a temp directory. Test pass/fail depends on the live pipeline state: AC1 (all four assertions) and AC3/AC4/AC5 for m33.1 all route through the `_m33_1_finalized()` guard because m33.1 is already `done` and its file was cleaned up by finalize. AC6 similarly passes via the MANIFEST `done` check. This means the test partially validates against the MANIFEST status column rather than the actual file content for the bulk of AC1–AC5. If run in a CI environment or after a state-resetting operation the test's behavior changes based on pipeline run history, not the committed source artifacts.
- Severity: HIGH
- Action: Extract the three milestone `.md` files and `MANIFEST.cfg` as committed fixture copies under `tests/fixtures/m33_milestone_structure/` and point the test's `MILESTONE_DIR` and `MANIFEST` variables at those copies. The milestone files are design-time authored artifacts checked into source; a fixture copy captures the intended state at audit time. Use `MANIFEST` fixture content to control exactly what the `_m33_X_finalized()` helpers see. This decouples the test from pipeline run state while still testing the structural properties.

#### INTEGRITY: Unconditional pass at line 240 inflates the pass count
- File: tests/test_m33_milestone_structure.sh:240
- Issue: After the real conditional check at lines 226–235 (which already calls `pass` or `fail` for the m33 parent's `status: "split"` claim), line 240 issues an additional unconditional `pass "m33 parent status verified via meta block (split)"` with no preceding condition. This always increments `PASS` regardless of what the actual check found. The comment above it says "positive check above is sufficient" — which implicitly acknowledges no real assertion is being made here. With m33 showing `done` in MANIFEST, the conditional block calls `pass "m33 parent split lifecycle completed..."` on line 232, and then line 240 fires another unconditional `pass`, inflating the reported PASS count by 1 for this suite. The inflated count obscures true coverage and could mask a future real failure in this area.
- Severity: MEDIUM
- Action: Remove line 240 entirely. The conditional check on lines 226–235 is the authoritative assertion. The explanatory comment (lines 237–239) is sufficient context; it does not need a redundant tautological pass statement to accompany it.

---

### Findings — coverage_test.go: None

All five test functions call real implementations with no excessive mocking:
- `TestWriteJSFile_ConcurrentAtomicity` exercises the tempfile+rename atomicity guarantee with 100 concurrent readers and 100 writers; the header prefix assertion is derived from the literal format string in `jsfile.go:51`.
- `TestEmitDiagnosis_WithFailureContext` plants a fixture JSON, calls the real `EmitDiagnosis`, parses the output file, and verifies fields (`available`, `classification`, `stage`, `summary`) derived directly from the planted fixture through `emit_diagnosis.go:38–43`.
- `TestEmitDiagnosis_MissingContext` and `TestEmitTeamState_ErrorOnEmptyTeamID` cover the fallback and error paths.
- `TestEmitTeamState_DelegatesToEmitRunState` verifies `parallel_mode:true` (correct given `ParallelTeams: []string{"t1"}` sets a non-empty team list) and team presence in the JSON output. All assertions are honest and derived from implementation logic.
All tests use `t.TempDir()` for isolation. No mutable project files read.

---

### Findings — parse_runs_test.go: None

All nine test functions are honest and well-isolated:
- `TestParseRunSummaries_FromMetricsJSONL`: the 3-record post-filter count, `got[0].RunType == "milestone"`, `got[1].Stages["reviewer"].Cycles == 2`, and `got[2].Stages["coder"].DurationS > 0` all derive directly from the four-line `testdata/parsers/runs/metrics.jsonl` fixture (verified against file) and the `recordToSummary`/`estimateMissingDurations` logic in `parse_runs.go`.
- `TestParseRunSummaries_FromRunSummaryFiles`: copies fixture files into `t.TempDir()` (correct; does not pollute testdata); assertions for `BuildFixOutcome`, `RecoveryRoute`, and the `total_agent_calls` fallback field all match the committed fixture JSON content (verified against `RUN_SUMMARY_20260402_12*.json` files).
- `TestEstimateMissingDurations`: the expected values 60 and 40 are computed from the formula `(totalTimeS*turns + totalTurns/2) / totalTurns` applied to the test inputs (100s total, turns 6 and 4, sum 10) — not hardcoded magic numbers.
- `TestParseMetricsJSONL_EmptyFile` and `TestParseMetricsJSONL_BlankLinesOnly`: correctly exercise the `TrimSpace`+empty-guard path and verify that `ParseRunSummaries` falls through to `parseRunSummaryFiles` when `len(rows) == 0`.
All tests use `t.TempDir()` or committed `testdata/` fixtures. No live project files accessed.
