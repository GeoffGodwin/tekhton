# Coder Summary

## Status: COMPLETE

## What Was Implemented

m40.2 — the closing half of the m40 resume-parity arc. Without this, every
stage-level `write_pipeline_state` call site that did NOT pass the 6th
positional milestone argument (the vast majority — `stages/coder.sh`,
`stages/review.sh`, `stages/tester.sh`, `stages/tester_continuation.sh`,
`stages/coder_buildfix.sh`, `stages/review_helpers.sh`,
`stages/tester_tdd.sh`, `stages/tester_validation.sh`,
`lib/replan_midrun.sh`, `lib/dry_run.sh`) produced a snapshot with
`"milestone_id":""`. On `tekhton --resume`, `snap.MilestoneID == ""` falls
through `requestFromSnapshot` to task/resume mode, `env.go` derives
`MilestoneMode=false`, and `_hook_mark_done` silently skips because it gates
on `MILESTONE_MODE && _CURRENT_MILESTONE`. The operator's manifest entry
never flips to `done` — proximate cause of m34.1 staying `todo` through
five successful pipeline runs on 2026-06-02.

Goal 1 — Emit `milestone_id` with env fallback in `_state_write_snapshot`:

- `lib/state_helpers.sh::_state_write_snapshot` now computes
  `milestone_id_field` from a three-tier precedence chain before populating
  the `--field` array:
  `${milestone_num:-${MILESTONE_ID:-${_CURRENT_MILESTONE:-}}}`. The explicit
  6th positional still wins (so `lib/orchestrate_save.sh`'s existing call
  site continues to behave identically); the m26 env-contract `MILESTONE_ID`
  takes precedence over the legacy bash-orchestrator `_CURRENT_MILESTONE`.
  All three empty means a non-milestone task run — the field stays empty and
  the existing omitempty path in both writer branches (Go-path `applyField`
  + bash-fallback `_state_bash_write_fields`) drops the key.
- All env reads use the `${VAR:-DEFAULT}` form per the m27 unguarded-reads
  contract.

Goal 2 — Tests:

- `tests/test_state_writer_resume_fields.sh` (extended) — added six new
  assertions across two scenario groups:
  - Scenario C (bash-fallback writer): MILESTONE_ID set, _CURRENT_MILESTONE
    legacy fallback, both-unset omit.
  - Scenario D (Go-path writer): same three cases, read back via
    `tekhton state read --field milestone_id`.
  Total: 14 assertions, all PASS. Existing m40.1 auto-advance scenarios
  remain untouched.
- `internal/runner/resume_test.go` (extended) — two new tests:
  - `TestRequestFromSnapshotMilestoneIDFixture` loads a hand-authored
    fixture envelope with `milestone_id:"m34.2"` through `state.New(...)
    .Read()`, then asserts the rebuilt `RunRequestV1` has
    `Mode == RunModeMilestone && Milestone == "m34.2"`. This is the
    production path operators reach via `tekhton --resume`.
  - `TestRequestFromSnapshotMilestoneIDAbsentFallsThrough` is the backward-
    compat AC anchor: a fixture without the `milestone_id` key produces
    `snap.MilestoneID == ""` and routes to `RunModeTask` when
    `ResumeTask != ""`. Pre-m40.2 state files continue to load cleanly.

Goal 3 — Arc-close version bump and changelog:

- `VERSION` set to `4.40.0` at write-time (subsequently auto-bumped to
  `4.40.1` by the harness mid-run — left as-is per the existing harness
  contract).
- `.claude/project_version.cfg` resolved (the file had stale merge conflict
  markers around identical content); now `CURRENT_VERSION=4.40.1`.
- `CHANGELOG.md`: consolidated `[4.40.0]` arc section summarizing both m40.1
  and m40.2 fixes, with the user-facing failure mode (silent manifest no-flip
  on resumed milestone runs) stated up front.

## Root Cause (bugs only)

