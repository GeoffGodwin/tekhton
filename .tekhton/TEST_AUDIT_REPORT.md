## Test Audit Report

### Audit Summary
Tests audited: 2 files, 10 test functions
- `internal/runner/resume_test.go` — 10 functions total; 3 new (m40.1): `TestRequestFromSnapshotAutoAdvanceFields`, `TestRequestFromSnapshotAutoAdvanceBackwardCompat`, `TestStateSnapshotAutoAdvanceJSONRoundTrip`
- `tests/test_state_writer_resume_fields.sh` — new file; 8 assertions across 4 scenarios (bash-fallback on/off, Go-path on/off)

Verdict: PASS

### Findings

#### COVERAGE: Go-path backward-compat does not check auto_advance_limit absence
- File: `tests/test_state_writer_resume_fields.sh:159-167`
- Issue: The Go-path backward-compat block asserts only that `auto_advance` is empty when `AUTO_ADVANCE` is unset. It does not assert that `auto_advance_limit` is also absent via `tekhton state read --field auto_advance_limit`. The bash-fallback backward-compat block (lines 106–114) covers both fields; the Go-path block covers only one. If a future change accidentally emitted `auto_advance_limit` on unrelated writes, only the bash-fallback path would catch it.
- Severity: LOW
- Action: After line 165, add a `tekhton state read --field auto_advance_limit` check against `$_GO_FILE_OFF` and assert the result is empty, mirroring the pattern already present for `auto_advance`.

#### COVERAGE: AUTO_ADVANCE=false explicit-false boundary not exercised
- File: `tests/test_state_writer_resume_fields.sh` (no existing scenario)
- Issue: `_state_write_snapshot` (state_helpers.sh:61) gates emission on `[[ "${AUTO_ADVANCE:-}" = "true" ]]`, so the explicit string `"false"` is treated the same as unset and the field is omitted. No test passes `AUTO_ADVANCE=false` to confirm this. The risk is subtle: if a caller ever passes the raw variable value directly into `--field auto_advance=$AUTO_ADVANCE` (instead of the derived `auto_advance_field` local), `applyField` (state.go:189–196) would write `false` to the snapshot — a regression only this missing case would catch.
- Severity: LOW
- Action: Add a third bash-fallback scenario calling `_write_with_env "$file" "false" "" "true"` and asserting `auto_advance` is absent from the output JSON. One new scenario block parallel to the existing backward-compat block.

None: No HIGH findings.

### Rubric Assessment

**Assertion Honesty — PASS.**
All assertions derive from real function calls. In `resume_test.go`, the expected values (`true`, `4`, `false`, `0`) are the values set on the snapshot structs passed into `requestFromSnapshot` — not fabricated constants. In the shell test, `grep '"auto_advance":true'` and `tekhton state read --field auto_advance` check output produced by the live `write_pipeline_state` → `_state_write_snapshot` call chain with the test-supplied env vars.

**Edge Case Coverage — PASS (with LOW gaps noted above).**
Go tests cover: happy path (fields present), backward compat (fields absent via zero-value struct), and on-disk JSON round-trip (write → read → requestFromSnapshot). Shell test covers: bash-fallback with fields on/off, Go-path with fields on; Go-path off partial.

**Implementation Exercise — PASS.**
`TestRequestFromSnapshotAutoAdvanceFields` calls `r.requestFromSnapshot(snap)` directly (resume.go:56–74). `TestStateSnapshotAutoAdvanceJSONRoundTrip` drives `state.New(tmp).Update()` → `store.Read()` → `requestFromSnapshot`, exercising `StateSnapshotV1` JSON marshaling (state_v1.go:29–30) end-to-end. The shell test sources `lib/state.sh` which calls `write_pipeline_state` → `_state_write_snapshot` (state_helpers.sh:21–102) and `_state_bash_write_fields` (state_helpers.sh:109–171) for the fallback path. The `fakePipeline` is used only to satisfy `runner.New()` construction; it is not on the path under test.

**Test Weakening — PASS.**
No existing tests were modified. All seven pre-existing functions in `resume_test.go` (`TestIsCompleteLoopExit`, `TestResumeMissingState`, `TestResumeRebuildsTaskRequest`, `TestRequestFromSnapshotMilestoneMode`, `TestApplyEnvDefaultsLeavesNonEmpty`, `TestResumeProductionPath`, `TestResumeProductionPathRejectsMissingAmbient`) are unchanged.

**Test Naming — PASS.**
`TestRequestFromSnapshotAutoAdvanceFields`, `TestRequestFromSnapshotAutoAdvanceBackwardCompat`, and `TestStateSnapshotAutoAdvanceJSONRoundTrip` each encode the component under test, the scenario, and the expected property. Shell test assertion messages (`"bash-fallback emits auto_advance: true"`, `"Go-path persists auto_advance_limit=4"`) are similarly specific.

**Scope Alignment — PASS.**
New fields `AutoAdvance` and `AutoAdvanceLimit` are confirmed present at `internal/proto/state_v1.go:29-30`. The copy into `RunRequestV1` is at `internal/runner/resume.go:62-63`. `applyField` bool branch is at `cmd/tekhton/state.go:189-196`. `lookupField` bool branch is at `cmd/tekhton/state.go:239-242`. `_state_write_snapshot` auto-advance block is at `lib/state_helpers.sh:60-66`. All references in the test files resolve to live implementation code.

**Test Isolation — PASS.**
All three Go tests use `t.TempDir()` for any file I/O, or operate entirely in-memory. The shell test creates `TMPDIR=$(mktemp -d)` with `trap 'rm -rf "$TMPDIR"' EXIT`. Each `_write_with_env` invocation runs in a `(...)` subshell with `unset AUTO_ADVANCE AUTO_ADVANCE_LIMIT` at the top, preventing the parent pipeline's milestone-mode env (which sets these vars) from leaking into backward-compat scenarios. No test reads `.tekhton/`, `.claude/logs/`, pipeline run artifacts, or any other mutable project-state file.
