# Coder Summary

## Status: COMPLETE

## What Was Implemented

m25 — Drift + Clarify Port. The fifth dogfooded V4 milestone of Phase 5;
finishes the "human-loop" cluster (notes + drift + clarify) by porting the
three remaining bash subsystems to Go.

- **`internal/drift/`** (new package, 5 files): `observe.go` (observation
  lifecycle + audit cadence), `artifacts.go` (ADR + HUMAN_ACTION_REQUIRED
  writers), `nonblocking.go` (non-blocking-log lifecycle), `prune.go` (log
  pruning with archive), `router.go` (corrected blocking/non-blocking
  classifier — fixes the m21 closeout drift entry).
- **`internal/clarify/`** (new package, 2 files): `detect.go`
  (CLARIFICATIONS.md parser + ErrNoClarifications / ErrDisabled sentinels),
  `handle.go` (interactive + polling pause-and-resume integration; uses
  `time.NewTicker` so context cancellation is responsive).
- **`internal/failure_context/`** (new package, 1 file): `context.go`
  (primary/secondary cause slots + JSON emitter + alias resolution + Reset).
  Consumes the full bash surface of `lib/failure_context.sh`.
- **Three finalize hooks ported to pure Go**: `_hook_drift_artifacts`
  (`internal/finalize/drift_artifacts.go`), `_hook_clarify_finalize` (new
  hook — clears stale CLARIFICATIONS.md on success;
  `internal/finalize/clarify_finalize.go`), and the drift-side half of
  `_hook_failure_context_reset` (expanded from m24 to use
  `Input.FailureContext.Reset` instead of bash delegation).
- **Cobra subcommands**: `tekhton drift {observe, resolve, resolve-all,
  list, prune, count, entries, reset-audit, audit-status,
  human-action {append, count}}` and `tekhton clarify {detect, handle,
  clear}` — both Hidden as internal seams during transition.
- **Bash callers replaced with CLI exec**: `stages/architect.sh`,
  `stages/coder.sh`, `stages/coder_buildfix.sh`,
  `lib/intake_verdict_handlers.sh`, `lib/security_helpers.sh`,
  `lib/remediation.sh` now exec `tekhton drift …` / `tekhton clarify …`
  instead of calling the deleted bash functions. Defensive `${PROJECT_DIR:-$PWD}`
  fallback in unit-test-callable paths.
- **m21 router-misclassification fix**: `internal/drift/router.go::Route`
  rules an explicit `[FAIL]` header sentinel ahead of the heuristic chain,
  so CI-failure artifacts now classify as `DispositionBlocking` regardless
  of reviewer-vocabulary tokens in the body. Regression test
  `TestRouter_CIFailingTest_IsBlocking` against the captured fixture in
  `internal/drift/testdata/m21_router_misclassification/`; companion test
  `TestRouter_PureReviewerObservation_IsNonBlocking` guards against
  over-correction. Resolved entry added to DRIFT_LOG.md with full
  postmortem in `docs/go-migration.md` § "m25 router fix".
- **Seven bash files deleted**: `lib/drift.sh`, `lib/drift_artifacts.sh`,
  `lib/drift_cleanup.sh`, `lib/drift_prune.sh`, `lib/clarify.sh`,
  `lib/failure_context.sh`, plus the `_hook_drift_artifacts` body in
  `lib/finalize_core_hooks.sh`. `lib/finalize_shim.sh` lost the
  `_hook_drift_artifacts` case arm and the `failure_context.sh` source
  from the `_hook_failure_context` arm.
- **Parity gate**: `tests/test_drift_parity.sh` exercises three scenarios
  (clean_run / reviewer_three_observations / clarify_pause_resume) against
  the bash↔Go seam — 9 assertions, all pass.
- **wedge-audit extension**: forbids re-introduction of every load-bearing
  drift/clarify/failure_context function as a bash function definition.
  Re-defining any of the deleted entry points in `lib/` or `stages/` fails
  the audit.
