# Coder Summary
## Status: COMPLETE

## What Was Implemented

m34.1 — the docs stage port and the Go-native stage-port pattern that m34.2 +
m35-m39 will inherit.

1. **`StageImpl` type + `StageDef.GoImpl` dispatch wedge.** `internal/stagerunner/helpers.go`
   gains a `StageImpl` type alias for the Go-native stage entry-point signature
   (`func(context.Context, *proto.StageRequestV1) (*proto.StageResultV1, error)`)
   and a `GoImpl StageImpl` field on `StageDef`. `internal/stagerunner/adapter.go::BashAdapter.Run`
   short-circuits to a new `runGo` helper when `def.GoImpl != nil`; otherwise the
   existing bash sourcing chain runs unchanged. `stageDefFor` was relaxed so
   overrides with only `GoImpl` set (no `Script`) are accepted. Behavior-preserving
   for every un-ported stage.

2. **`internal/stages/staglog` helper.** ~100 LOC `Logger` interface +
   `New(req) Logger` constructor providing `Header / Info / Warn / Success`.
   Header emits the `[pos/count] StageName` format mandated by the m34.1
   acceptance regex. m35-m39 reuse this; expansions stay minimal-first.

3. **`internal/stages/docs/` package.** First Go-native stage, ported from
   `stages/docs.sh` (93 LOC bash) + `lib/docs_agent.sh` (153 LOC bash).
   - `stage.go::RunStage` — entry point matching `StageImpl`. Walks the
     three gates (disabled / skip-flag / no-public-surface-change) and
     dispatches to a stubbable `AgentRunner` for the agent call. Never
     returns `verdict=fail` (matches bash semantics where every branch
     ends with `return 0`).
   - `prepare.go::prepareTemplateVars` — port of `_docs_prepare_template_vars`.
     Returns a map (no env-pollution) with `CODER_SUMMARY_CONTENT`,
     `DOCS_GIT_DIFF_STAT`, `DOCS_SURFACE_SECTION`, plus the always-seeded
     `DOCS_README_FILE / DOCS_DIRS / DOCS_AGENT_REPORT_FILE` defaults.
   - `skip.go::shouldSkip` + helpers — port of `docs_agent_should_skip`
     + `_docs_extract_doc_responsibilities` + `_docs_extract_public_surface`
     + `_docs_changed_files_match_surface`. Glob `*` → Go `regexp` (bash
     sed transform `s/\./\\./g; s/\*/.*/g` ported verbatim). Always seeds
     `README.md`, `DOCS_README_FILE`, and `DOCS_DIRS` as default surface
     patterns even when the CLAUDE.md section is empty.

4. **Wired `docs.RunStage` into `DefaultStageDefs[StageDocs]`.** `Script: "stages/docs.sh"`
   stays set as the audit-trail signal documented in m34's parent goal;
   `Helpers` slice was dropped (lib/docs_agent.sh no longer exists).
   `parity_test.go::TestDefaultStageDefsHelpersMatchLegacy` updated to expect
   an empty Helpers slice for docs.

5. **Deleted bash docs stage + helpers.** `stages/docs.sh`, `lib/docs_agent.sh`,
   `tests/test_docs_agent_helpers.sh`, `tests/test_docs_agent_skip_path.sh`,
   `tests/test_docs_agent_stage_smoke.sh` — all `git rm`'d. The two source
   lines in `tekhton-legacy.sh` were replaced with a comment block explaining
   the port. `tests/test_docs_agent_pipeline_order.sh` is preserved (it tests
   `lib/pipeline_order.sh`, not the deleted files).

6. **Wedge-audit hardening.** `scripts/wedge-audit-companions.sh` extended
   to fail when either deleted file is re-introduced.

7. **Parity harness.** `tests/test_stage_port_parity.sh` (140 LOC) drives
   `tekhton run-stage docs` against two scenarios — `docs-disabled` (env
   gate fires) and `docs-no-surface` (public-surface check fires) — and
   asserts `(verdict, exit_reason)` matches the bash baseline. Wired into
   `make dogfood`. Designed to be extended by m34.2 + m35-m39 (drop a
   fixture + an expectation, no harness change required).

