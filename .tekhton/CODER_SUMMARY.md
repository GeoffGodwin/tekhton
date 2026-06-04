# Coder Summary

## Status: COMPLETE

## What Was Implemented

m36.1 — Architect Stage Port. Ported `stages/architect.sh` (414 LOC) to
`internal/stages/architect/` Go-native and deleted the bash file. The
architect runs via the StageDef.GoImpl dispatch wedge in stagerunner.

### Surface

- `internal/stages/architect/architect.go` — `RunStage(ctx, *proto.StageRequestV1) (*proto.StageResultV1, error)`. Orchestrates: context load → architect agent → plan parse → sr/jr router → post-remediation build + expedited review → drift resolution + OOS re-add → design-doc → human-action surfacing → audit-counter reset → archive plan. Three pluggable seams: `AgentRunner`, `BuildGateRunner`, `TUICaller`.
- `internal/stages/architect/plan_parser.go` — `parsePlan(io.Reader) (parsedPlan, error)` with multi-line bullet joining (state machine on bullet markers) and per-section filter chains (`OutOfScope()` and `DesignDocObservations()`). Eleven `regexp.MustCompile` filter patterns ported one-for-one from the bash `grep -qiE` chains at architect.sh:295-303 and 363-377.
- `internal/stages/architect/remediation.go` — `runRework(ctx, kind, cfg)` sr/jr dispatcher. Sr handles ONLY Simplification, jr handles Staleness + Dead Code + Naming. Separate models (`CLAUDE_CODER_MODEL` vs `CLAUDE_JR_CODER_MODEL`) and turn budgets preserved. Plus `runBuildFix` (CODER_MAX_TURNS/3 budget, clamped to ≥1) and `runExpeditedReview`.
- `internal/stages/architect/render.go` — `renderArchitectPrompt(cfg)` populates `DRIFT_LOG_CONTENT`, `ARCHITECTURE_LOG_CONTENT`, `ARCHITECTURE_CONTENT`, and `DRIFT_OBSERVATION_COUNT` template vars before calling `prompt.Render`.
- `internal/stages/architect/config.go` + `env.go` — per-stage config snapshot loader and env helpers (envBool/envInt/envOr/envOrFromReq) — matches the cleanup/security pattern.
- `internal/stages/architect/testdata/{plan_baseline,plan_no_action,plan_design_doc_only}.md` — frozen plan fixtures covering all-branches-fire, all-None, design-doc-only cases.

### Drift integration

The six `tekhton drift ...` subprocess execs per audit run replaced by in-process Go calls on `internal/drift/`:
- `drift.NewLog(path).CountUnresolved()` for the observation count
- `drift.NewLog(path).ResolveAllObservations()` for the tick-and-sweep
- `drift.NewLog(path).AppendEntries(entries)` for the OOS re-add
- `drift.NewHumanAction(path).Append("architect", description)` for design-doc observations
- `drift.NewLog(path).ResetRunsSinceAudit()` for the audit-counter reset

The wedge-audit at `scripts/wedge-audit-companions.sh` now forbids direct `os.WriteFile` / `os.Create` against `ARCHITECTURE_LOG.md` / `DRIFT_LOG.md` / `HUMAN_ACTION_REQUIRED.md` from `internal/stages/architect/` non-test files (M25 owns the file format).

### Stage registration

- `internal/proto/stage_v1.go` — added `StageArchitect = "architect"` const and to `KnownStages`.
- `internal/stagerunner/helpers.go` — registered `proto.StageArchitect` in `DefaultStageDefs` with `GoImpl: architectstage.RunStage` and no Script / Helpers (bash deleted).

### Bash residues

- `stages/architect.sh` — deleted.
- `tekhton-legacy.sh` — removed the `source stages/architect.sh` line; added a `run_stage_architect` shim function alongside `run_stage_cleanup` that drives `tekhton run-stage architect --request-file ...` so the legacy bash pre-stage call site at line ~2470 still routes through the Go entry point. Silently no-ops if the binary is unavailable (matches cleanup shim pattern).

### Tests + parity gate