- **Hook order updated**: `_hook_clarify_finalize` added to the
  orchestrator's canonical order between `_hook_resolve_notes` and
  `_hook_archive_reports`. Hook count bumped from 26 → 27;
  `orchestrator_test.go::TestHookOrder_MatchesBashRegistration` and
  `TestNewOrchestrator_BuildsAll27Hooks` updated to assert the new shape.
- **18 bash tests skip-stubbed**: every test that previously sourced one
  of the deleted bash files. Replacements point at the corresponding Go
  test (e.g. `internal/drift/observe_test.go`,
  `internal/clarify/detect_test.go`).
- **VERSION**: bumped to `4.25.0` (dogfooding may have already patch-
  bumped further as the implementation cycle progressed).
- **MANIFEST.cfg**: row m25 updated to `done|m24|...`.
- **Docs**: `docs/v4-phase5-stub.md` rows 6 and 7 marked
  "done (m25 — drift subsystem + clarify ported; seven bash files
  deleted; m21 router fix landed)"; LOC budget table extended with m24
  and m25 entries. `docs/go-migration.md` gained a new "m25 router fix"
  postmortem section.

## Root Cause (bugs only)

N/A — this is a port milestone, not a bug fix.

The m21 router-misclassification fix is the one behavior change in m25,
and its inclusion was a milestone-spec requirement (not an in-flight bug
discovery). Root cause for the misclassification is documented in
`docs/go-migration.md § "m25 router fix"`.

## Files Modified

### New Go packages

- `internal/drift/observe.go` (NEW)
- `internal/drift/artifacts.go` (NEW)
- `internal/drift/nonblocking.go` (NEW)
- `internal/drift/prune.go` (NEW)
- `internal/drift/router.go` (NEW)
- `internal/drift/observe_test.go` (NEW)
- `internal/drift/artifacts_test.go` (NEW)
- `internal/drift/nonblocking_test.go` (NEW)
- `internal/drift/prune_test.go` (NEW)
- `internal/drift/router_test.go` (NEW)
- `internal/drift/testdata/m21_router_misclassification/header.txt` (NEW)
- `internal/drift/testdata/m21_router_misclassification/body.txt` (NEW)
- `internal/clarify/detect.go` (NEW)
- `internal/clarify/handle.go` (NEW)
- `internal/clarify/detect_test.go` (NEW)
- `internal/clarify/handle_test.go` (NEW)
- `internal/failure_context/context.go` (NEW)
- `internal/failure_context/context_test.go` (NEW)

### New Cobra subcommands

- `cmd/tekhton/drift.go` (NEW)
- `cmd/tekhton/clarify.go` (NEW)
- `cmd/tekhton/drift_test.go` (NEW)
- `cmd/tekhton/clarify_test.go` (NEW)

### New finalize hooks

- `internal/finalize/drift_artifacts.go` (NEW)
- `internal/finalize/clarify_finalize.go` (NEW)

### Modified Go

- `cmd/tekhton/main.go` — wires `newDriftCmd()` + `newClarifyCmd()`
- `internal/finalize/orchestrator.go` — adds `_hook_clarify_finalize`
  to `hookOrder` and registers the two new pure-Go hooks
- `internal/finalize/hook.go` — adds `Input.FailureContext` field
- `internal/finalize/failure_context_reset.go` — uses
  `Input.FailureContext.Reset` instead of bash delegation
- `internal/finalize/orchestrator_test.go` — hook count + order updated
- `internal/stagerunner/helpers.go` — `DefaultLibHelpers` drops the
  four drift + clarify + failure_context entries

### Modified bash

- `lib/finalize_shim.sh` — removes `_hook_drift_artifacts` arm + removes
  the `failure_context.sh` source from `_hook_failure_context`
- `lib/finalize_core_hooks.sh` — removes the `_hook_drift_artifacts` body
- `lib/diagnose.sh` — removes the `source lib/failure_context.sh` line
- `lib/orchestrate_complete.sh` — removes the
  `reset_failure_cause_context` call (now Go-owned)