8. **`docs/go-migration.md` pattern ADR.** New `## Stage-Port Pattern (m34)`
   section documents the dispatch precedence, per-stage package layout,
   bash-coexistence guarantees, and parity-baseline-capture protocol.
   m35-m39 link to this instead of re-deriving.

9. **VERSION bumped to `4.34.0`.**

## Root Cause (bugs only)
N/A — feature milestone, not a bug fix.

## Files Modified

### Created
- `internal/stages/docs/stage.go` (NEW) — RunStage entry point + agent-runner seam
- `internal/stages/docs/stage_test.go` (NEW) — per-gate table tests + property "never fail" test
- `internal/stages/docs/prepare.go` (NEW) — template variable preparation
- `internal/stages/docs/prepare_test.go` (NEW) — var-population tests
- `internal/stages/docs/skip.go` (NEW) — should-skip logic + helpers
- `internal/stages/docs/skip_test.go` (NEW) — gate-decision tests
- `internal/stages/staglog/staglog.go` (NEW) — shared colored-output Logger
- `internal/stages/staglog/staglog_test.go` (NEW) — Header format + level prefix tests
- `tests/test_stage_port_parity.sh` (NEW) — m34.1 parity gate (2 scenarios; extends in m34.2+)

### Modified
- `internal/stagerunner/helpers.go` — added `StageImpl` type, `StageDef.GoImpl` field, wired `docs.RunStage`
- `internal/stagerunner/helpers_test.go` — added `NoDoubleWiredEntry / DocsHasGoImpl / DocsDropsBashHelper` assertions
- `internal/stagerunner/adapter.go` — added dispatch wedge + `runGo` helper, relaxed `stageDefFor`
- `internal/stagerunner/adapter_test.go` — added `GoDispatch / NilResult / StampsDuration` cases
- `internal/stagerunner/parity_test.go` — `wantHelpers[StageDocs]` is now empty
- `tekhton-legacy.sh` — replaced docs source lines with port-explanation comment
- `scripts/wedge-audit-companions.sh` — added m34.1 deleted-file regression gate
- `Makefile` — wired `test_stage_port_parity.sh` into `dogfood`
- `docs/go-migration.md` — appended `## Stage-Port Pattern (m34)` ADR section
- `VERSION` — bumped to `4.34.0`

### Deleted
- `stages/docs.sh` — ported to `internal/stages/docs/stage.go` + `prepare.go`
- `lib/docs_agent.sh` — ported to `internal/stages/docs/skip.go`
- `tests/test_docs_agent_helpers.sh` — superseded by `internal/stages/docs/skip_test.go`
- `tests/test_docs_agent_skip_path.sh` — superseded by `internal/stages/docs/skip_test.go`
- `tests/test_docs_agent_stage_smoke.sh` — superseded by `internal/stages/docs/stage_test.go`

## Docs Updated

- `docs/go-migration.md` — new `## Stage-Port Pattern (m34)` section
  documenting the dispatch precedence + package layout for m35-m39.

