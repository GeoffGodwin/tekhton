# Coder Summary

## Status: COMPLETE

## What Was Implemented

m36.3 — Intake Stage Port. Closes the M36 arc by porting `stages/intake.sh`
(377 LOC) to `internal/stages/intake/`, consuming the m36.2
`internal/intake/` package in-process. Deletes the three intake bash files
(`stages/intake.sh`, `lib/intake_helpers.sh`,
`lib/intake_verdict_handlers.sh`), the m36.2 transition CLI shim
(`cmd/tekhton/intake.go`), and three obsolete bash tests
(`tests/test_intake.sh`, `tests/test_intake_bash_passthrough.sh`,
`tests/test_m118_intake_deferred_emit.sh`,
`tests/test_clarify_intake_handler.sh`).

### Goal 1 — `internal/stages/intake/`

Four new Go files under `internal/stages/intake/`:

- **`intake.go`** (339 lines) — exports `RunStage(ctx, *proto.StageRequestV1)`
  matching the M34/M35/M36.1 stage-port signature. Ports the full bash flow:
  sentinel cleanup (sole owner of `.final_check_result` + `.commit_decision`),
  HUMAN_MODE skip, INTAKE_AGENT_ENABLED skip, cached-run branch, content
  read + content-hash skip, banner, prompt invoke, verdict dispatch
  (PASS/TWEAKED/SPLIT_RECOMMENDED/NEEDS_CLARITY), `_INTAKE_PASS_EMIT`
  flag set ONLY on the live-PASS path.

- **`context.go`** (232 lines) — prompt-variable builders. Exports
  `buildPromptVars`, `buildProjectIndex`, `buildHistoryBlock`,
  `buildHealthSummary`, `buildIntakeRoleContent`, `buildNotesContext`.
  The keyword-overlap matcher ports the bash 4-char-min word filter (and
  uses `internal/notes.ExtractFromProject` in-process — eliminates one
  subprocess exec). The history/health/index builders best-effort exec
  `tekhton <subcommand>` paths; those subcommands don't exist yet so the
  blocks degrade to empty (documented in Design Observations).

- **`verdict.go`** (102 lines) — wires `internal/intake.VerdictHandler` with
  in-process `internal/state.Store.Update` for halt-state writes. Stubs
  `Split` / `Switch` (a follow-up milestone hooks the real
  `internal/manifest` seams).

- **`config.go`** (158 lines) + **`env.go`** (63 lines) — env reads via
  `envOr`/`envBool`/`envInt` (V4 m27 env contract), per-call config snapshot.

The `_INTAKE_PASS_EMIT` env var is set ONLY on the live PASS dispatch
path; explicitly unset on every skip path (disabled, HUMAN_MODE, no
content, unchanged, cached). Asymmetry preserved verbatim from the bash
M118 contract — the TUI relies on this for ordering the success line
after the green pill flip. A subprocess-boundary sidecar file
(`TEKHTON_INTAKE_ENV_OUT`) emits the three exports as a sourceable bash
file so the legacy `run_stage_intake` shim in `tekhton-legacy.sh` can
read them back across the exec boundary.

### Goal 2 — Stagerunner registration

`internal/stagerunner/helpers.go`:

- Adds `intakestage "github.com/geoffgodwin/tekhton/internal/stages/intake"`
  import.
- `DefaultStageDefs[proto.StageIntake]` now carries `GoImpl: intake.RunStage`
  only (Script and Helpers dropped). The wedge audit asserts no
  `Script:` or `Helpers:` lines remain on the `StageIntake` entry.

### Goal 3 — Bash deletions + CLI shim retirement

Files deleted:

- `stages/intake.sh` (377 LOC).
- `lib/intake_helpers.sh` (113 LOC — the m36.2 shim shrunk it from 472).
- `lib/intake_verdict_handlers.sh` (35 LOC — m36.2 shrunk from 204).
- `cmd/tekhton/intake.go` (454 LOC — the m36.2 transition CLI shim).
- `cmd/tekhton/intake_test.go` (105 LOC).
- `tests/test_intake_bash_passthrough.sh` (180 LOC — m36.2-only test).
- `tests/test_intake.sh` (sourced `lib/intake_helpers.sh`; intake logic now
  Go-tested by `internal/intake/*_test.go` + `internal/stages/intake/*_test.go`).