N/A — m40.2 is an additive parity fix completing the m40 arc, not a bug
regression. The gap was that the bash state writer's `milestone_id` field
was sourced only from the 6th positional argument, and most stage-level
`write_pipeline_state` callers did not pass it.

## Files Modified

- `lib/state_helpers.sh` — `_state_write_snapshot` adds a `milestone_id_field`
  local using the `positional > MILESTONE_ID > _CURRENT_MILESTONE` precedence
  chain; the `--field` array entry consumes it. (230 lines, under ceiling.)
- `tests/test_state_writer_resume_fields.sh` — extended with the
  `_write_with_milestone_env` helper plus Scenarios C (bash-fallback) and
  D (Go-path), six new assertions. (296 lines, under ceiling.)
- `internal/runner/resume_test.go` — two new tests
  (`TestRequestFromSnapshotMilestoneIDFixture`,
  `TestRequestFromSnapshotMilestoneIDAbsentFallsThrough`); the existing
  `os` import gets added for `os.WriteFile`.
- `VERSION` — bumped to `4.40.0` at milestone close (harness post-bumped to
  `4.40.1`).
- `.claude/project_version.cfg` — merge-conflict markers removed; tracking
  current version.
- `CHANGELOG.md` — `[4.40.0]` section documenting the m40 arc closure.

## Docs Updated

None — no public-surface docs require updates. The change is internal to the
state-writer fallback chain and the JSON envelope. The `--auto-advance` CLI
flag help, README, and `docs/v4-env-contract.md` are unchanged. No new
config keys; no new prompt template variables. The CHANGELOG entry is the
only operator-visible artifact.

## Design Observations

- The milestone's "End-to-end proof" Goal 3 refers to capturing the `EnvKV`
  slice fed to the finalize hook. The Go-side env builder is verified
  indirectly: `TestRequestFromSnapshotMilestoneIDFixture` confirms
  `req.Mode == RunModeMilestone && req.Milestone == "m34.2"` — the upstream
  precondition for `env.go:115` to derive `MilestoneMode=true`. The
  fixture-driven Go test is the regression net the milestone describes;
  capturing the full `EnvKV` slice in-process would require a larger seam
  beyond this milestone's scope (a hook fixture in `internal/runner`).
- The milestone references `tekhton state validate` as the JSON-validation
  surface. That subcommand still does not exist (m40.1's
  CODER_SUMMARY flagged the same observation). The new Scenario D
  assertions reuse `tekhton state read --field milestone_id` for the
  validate-shape role — the reader rejects corrupt JSON with exit 2,
  identical to a hypothetical `state validate`.

## Acceptance Criteria Verification

- [x] `write_pipeline_state` emits `"milestone_id": "<id>"` when `MILESTONE_ID`
  env is set — Scenario C1 + D1.
- [x] Same behavior when `_CURRENT_MILESTONE` is set but `MILESTONE_ID` is
  empty — Scenario C2 + D2.
- [x] No `milestone_id` key in the output when both vars are unset — Scenario
  C3 + D3.
- [x] `tests/test_state_writer_resume_fields.sh` includes three new test
  cases per writer path (six total) and all pass — verified by direct run.
- [x] `internal/runner/resume_test.go` has a new test loading a fixture
  with `milestone_id:"m34.2"` and asserting milestone mode round-trip —
  `TestRequestFromSnapshotMilestoneIDFixture`.
- [x] A fixture state file with NO `milestone_id` key continues to load and
  falls through to task/resume mode —
  `TestRequestFromSnapshotMilestoneIDAbsentFallsThrough`.
- [x] End-to-end: a resumed halted-milestone state file produces a
  rebuilt RunRequest with `Mode == RunModeMilestone && Milestone != ""` —
  proven by the fixture test (the env builder downstream is already
  verified by existing m26 tests).
- [x] `bash tests/run_tests.sh` clean — 513/513 shell tests PASS; all Go
  packages PASS.

## Human Notes Status

No human notes were attached to this milestone.