`ARCHITECTURE.md` was not updated in this milestone; the architecture entries
for `internal/stages/docs/`, `internal/stages/staglog/`, and the dispatch
wedge will land alongside m34.2's closeout when the pattern is exercised by
a second stage (avoids documenting a one-stage "pattern" that may evolve
when the cleanup stage's port reveals new constraints). The Stage-Port
Pattern ADR in `docs/go-migration.md` is the implementer reference for the
interim.

## Human Notes Status

No unchecked human notes for this run.

## Test Results

- **Go unit tests** — `go test ./...` all packages green; `internal/stages/docs`
  reaches 90% statement coverage (acceptance gate is 75%).
- **Shellcheck** — `shellcheck tekhton.sh lib/*.sh stages/*.sh` clean.
- **`tests/test_stage_port_parity.sh`** — 2/2 scenarios pass.
- **`tests/test_docs_agent_pipeline_order.sh`** — 19/19 pass (preserved test
  on `lib/pipeline_order.sh`).
- **Bash test suite** — see `tests/run_tests.sh` output; no new failures
  introduced by m34.1 (the deleted docs tests are intentional retirements).

## Build Fixes

Build-fix re-entry on the `unknown_only` routing path (no recognized error
signatures, no `BUILD_ERRORS.md` on disk). Reproduced every gate the
build-fix loop would have run; all clean. No code changes were required.

Second re-entry on the same `unknown_only` path (still no `BUILD_ERRORS.md`
on disk, routing prompt embedded only the diagnostic stub). All gates
re-run against the unchanged working tree — `go build ./...`, `go vet ./...`,
`shellcheck tekhton.sh lib/*.sh stages/*.sh`, `go test ./...` (every package
green including `internal/stages/docs`, `internal/stages/staglog`,
`internal/stagerunner`, and the 36s `internal/supervisor` suite),
`tests/test_stage_port_parity.sh` (2/2: `docs-disabled`, `docs-no-surface`),
and `tests/test_finalize_parity.sh`. No changes made; m34.1 still ships as
originally summarized.

Gates re-run against the current working tree:

- `go build ./...` — exit 0.
- `go vet ./...` — exit 0.
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — exit 0.
- `go test ./...` — every package green, including the m34.1 additions
  (`internal/stages/docs`, `internal/stages/staglog`) and the
  `internal/stagerunner` dispatch wedge tests (`GoDispatch`, `NilResult`,
  `StampsDuration`, `NoDoubleWiredEntry`, `DocsHasGoImpl`,
  `DocsDropsBashHelper`).
- `bash tests/test_stage_port_parity.sh` — 2/2 scenarios
  (`docs-disabled`, `docs-no-surface`).
- `bash tests/test_finalize_parity.sh` — green.
- `bash tests/run_tests.sh` — full suite passes 501/0 shell + all Go.

Routing observations:

- `.tekhton/BUILD_ERRORS.md` does not exist on disk; the routing prompt's
  embedded `BEGIN FILE CONTENT: BUILD_ERRORS` block carried only the
  `unknown_only` diagnostic, not an error payload.
- The stale `.tekhton/COMPLETION_GATE_LAST_FAILURE.log` artifact present
  in `.tekhton/` is from 2026-05-31 (milestone 32.2,
  `test_drift_prompts.sh` failure) and pre-dates the m34.1 work
  reflected in this summary — it is not the failure that triggered this
  re-entry.
- `test_m29_milestone_conformance.sh` flaked once during reproduction
  (failed in a full-suite run, then passed every subsequent run —
  standalone, positional-override through `run_tests.sh`, and a second
  full-suite run). It is a read-only conformance assertion against
  `.claude/milestones/MANIFEST.cfg` + git history; the production
  milestone directory state is correct (m29.1/m29.2 absent, MANIFEST
  rows `done`), so any flake is upstream pollution from an earlier
  test, not a code defect. Out of scope for this build-fix pass.

m34.1 ships as previously summarized; no scope changes.

## Verification Against m34.1 Acceptance Criteria

Every acceptance criterion in the milestone definition is met:
- `StageImpl` type declared ✓
- `StageDef.GoImpl` field of type `StageImpl` ✓
- `DefaultStageDefs[StageDocs].GoImpl` non-nil ✓
- `Helpers` no longer contains `lib/docs_agent.sh` ✓
- `BashAdapter.Run` dispatches to `def.GoImpl` and skips bash chain ✓
- `internal/stages/docs/` compiles + vets clean ✓
- All four skip/disabled/skip-flag/agent-failed paths return correct verdicts ✓
- `RunStage` never returns `verdict=fail` ✓
- `shouldSkip` returns false (run) when CLAUDE.md or section absent ✓
- `extractPublicSurface` always seeds defaults ✓
- `Logger.Header` matches `^\[\d+/\d+\] [A-Z][a-zA-Z]+$` ✓
- `stages/docs.sh` and `lib/docs_agent.sh` do not exist on disk ✓
- `tests/test_stage_port_parity.sh` passes both scenarios ✓
- `make dogfood` includes `test_stage_port_parity` ✓
- `scripts/wedge-audit.sh` exits 0 ✓
- Go test coverage ≥ 75% on `internal/stages/docs/` (90% achieved) ✓
- No remaining bash callers reference deleted helpers ✓
- `docs/go-migration.md` has `## Stage-Port Pattern (m34)` section ✓
- `VERSION` reads `4.34.0` ✓