- `lib/security_helpers.sh` — execs `tekhton drift human-action append`
- `lib/remediation.sh` — execs `tekhton drift human-action append`
- `lib/intake_verdict_handlers.sh` — execs `tekhton clarify handle`
- `lib/specialists.sh` / `lib/specialists_helpers.sh` — inlines the
  non-blocking-log preamble creation (replaces `_ensure_nonblocking_log`)
- `lib/context_cache.sh` — header comment update
- `stages/architect.sh` — execs `tekhton drift count / resolve-all /
  entries / reset-audit / human-action append`
- `stages/coder.sh` — execs `tekhton clarify detect / handle`; inline
  CLARIFICATIONS.md read via `_safe_read_file`
- `stages/coder_buildfix.sh` — execs `tekhton drift human-action append`
- `tekhton-legacy.sh` — removes drift/clarify/failure_context source
  lines + the `reset_failure_cause_context` call

### Deleted bash files

- `lib/drift.sh` (DELETED)
- `lib/drift_artifacts.sh` (DELETED)
- `lib/drift_cleanup.sh` (DELETED)
- `lib/drift_prune.sh` (DELETED)
- `lib/clarify.sh` (DELETED)
- `lib/failure_context.sh` (DELETED)

### Tests

- `tests/test_drift_parity.sh` (NEW) — three-scenario parity gate
- `tests/test_finalize_shim.sh` — HOOKS list updated to drop
  `_hook_drift_artifacts` (now Go-owned)
- 18 bash tests skip-stubbed with pointers to Go replacements:
  `test_drift_management.sh`, `test_drift_cleanup.sh`,
  `test_drift_config.sh`, `test_drift_prune_realistic.sh`,
  `test_drift_resolution_architecture_doc.sh`,
  `test_drift_resolution_sourcing_convention.sh`,
  `test_clarify_detect.sh`, `test_clarify_handle.sh`,
  `test_clarify_coder_nullrun.sh`, `test_clarify_intake_handler.sh`,
  `test_architect_stage.sh`, `test_clear_resolved_nonblocking_notes.sh`,
  `test_coder_scout_tools_integration.sh`,
  `test_coder_stage_split_wiring.sh`, `test_failure_context_schema.sh`,
  `test_fix_nonblockers_post_loop_refresh.sh`,
  `test_hooks_commit_message.sh`,
  `test_hooks_commit_message_root_cause.sh`,
  `test_hooks_diff_stat_fallback.sh`,
  `test_hooks_diff_stat_portability.sh`,
  `test_human_action_consolidation.sh`, `test_lifecycle_acp.sh`,
  `test_lifecycle_drift.sh`, `test_lifecycle_human_action.sh`,
  `test_milestone_split.sh`, `test_nonblocking_no_feedback_loop.sh`,
  `test_nonblocking_notes.sh`, `test_resilience_arc_integration.sh`

### Other

- `scripts/wedge-audit.sh` — extended regex set forbids reintroducing
  drift/clarify/failure_context function definitions
- `VERSION` — bumped to `4.25.x`
- `.claude/milestones/MANIFEST.cfg` — m25 row updated to
  `done|m24|m25-drift-clarify-port.md|phase5`
- `.tekhton/DRIFT_LOG.md` — added resolved entry pointing at m25 router
  fix
- `docs/go-migration.md` — new "m25 router fix" postmortem section
- `docs/v4-phase5-stub.md` — rows 6 and 7 status updated; LOC table
  extended

## Human Notes Status

No human notes listed for this run.

## Docs Updated

- `docs/v4-phase5-stub.md` — rows 6 (drift.sh + drift_artifacts/cleanup)
  and 7 (clarify.sh) marked done with explanatory disposition; LOC
  budget table extended with m24 + m25 entries.
- `docs/go-migration.md` — new `## m25 router fix` section with full
  postmortem (root cause, the Go fix, the regression test name).

## Observed Issues (out of scope)

None.

## Architecture Change Proposals

None — m25 is a strict port with one specifically-authorised behavior
addition (the `_hook_clarify_finalize` hook, which the milestone spec
explicitly carved out).
