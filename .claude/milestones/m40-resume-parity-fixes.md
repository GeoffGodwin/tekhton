<!-- milestone-meta
id: "40"
status: "split"
-->

# m40 — Resume Parity Fixes

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | `tekhton --resume` silently drops two pieces of run intent that the bash-era resume preserved: the milestone id and the auto-advance config. The user-visible symptom is dramatic — a milestone-mode run that halts at the build-fix loop, gets resumed, runs to success, but the manifest never advances past the just-resumed milestone. Operators discover this only after running the same milestone five times in a row (real incident from the m34.1 auto-advance run on 2026-06-02). Both gaps were introduced by the m20 dogfooding cutover that moved the run-flag entry point from `tekhton.sh` to `tekhton run`; the Go runner's state envelope wasn't a strict superset of the bash one and the bash writer never grew the new fields. |
| **Gap** | (1) `internal/proto/state_v1.go::StateSnapshotV1` has no `auto_advance` or `auto_advance_limit` fields. `requestFromSnapshot` in `internal/runner/resume.go` has no fields to read for them, so resume always rebuilds the request with `AutoAdvance=false` regardless of what the operator started the arc with. (2) The bash state writer `lib/state_helpers.sh::write_pipeline_state` emits `exit_stage`, `exit_reason`, `resume_flag`, `notes`, `extra` — but NOT `milestone_id`. On the Go-resume path, `requestFromSnapshot` reads `snap.MilestoneID`, sees `""`, and routes through the task branch, which leaves `req.Mode = RunModeResume` and `req.Milestone = ""`. Downstream, `env.go:115` derives `MilestoneMode = req.Mode == RunModeMilestone \|\| req.Milestone != ""` — both false on resume, so MILESTONE_MODE is `false`, `_hook_mark_done` skips, and the manifest never flips even when the pipeline runs to a clean success. |
| **m40 fills** | Two narrow Go + bash edits. 40.1 widens `StateSnapshotV1` with `auto_advance` (bool) and `auto_advance_limit` (int), updates `requestFromSnapshot` to copy them onto the rebuilt `RunRequestV1`, and updates the bash writer to emit both. 40.2 adds `milestone_id` to the bash writer's output and verifies `requestFromSnapshot` already reads it (no Go change beyond a test). Both ship together so resume is full-parity with the original run. |
| **Depends on** | m33 |
| **Files changed** | `internal/proto/state_v1.go`, `internal/runner/resume.go`, `internal/runner/resume_test.go`, `lib/state_helpers.sh`, `tests/test_state_writer_resume_fields.sh` (new), `cmd/tekhton/run.go` (only flag-help text), `VERSION`, `CHANGELOG.md`, `.claude/milestones/MANIFEST.cfg`. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m20 | Dogfooding cutover — moved `tekhton run` entry into Go; state envelope parity drifted between writers and readers. |
| m33 | Last stage-port-adjacent milestone before the m34-m39 sprint. |
| **m40** | **Close the resume envelope parity gap exposed by the m34.1 auto-advance dogfood.** |

---

## Design

This milestone is sequenced into two independently testable subtasks. They are tiny and could land in a single commit, but the decimal split keeps each agent session focused on a single field group and lets the test coverage be reviewed in pieces.

### Why split this way

- **40.1 fills the auto-advance gap** which is the more visible bug to operators (they re-pass `--auto-advance` after a resume and notice it's not honored). Lands the proto change and proves the writer/reader pair end-to-end.
- **40.2 fills the milestone id gap** which is the more dangerous bug (silently breaks milestone completion tracking on every resume of a milestone arc). Lands after 40.1 so the proto's resume-related field additions are batched into a single envelope rev.

Both leave the on-disk file format backward-compatible (new optional fields; absence reads as zero-value). Existing `.claude/PIPELINE_STATE.md` files from prior runs continue to load.

---

## Acceptance Criteria (arc-level)

- [ ] m40.1 and m40.2 each close with `status: "done"`.
- [ ] Manifest rows for m40, m40.1, m40.2 all read `done` after m40.2 closes; m40 parent flips from `split` to `done`.
- [ ] `VERSION` reads `4.40.0` on m40 close (m40.1 and m40.2 use patch bumps).
- [ ] `bash tests/run_tests.sh` shows zero regressions vs. the pre-m40 baseline.
- [ ] Single arc CHANGELOG section under `[4.40.0]` consolidates the two subtask entries.
- [ ] Integration proof: a halted milestone-mode run resumed with `tekhton --resume` produces an `[MILESTONE NN ✓]` finalize commit, and the manifest's `_hook_mark_done` flips the just-resumed milestone to `done`. Verified on a recorded `.claude/PIPELINE_STATE.md` fixture in `tests/test_state_writer_resume_fields.sh`.

## Watch For

- **Do not change the StateSnapshotV1 proto version.** The new fields are additive and JSON-marshalled with `omitempty`. Bumping to `tekhton.state.v2` would force a migration shim for users with in-flight `.md` files from the m34.1 era, and there's nothing in the existing fields that benefits from a major bump.
- **`auto_advance_limit` semantics on resume.** A literal-restore approach can produce a confusing "advanced 1 of 4 → halted → resumed → tries to advance 4 more" overshoot. The resume should restore the ORIGINAL limit, not the remaining count. If the user wants to cap the post-resume tail, they can pass `--auto-advance-limit N` explicitly which overrides the snapshot value (the Go runner's existing flag-override pattern).
- **Bash writer field ordering.** `write_pipeline_state` builds the JSON via a sequence of `printf` calls (no jq dependency). New fields must land in the same alphabetical-within-section order the rest of the envelope uses so `tekhton state validate` round-trips clean. Out-of-order keys won't fail JSON parse but break the parity gate test.
- **`get_current_milestone` plumbing.** The bash side reads `_CURRENT_MILESTONE` from a global. On bash-orchestrator paths that global is set; on Go-orchestrator paths the bash subprocess inherits it from the env contract (`MILESTONE_ID` per the m26 builder). m40.2's writer must read whichever is present without crashing if both are empty (a non-milestone task run writes a state file too).

## Seeds Forward

- **Post-m40**: `tekhton --resume` from a milestone-mode halt restores full intent — milestone id, auto-advance, and limit. The m34-m39 stage-port sprint becomes resume-safe under the auto-advance flag, which is the dogfood mode operators actually use.
- **Future state-envelope work**: any new `RunRequestV1` field that needs to survive resume now has a clear pattern: add to `StateSnapshotV1`, emit in `write_pipeline_state`, read in `requestFromSnapshot`. The m26 env contract documents this seam; m40 establishes the resume-side mirror.
- **Test fixture corpus**: `tests/test_state_writer_resume_fields.sh` will serve as the regression net for any future writer changes. The same fixture is the parity baseline if/when bash `write_pipeline_state` ports to Go.