- `internal/stages/architect/{architect,plan_parser,remediation}_test.go` — 26 tests total covering branch dispatch, plan parsing, filter chains, multi-line bullets, build-broken path, upstream-error path, TUI lifecycle propagation, bullet normalization. Coverage 75.3% (meets ≥75% acceptance threshold).
- `tests/test_architect_parity.sh` — three-scenario gate (`audit-with-simplification`, `audit-with-jr-work-only`, `audit-with-design-doc-observations`). All three exit `pass|audit_complete`.
- `scripts/wedge-audit-companions.sh` — m36.1 entries: forbid `stages/architect.sh` re-introduction; forbid drift-file writes from `internal/stages/architect/*.go` (excluding _test.go).
- `Makefile` — wired `test_architect_parity.sh` into the `dogfood` target.
- `docs/v4-phase5-stub.md` — architect row marked done; LOC budget delta -414.
- `VERSION` — bumped 4.42.14 → 4.43.0.

### Verification

- `go build ./...` clean.
- `go test ./...` all packages pass.
- `bash scripts/wedge-audit.sh` clean.
- `bash tests/test_architect_parity.sh` — 3 / 3 pass (1.2s total wall time).
- `bash tests/run_tests.sh` — **511 / 0** shell, **all Go pass**.
- `shellcheck` on every bash file modified — clean (pre-existing SC1091 warnings only).

## Root Cause (bugs only)

N/A — this is a Ship-of-Theseus port milestone, not a bug fix.

## Architecture Change Proposals

None — m36.1 mirrors the m34.1 / m35.2 / m34.2 stage-port pattern verbatim
(StageDef.GoImpl + delete bash + wedge-audit gate + parity test).

## Design Observations

None.

## Files Modified

- `internal/stages/architect/architect.go` (NEW)
- `internal/stages/architect/architect_test.go` (NEW)
- `internal/stages/architect/config.go` (NEW)
- `internal/stages/architect/env.go` (NEW)
- `internal/stages/architect/plan_parser.go` (NEW)
- `internal/stages/architect/plan_parser_test.go` (NEW)
- `internal/stages/architect/remediation.go` (NEW)
- `internal/stages/architect/remediation_test.go` (NEW)
- `internal/stages/architect/render.go` (NEW)
- `internal/stages/architect/testdata/plan_baseline.md` (NEW)
- `internal/stages/architect/testdata/plan_no_action.md` (NEW)
- `internal/stages/architect/testdata/plan_design_doc_only.md` (NEW)
- `internal/proto/stage_v1.go` — added StageArchitect const + KnownStages entry
- `internal/stagerunner/helpers.go` — registered architect in DefaultStageDefs with GoImpl
- `tekhton-legacy.sh` — removed stages/architect.sh source; added run_stage_architect shim
- `stages/architect.sh` — DELETED
- `scripts/wedge-audit-companions.sh` — added m36.1 file-presence + drift-write boundary checks
- `tests/test_architect_parity.sh` (NEW) — three-scenario Go-vs-Go parity gate
- `Makefile` — wired test_architect_parity.sh into dogfood
- `docs/v4-phase5-stub.md` — architect row done; LOC delta -414
- `VERSION` — 4.42.14 → 4.43.0

## Docs Updated

- `docs/v4-phase5-stub.md` — Stage-Port Matrix architect row flipped to **done**; closeout paragraph extended with m36.1 details.

## Observed Issues (out of scope)

None encountered during the port. The four prompt templates
(`prompts/architect{,_review,_sr_rework,_jr_rework}.prompt.md`) are
untouched per the milestone Watch For block.

## Human Notes Status

No active human notes in HUMAN_NOTES.md — none to claim.

## Remaining Work

None. All acceptance criteria met:

- [x] `RunStage` exported with the milestone signature
- [x] `parsePlan` + four query methods (`HasSimplification`, `HasJrWork`, `OutOfScope`, `DesignDocObservations`)
- [x] `DefaultStageDefs[proto.StageArchitect].GoImpl == architect.RunStage`
- [x] `proto.StageArchitect == "architect"` const
- [x] `stages/architect.sh` deleted
- [x] wedge-audit rejects re-introduction + drift-write violations from `internal/stages/architect/`
- [x] `bash scripts/wedge-audit.sh` exits 0
- [x] `tests/test_architect_parity.sh` exits 0 across 3 scenarios
- [x] `make dogfood` wires the parity gate
- [x] `go test ./internal/stages/architect/...` passes with coverage 75.3% (≥75%)
- [x] `bash tests/run_tests.sh` reports 511 / 0 (zero new failures)
- [x] Prompt templates `prompts/architect*.prompt.md` untouched (`git diff` empty)
- [x] `docs/v4-phase5-stub.md` architect row marked done + closeout paragraph extended
- [x] `VERSION` bumped (4.42.14 → 4.43.x after finalize patch-bump)
