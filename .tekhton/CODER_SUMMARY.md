# Coder Summary

## Status: COMPLETE

## What Was Implemented

m26 — Stage and Finalize Env Contract. The Phase 5 sequencing gate that
established a single typed `StageEnvV1` contract spanning pipeline.conf
+ run-request flags, consumed identically by every stage subprocess and
every finalize hook. Closes the unbound-variable cascade that prevented
m20–m22 milestone-mode runs from completing end-to-end.

This pipeline run found the m26 implementation already landed across
prior dogfooded passes (commits leading to VERSION 4.27.2; m26 row in
MANIFEST.cfg is `done`; m27 already followed on top). Cycle work was:

- **Verified the m26 surface is intact**:
  - `internal/proto/stage_env.go` declares `StageEnvV1` with
    `StageEnvProtoV1 = "tekhton.stage_env.v1"` and the runtime-flag /
    log-channel / ConfigKeys field groups.
  - `internal/runner/env.go` exposes `NewEnvBuilder`, `Compose`, `AsKV`,
    `LogContext.LogFile`, `taskSlug` — three-layer composition with
    overrides beating request flags beating config.
  - `internal/runner/single.go:buildPipelineRequest` composes the env
    once and applies it uniformly across every stage in
    `defaultStageOrder()`. No per-stage curation remains.
  - `internal/finalize/shim.go:buildEnv` consumes `Input.EnvKV` for the
    m26 contract path and falls back to `legacyEnvFallback` for callers
    that haven't been migrated.
  - `internal/finalize/orchestrator.go` plumbs `Input.RunRequest` and
    `Input.EnvKV` through every hook.
  - `cmd/tekhton/run.go:buildRunner` constructs the env builder via
    `buildEnvBuilder`, wires it onto both the Runner and the
    BashHookRunner, and surfaces a stderr warning when pipeline.conf is
    missing (defaults-only path).
  - `docs/v4-env-contract.md` documents the producer/consumer split,
    the field groups, the defaults-only path, and the "How to add a
    new bash global" recipe.
- **Added the missing smoke test** specified in the milestone's
  Files Modified table: `TestBuildRunner_EnvBuilderWired` in
  `cmd/tekhton/run_test.go` asserts that `buildRunner` always produces
  a non-nil `*runner.EnvBuilder` on the Runner AND the same builder is
  shared with the BashHookRunner. A regression that nil'd out either
  field would silently re-create the unbound-variable cascade m26
  closed; this test is the early-warning gate.
- **Verified Go and shell test gates** pass on this tree:
  - `go test ./...` — all packages green.
  - `bash tests/test_v4_env_contract.sh` — 3/3 contract assertions pass
    (runtime-flag set reachable under `set -u`,
    `lib/intake_helpers.sh` smoking-gun functions clean, `finalize_shim.sh`
    dispatches without unbound-variable crashes).
  - `shellcheck tekhton.sh lib/*.sh stages/*.sh` — zero warnings.

The end-to-end pipeline parity test (`tests/test_v4_pipeline_e2e.sh`)
called out in the milestone's acceptance list remains deferred —
`tests/test_v4_env_contract.sh` documents the rationale: `--dry-run` is
accepted as a flag but `cmd/tekhton/run.go:83-89` notes "no dispatch
branch consumes it yet — every path below invokes agents for real." A
real end-to-end test without working dry-run would require live agent
invocation. The focused contract test (`test_v4_env_contract.sh`) is the
working substitute today; the heavyweight e2e test is a future-milestone
follow-up once `--dry-run` actually short-circuits agents.

## Root Cause (bugs only)

N/A — m26 is a contract milestone, not a bug fix.

## Files Modified

- `cmd/tekhton/run_test.go` — added `TestBuildRunner_EnvBuilderWired`
  smoke test and the `runner` import it needs. Asserts `r.Env != nil`
  AND `r.Hooks.(*runner.BashHookRunner).Env != nil` AND both fields
  share the same builder (so a future regression that nil's out either
  is caught early).

The m26 implementation itself (the `internal/proto/stage_env.go`,
`internal/runner/env.go`, `internal/runner/single.go`,
`internal/finalize/shim.go`, `internal/finalize/orchestrator.go`,
`cmd/tekhton/run.go`, and `docs/v4-env-contract.md` changes) was
already landed by prior dogfooded passes — verified in this cycle but
not re-edited.

## Human Notes Status

No human notes listed for this run.

## Docs Updated

None — no public-surface changes in this cycle. `docs/v4-env-contract.md`
already documents the contract from the prior m26 implementation pass.

## Observed Issues (out of scope)

- `tests/test_drift_prompts.sh` fails intermittently when run via
  `tests/run_tests.sh` (test-suite ordering issue — state from an
  earlier test bleeds in) but passes cleanly when run standalone.
  Predates m26 (the test file's last change is commit `c8c7daf`,
  pre-V4). Not introduced by this cycle; flag for separate
  investigation.

## Architecture Change Proposals

None — m26 is the contract milestone the V4 architecture already
anticipated; nothing here changes the architecture map.