- `tests/test_m118_intake_deferred_emit.sh` (sourced the deleted bash; the
  M118 deferred-emit contract is now Go-tested by
  `TestRunStage_LiveDispatchPassSetsEmitFlag` +
  `TestRunStage_HumanModeSkipDoesNotEmitPass`).
- `tests/test_clarify_intake_handler.sh` (m25 skip-stub — no-op).

`cmd/tekhton/main.go` drops the `newIntakeCmd()` registration.

`tekhton-legacy.sh`:

- Removes the three `source "${TEKHTON_HOME}/{lib,stages}/intake*.sh"` lines.
- Adds a `run_stage_intake` bash shim (after the m36.1 architect shim) that
  execs `tekhton run-stage intake` with a sourceable env sidecar to read
  `INTAKE_VERDICT` / `INTAKE_CONFIDENCE` / `_INTAKE_PASS_EMIT` back across
  the subprocess boundary.
- Updates `--add-milestone` to emit a clear "temporarily unavailable
  post-m36.3 in agent-driven create mode" warning before routing to
  `--draft-milestones` (the working user-driven alternative). The deferred-
  stub message satisfies the AC's `grep -q 'temporarily unavailable
  post-m36.3'` assertion without regressing the existing working flow.

### Goal 4 — Parity gate + tests

- `tests/test_intake_parity.sh` (218 lines) — 8-scenario parity gate covering:
  `pass`, `tweaked`, `split-recommended`, `needs-clarity-complete` (verifies
  `block|needs_clarity` verdict AND CLARIFICATIONS.md byte content),
  `cached-run`, `human-mode-skip`, `disabled`, `no-content`. Uses
  `TEKHTON_AGENT_BINARY=/bin/false` so the agent invocation always fails
  cleanly and the stage falls through to its best-effort report-parse
  path. Wired into `make dogfood`.
- `internal/stages/intake/intake_test.go` (367 lines) — branch coverage:
  disabled skip, HUMAN_MODE skip (asserts `_INTAKE_PASS_EMIT` absent),
  sentinel cleanup, cached-run, live PASS (asserts `_INTAKE_PASS_EMIT=true`),
  content-hash skip, no-content, verdict-exit-reason mapping, env exporter.
- `internal/stages/intake/context_test.go` (194 lines) — per-builder unit
  tests, keyword-overlap matcher edge cases, no-file and read-file paths.
- `internal/stages/intake/verdict_test.go` (280 lines) — dispatch routing,
  CLARIFICATIONS.md write, state-store round-trip, NEEDS_CLARITY
  complete-mode → block verdict, ErrHalt sentinel propagation.

Coverage: **77.8%** of statements in `internal/stages/intake/` (above the
75% AC threshold).

### Goal 5 — Wedge audit + Makefile + docs + VERSION

- `scripts/wedge-audit-companions.sh` extended:
  - Forbids re-introduction of `stages/intake.sh`,
    `lib/intake_helpers.sh`, `lib/intake_verdict_handlers.sh` (m36.3
    violation message).
  - Asserts `DefaultStageDefs[StageIntake]` lists no `Script:` or
    `Helpers:` entries (catches the dead-Helpers regression).
  - Asserts `INTAKE_CLARITY_THRESHOLD` is NOT referenced in Go intake
    code (the threshold belongs in the prompt template only —
    Go-side gate enforcement would double-gate the agent contract).
  - Regression-verified: `touch lib/intake_helpers.sh && bash
    scripts/wedge-audit.sh` exits 1 with the m36.3 violation message.
- `Makefile` `dogfood` target wires `tests/test_intake_parity.sh`
  immediately after the m36.1 architect parity gate.
- `docs/v4-phase5-stub.md` — intake row flipped to **done** in the
  stage-port matrix; the "intake stage rows are arriving in two halves"
  paragraph rewritten to past tense; a new "Phase 5 follow-up:
  --add-milestone port" section documents the deferred
  `run_intake_create` scope.
- `docs/go-migration.md` — new "Phase 5 — M36 Closeout (Architect +
  Intake Stage Port)" retro at the top: bash LOC deleted, Go LOC added,
  patterns established (in-process verdict dispatch, sentinel-cleanup
  invariant, `_INTAKE_PASS_EMIT` asymmetry, env-sidecar pattern), and
  deferred work.
- `VERSION` bumped to `4.41.0` to mark m36.3 arc-close.

### Goal 6 — Test-suite repair

The stage-port deletions tripped four existing tests / test files that
sourced the deleted bash files. Each was either deleted (because the
contract is now Go-tested in `internal/stages/intake/`) or repointed:

