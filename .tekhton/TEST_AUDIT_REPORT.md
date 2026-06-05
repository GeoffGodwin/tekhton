## Test Audit Report

### Audit Summary
Tests audited: 2 files, 8 new test assertions/functions
- `tests/test_state_writer_resume_fields.sh` — extended with `_write_with_milestone_env` helper and Scenarios C/D (6 new bash assertions)
- `internal/runner/resume_test.go` — 2 new Go test functions: `TestRequestFromSnapshotMilestoneIDFixture`, `TestRequestFromSnapshotMilestoneIDAbsentFallsThrough`

Verdict: PASS

### Findings

#### COVERAGE: No test for MILESTONE_ID vs _CURRENT_MILESTONE precedence ordering
- File: tests/test_state_writer_resume_fields.sh:221
- Issue: The three-tier chain is `positional > MILESTONE_ID > _CURRENT_MILESTONE` (state_helpers.sh:77). C1 exercises MILESTONE_ID alone; C2 exercises _CURRENT_MILESTONE alone. No case sets both simultaneously (e.g. MILESTONE_ID="m99" + _CURRENT_MILESTONE="m34.2") to assert MILESTONE_ID wins. The `_write_with_milestone_env` helper already accepts both as separate args (positions 2 and 3), so a new scenario requires only a call and one grep assertion.
- Severity: MEDIUM
- Action: Add C4 (bash-fallback) and D4 (Go-path): call `_write_with_milestone_env "$file" "m99" "m34.2" "" "true/false"` and assert the output contains `"milestone_id":"m99"` rather than `"m34.2"`. No implementation changes needed.

#### COVERAGE: No test for positional argument overriding env vars
- File: tests/test_state_writer_resume_fields.sh:103
- Issue: The positional (6th arg) is the highest-precedence source. No test passes a positional value alongside a conflicting MILESTONE_ID env var to confirm the positional wins. The `pos` parameter on `_write_with_milestone_env` already supports this; the scenario is just absent.
- Severity: LOW
- Action: Optional — add a scenario calling `_write_with_milestone_env "$file" "m34.2" "" "m99.0" "true"` and asserting output is `"m99.0"`. The bash expansion at state_helpers.sh:77 makes the positional priority self-evident from source; the test documents intent for future readers.

None: No HIGH findings. No INTEGRITY, SCOPE, WEAKENING, NAMING, EXERCISE, or ISOLATION violations.

### Rubric Assessment

**Assertion Honesty — PASS.**
C1/C2/C3 grep patterns match the exact JSON encoding produced by `_state_bash_write_fields` for str-typed fields (state_helpers.sh:159). C3 absence check is correct: the `elif [[ -n "$val" ]]` guard skips empty strings, so no `milestone_id` key reaches the output when the chain resolves to empty.
Go fixture tests (resume_test.go:146, 181) write a hand-authored JSON envelope, parse it through `state.New(path).Read()`, then call `requestFromSnapshot` — the same path `tekhton --resume` takes. Assertions at lines 168–173 and 205–210 are derived directly from the branching logic at resume.go:67–73: if `snap.MilestoneID != ""`, set `RunModeMilestone`; else if `req.Task != ""`, set `RunModeTask`. No hard-coded magic values.

**Edge Case Coverage — PASS (two gaps noted above, MEDIUM and LOW).**
Scenarios C1–C3 and D1–D3 cover: MILESTONE_ID-set, _CURRENT_MILESTONE-fallback, and both-unset omit. Backward compat (pre-m40.2 state with no milestone_id key routes to task mode) is covered by `TestRequestFromSnapshotMilestoneIDAbsentFallsThrough`. Missing: MILESTONE_ID+_CURRENT_MILESTONE conflict (MEDIUM) and positional-overrides-env (LOW).

**Implementation Exercise — PASS.**
Shell tests source `lib/state.sh`, which calls `write_pipeline_state` → `_state_write_snapshot` (state_helpers.sh:21–113) → `_state_bash_write_fields` (state_helpers.sh:120–182) on the fallback path. Go tests create real fixture files via `os.WriteFile`, call `state.New(path).Read()`, and invoke `r.requestFromSnapshot(snap)`. The `fakePipeline` satisfies runner construction only and is not on the tested path.

**Test Weakening — PASS.**
No existing assertions in either file were removed or broadened. Scenarios A and B (m40.1) in the shell test file (lines 124–212) are byte-for-byte unchanged. All pre-existing Go test functions remain intact and unmodified.

**Test Naming — PASS.**
`TestRequestFromSnapshotMilestoneIDFixture` encodes: function under test, feature (milestone_id), and test method (fixture). `TestRequestFromSnapshotMilestoneIDAbsentFallsThrough` encodes: function, scenario (absent key), and expected behavior (falls through to task mode). Shell assertion messages (`"bash-fallback emits milestone_id from MILESTONE_ID env"`, etc.) are equivalently specific.

**Scope Alignment — PASS.**
`StateSnapshotV1.MilestoneID` confirmed at internal/proto/state_v1.go:28. `requestFromSnapshot` milestone routing confirmed at internal/runner/resume.go:67–73. `_state_write_snapshot` milestone_id_field chain at lib/state_helpers.sh:76–77. Deleted file `.tekhton/stage_results/stage_tester_r1_b0.json` has no reference in either test file — no orphan risk.

**Test Isolation — PASS.**
Shell test: `TMPDIR=$(mktemp -d)` + `trap 'rm -rf "$TMPDIR"' EXIT`; all state files written to `$TMPDIR/*`; each `_write_with_milestone_env` call runs in a `(...)` subshell with `unset MILESTONE_ID _CURRENT_MILESTONE` at entry, preventing pipeline-mode env leakage into backward-compat scenarios.
Go tests: `t.TempDir()` for all file I/O; fixture content is an inline string literal. Neither test file reads `.tekhton/`, `.claude/logs/`, or any other mutable project-state file.
