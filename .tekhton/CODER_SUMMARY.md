# Coder Summary

## Status: COMPLETE

## What Was Implemented

m40.1 — first of two narrow envelope-parity fixes for the auto-advance
resume gap exposed by the m34.1 dogfood. Without this, `tekhton --resume`
after a halt rebuilt the RunRequest with `AutoAdvance=false` regardless
of how the operator started the arc.

Goal 1 — Widen `StateSnapshotV1`:
- Added `AutoAdvance bool` and `AutoAdvanceLimit int` to
  `internal/proto/state_v1.go` with `omitempty` JSON tags. Field
  additions are additive within `tekhton.state.v1` — no v2 bump.

Goal 2 — Read into `requestFromSnapshot`:
- `internal/runner/resume.go::requestFromSnapshot` now copies
  `snap.AutoAdvance` and `snap.AutoAdvanceLimit` onto the rebuilt
  `RunRequestV1`. CLI flag overrides (`--auto-advance-limit`) still
  win because `buildRunRequest` runs before resume reads the snapshot.

Goal 3 — Emit from `write_pipeline_state`:
- `lib/state_helpers.sh::_state_write_snapshot` adds two `--field`
  entries to the state-update array, gated on `AUTO_ADVANCE=true`
  and a numeric, non-zero `AUTO_ADVANCE_LIMIT`. The env vars are
  already populated by the m26 env builder for milestone-mode runs.
  Both checks use the `${VAR:-DEFAULT}` form per the m27 unguarded-
  reads contract (caught by `scripts/audit-bash-env.sh`).
- Both writer paths preserve omitempty parity:
  - Go path (`tekhton state update`): empty `--field` value is a
    no-op through `applyField` (the new `reflect.Bool` branch).
  - Bash fallback (`_state_bash_write_fields`): new `bool` scalar
    type emits only `"true"`; `"false"` and empty are skipped.

Goal 4 — Tests:
- `internal/runner/resume_test.go` — added three test cases:
  - `TestRequestFromSnapshotAutoAdvanceFields` — round-trip from
    snapshot with `auto_advance:true, auto_advance_limit:4`.
  - `TestRequestFromSnapshotAutoAdvanceBackwardCompat` — snapshot
    without the fields produces zero-value fields on the request.
  - `TestStateSnapshotAutoAdvanceJSONRoundTrip` — full on-disk
    write/read/requestFromSnapshot chain.
- `tests/test_state_writer_resume_fields.sh` (new) — drives
  `write_pipeline_state` through both Go-path and bash-fallback
  writers; 8 assertions covering both fields with env set and
  backward-compat (env unset omits the keys).

Supporting changes:
- `cmd/tekhton/state.go::applyField` + `lookupField`: extended
  reflective field handling to cover `reflect.Bool`. Required for
  the Go-path writer to persist `auto_advance` through
  `tekhton state update --field auto_advance=true`.
- `cmd/tekhton/run.go`: flag-help text for `--auto-advance-limit`
  notes the new persist-on-resume behavior.
- `VERSION` bumped `4.44.8` → `4.44.10` (final-version state at
  commit time; the version file was bumped by the harness during
  the run).
- `CHANGELOG.md`: added `[Unreleased]` entry summarizing the m40.1 fix.

## Root Cause (bugs only)

N/A — m40.1 is an additive parity fix, not a regression. The gap was
that the state envelope simply did not carry the auto-advance fields,
so resume saw zero values regardless of the originating arc.

## Files Modified

- `internal/proto/state_v1.go` — `StateSnapshotV1` gets `AutoAdvance bool` and `AutoAdvanceLimit int` with `omitempty` tags (gofmt re-aligned the struct tag column at the same time — unrelated to the field additions).
- `internal/runner/resume.go` — `requestFromSnapshot` copies the two new fields onto the rebuilt `RunRequestV1`.
- `internal/runner/resume_test.go` — three new tests covering round-trip, backward compat, and end-to-end disk round-trip.
- `cmd/tekhton/state.go` — `applyField` + `lookupField` extended to handle `reflect.Bool` so the bash writer's `--field auto_advance=true` hop round-trips.
- `cmd/tekhton/run.go` — `--auto-advance-limit` flag help updated to mention resume persistence.
- `lib/state_helpers.sh` — `_state_write_snapshot` emits the two fields when env vars are set; `_state_bash_write_fields` scalars table adds `bool` type with omitempty semantics.
- `tests/test_state_writer_resume_fields.sh` (NEW) — shim-boundary integration test driving both writer paths.
- `VERSION` — `4.44.8` → `4.44.10`.
- `CHANGELOG.md` — Unreleased entry under `### Added`.

## Docs Updated

None — no public-surface docs require updates. The only externally-visible
change is the `--auto-advance-limit` CLI help string, which is in-source
and rendered by `tekhton run --help`. No README, `docs/`, or
`ARCHITECTURE.md` entry references the snapshot field set; the README's
descriptions of `--auto-advance` are unchanged because behavior on the
fresh-run path is identical.

## Design Observations

- The milestone references `tekhton state validate` as if it already exists
  ("already exists from m03"). It does not — only `state read`, `state
  write`, `state update`, `state clear`. The new test uses `tekhton state
  read` for the parse-and-validate role since the reader rejects corrupt
  JSON with exit code 2 (matching the m03 `ErrCorrupt` contract). This is
  equivalent functionally — `state read --path X` and a hypothetical
  `state validate --path X` would both fail on the same inputs — but the
  AC text could be updated to point at the existing surface.

## Acceptance Criteria Verification

- [x] `StateSnapshotV1` has `AutoAdvance bool` + `AutoAdvanceLimit int` fields tagged with `omitempty` — verified `internal/proto/state_v1.go:29-30`.
- [x] `requestFromSnapshot` copies both fields onto the rebuilt `RunRequestV1` — verified `internal/runner/resume.go:62-63`, covered by `TestRequestFromSnapshotAutoAdvanceFields`.
- [x] State file without the keys still loads cleanly — `TestRequestFromSnapshotAutoAdvanceBackwardCompat` plus existing `TestResumeRebuildsTaskRequest` (untouched).
- [x] State file with `auto_advance:true, auto_advance_limit:4` round-trips → `req.AutoAdvance == true && req.AutoAdvanceLimit == 4` — `TestStateSnapshotAutoAdvanceJSONRoundTrip` and `TestRequestFromSnapshotAutoAdvanceFields`.
- [x] `write_pipeline_state` emits both fields when env set — `tests/test_state_writer_resume_fields.sh` Scenario A & B, both pass.
- [x] Output JSON validates (parses cleanly via `tekhton state read`) — same test, "Go-path produces valid JSON" assertion.
- [x] New test `tests/test_state_writer_resume_fields.sh` passes — 8/8 assertions green.
- [x] Existing `state` round-trip tests pass with no regression — `bash tests/test_state_roundtrip.sh` + `tests/test_state_cli_exit_codes.sh` + `tests/test_state_error_classification.sh` all pass.
- [x] `bash tests/run_tests.sh` shows zero regressions vs. HEAD baseline. The only fail observed during testing (`test_m27_sweep_regression.sh`) was triggered by my interim unguarded `${AUTO_ADVANCE_LIMIT}` reads, which I subsequently fixed with the `${VAR:-DEFAULT}` form. Re-running the test post-fix returns 5/5 PASS. Two other failures (`test_milestones.sh`, `test_milestones_flag_smoke.sh`) reproduce on plain HEAD without my changes — pre-existing failures unrelated to m40.1.

## Human Notes Status

No human notes were listed in the task — none to address.