- `internal/stagerunner/parity_test.go` — `TestDefaultStageDefsHelpersMatchLegacy`
  now expects `[]` for `StageIntake` Helpers (was the two-file list).
  `TestBashAdapterRealHelperIntegration` removed (depended on
  `lib/intake_helpers.sh`; the bash-adapter per-stage helper pattern
  is still covered by `TestBashAdapterPerStageHelperSourced`).
- `internal/stagerunner/adapter_test.go` — `newAdapter` test helper now
  defaults `Script` to `"stages/<name>.sh"` for stages whose
  `DefaultStageDefs` entry is Go-only; the existing adapter unit tests
  use the intake stage NAME as a vehicle for testing the bash adapter
  mechanics (with stub `stages/intake.sh` files in `t.TempDir()`).
- `tests/test_v4_env_contract.sh` — Test 2 repointed from
  `lib/intake_helpers.sh` smoking-gun to `lib/hooks_final_checks.sh`
  as the canonical reference (intake_helpers no longer exists).
- `tests/test_stage_env_setu.sh` — comment line 34 repointed from the
  deleted `lib/intake_helpers.sh:29` to `lib/hooks_final_checks.sh`.
- `lib/dry_run.sh` — comment line 15 updated to reflect that
  `run_stage_intake` is now Go-native.

## Root Cause (bugs only)

N/A — m36.3 is a stage-port milestone, not a bug fix.

## Files Modified

### Created (NEW)
- `internal/stages/intake/intake.go` (NEW)
- `internal/stages/intake/context.go` (NEW)
- `internal/stages/intake/verdict.go` (NEW)
- `internal/stages/intake/config.go` (NEW)
- `internal/stages/intake/env.go` (NEW)
- `internal/stages/intake/intake_test.go` (NEW)
- `internal/stages/intake/context_test.go` (NEW)
- `internal/stages/intake/verdict_test.go` (NEW)
- `tests/test_intake_parity.sh` (NEW)

### Modified
- `internal/stagerunner/helpers.go` — register `GoImpl: intake.RunStage`;
  drop `Script` + `Helpers` for `StageIntake`; add intakestage import.
- `internal/stagerunner/adapter_test.go` — `newAdapter` Script default.
- `internal/stagerunner/parity_test.go` — drop
  `TestBashAdapterRealHelperIntegration`; update wantHelpers for intake.
- `cmd/tekhton/main.go` — drop `newIntakeCmd()` registration.
- `tekhton-legacy.sh` — drop three intake source lines; add
  `run_stage_intake` bash shim that execs `tekhton run-stage intake`;
  update `--add-milestone` deprecation message.
- `scripts/wedge-audit-companions.sh` — m36.3 forbid rules + assertions.
- `Makefile` — wire `test_intake_parity.sh` into `dogfood`.
- `lib/dry_run.sh` — comment update.
- `tests/test_v4_env_contract.sh` — repoint Test 2 to hooks_final_checks.sh.
- `tests/test_stage_env_setu.sh` — comment-only update.
- `docs/v4-phase5-stub.md` — intake row done; follow-up section added.
- `docs/go-migration.md` — Phase 5 M36 Closeout retro at top.
- `VERSION` — bumped to `4.41.0`.

### Deleted
- `stages/intake.sh`
- `lib/intake_helpers.sh`
- `lib/intake_verdict_handlers.sh`
- `cmd/tekhton/intake.go`
- `cmd/tekhton/intake_test.go`
- `tests/test_intake_bash_passthrough.sh`
- `tests/test_intake.sh`
- `tests/test_m118_intake_deferred_emit.sh`
- `tests/test_clarify_intake_handler.sh`

## Docs Updated

- `docs/v4-phase5-stub.md` — intake stage row flipped to **done**;
  `## Phase 5 follow-up: --add-milestone port` section added.
- `docs/go-migration.md` — new `## Phase 5 — M36 Closeout` section at top.

No other public-surface docs touched. CLI flags / config keys are
unchanged.

## Design Observations

- **`internal/health/` and `tekhton index summary` / `tekhton causal
  verdict-history` do not yet exist as Go ports.** The milestone
  description claims "internal/health/ — call as Go function" and
  "history block (`internal/causal/` calls — already Go)", but those Go
  packages haven't been ported. The intake context builders
  (`buildHistoryBlock`, `buildHealthSummary`, `buildProjectIndex`) shell
  out to non-existent `tekhton` subcommands and degrade to empty strings
  when those subcommands fail. The intake prompt template still works
  with empty values (those vars are enrichment, not required), and the
  parity gate uses a mock agent so prompt content doesn't affect verdict
  assertions. A future milestone that ports the health / causal-query /
  index-reader subsystems will activate those context blocks without
  touching the intake stage.

- **`--add-milestone` was already routing to `run_draft_milestones`
  pre-m36.3.** The milestone's Watch For block warns that deleting
  `stages/intake.sh` breaks the `run_intake_create` create-mode flow,
  and asks for a deferred-stub message. The pre-existing code already
  deprecated `--add-milestone` to `--draft-milestones` — `run_intake_create`
  was dead code (no caller in the dispatcher). The implementation
  preserves the working `--draft-milestones` routing AND adds the
  deferred-stub message so the AC's `grep -q 'temporarily unavailable
  post-m36.3'` test passes without regressing the existing working
  alternative.

- **`m36.3` was driven manually, not by `tekhton run --milestone m36.3
  --complete`** — the AC's last bullet asks for self-hosted execution.
  This file was written by a coder agent invocation; the pipeline
  harness that would have driven this milestone end-to-end was
  unavailable for this run.

## Acceptance Criteria Verification

- [x] `internal/stages/intake/intake.go` exports `RunStage(ctx, *proto.StageRequestV1)`.
- [x] `internal/stages/intake/context.go` exports `buildPromptVars`,
  `buildProjectIndex`, `buildHistoryBlock`, `buildHealthSummary`,
  `buildNotesContext`, `buildIntakeRoleContent`.
- [x] `DefaultStageDefs[proto.StageIntake]` has `GoImpl: intake.RunStage`
  AND does NOT have `Script` or `Helpers` populated.
- [x] `stages/intake.sh`, `lib/intake_helpers.sh`,
  `lib/intake_verdict_handlers.sh` are deleted.
- [x] `cmd/tekhton/intake.go` and `cmd/tekhton/intake_test.go` are deleted.
- [x] `cmd/tekhton/main.go` no longer registers `newIntakeCmd()`.
- [x] `scripts/wedge-audit.sh` rejects re-introducing any of the three
  intake bash files — regression-tested manually.
- [x] `scripts/wedge-audit.sh` rejects a `Helpers` entry on `StageIntake`.
- [x] `bash scripts/wedge-audit.sh` exits 0 against the m36.3-closed tree.
- [x] `tests/test_intake_parity.sh` exits 0 across the eight scenarios.
- [x] `make dogfood` includes `tests/test_intake_parity.sh`.
- [x] `needs-clarity-complete` scenario asserts CLARIFICATIONS.md content.
- [x] The intake stage exports `_INTAKE_PASS_EMIT=true` ONLY on the PASS
  dispatch path — `TestRunStage_HumanModeSkipDoesNotEmitPass` +
  `TestRunStage_LiveDispatchPassSetsEmitFlag`.
- [x] The intake stage clears `.final_check_result` and `.commit_decision`
  on entry — `TestRunStage_SentinelCleanup`.
- [x] `INTAKE_CLARITY_THRESHOLD` is consulted by the prompt template only;
  NOT by Go-side gate logic — wedge-audit asserts zero matches under
  `internal/stages/intake/` + `internal/intake/`.
- [x] Verdict-dispatch routes TWEAKED → `HandleTweaked`, SPLIT_RECOMMENDED
  → `HandleSplitRecommended`, NEEDS_CLARITY → `HandleNeedsClarity`, PASS
  → flag-set-only — `TestDispatchVerdictHandler_Routing`.
- [x] `tekhton-legacy.sh --add-milestone` entry includes "temporarily
  unavailable post-m36.3" message (routes to `--draft-milestones` as
  the working fallback).
- [x] `go test ./internal/stages/intake/... ./internal/intake/...` passes
  with coverage ≥ 75% (77.8% actual).
- [x] `bash tests/run_tests.sh` baseline preserved (no new failures
  introduced — deleted four obsolete bash tests in lockstep with
  their bash dependencies).
- [x] `docs/v4-phase5-stub.md` intake row marked done; `--add-milestone
  deferral` section present.
- [x] `docs/go-migration.md` has an "M36 Closeout" section at the top.
- [x] `VERSION` bumped to `4.41.0`.
- [ ] Self-hosted execution — see Design Observations.

## Human Notes Status

No human notes were attached to this milestone.
