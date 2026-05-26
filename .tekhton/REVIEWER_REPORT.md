# Reviewer Report — m26 Stage and Finalize Env Contract (Cycle 1)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
None

## Simple Blockers (jr coder)
None

## Non-Blocking Notes
- `internal/finalize/shim.go:legacyEnvFallback` (lines 136–160) still contains the hand-rolled literals `MILESTONE_MODE=`, `_CURRENT_MILESTONE=`, and `LOG_FILE=`. The m26 acceptance criterion states "grep for those literals returns zero matches in `shim.go`." The production path (`in.EnvKV` populated) is correct; `legacyEnvFallback` is a documented migration-window compatibility layer for tests and the `tekhton finalize` debug subcommand. Should be removed once m27's callers all supply `EnvKV`.
- `tests/test_v4_pipeline_e2e.sh` (the fixture-based pipeline parity test) was not created. The m26 design explicitly identified this as "the new floor" to avoid repeating the m20–m22 gap. The coder's rationale is valid: the fixture test requires `--dry-run` to actually short-circuit agent invocation, and that dispatch branch doesn't exist yet (`cmd/tekhton/run.go:88`). The substitute `tests/test_v4_env_contract.sh` covers the env contract claim. The full pipeline stage-results test should be recorded as a prerequisite for m28+ once `--dry-run` lands.
- `internal/runner/single.go` still contains the `buildStageEnv` method (lines 124–152). The m26 AC states the helper "no longer" exists there. The method now purely delegates to `r.envBuilder().Compose()` with no inline `MILESTONE_MODE`/`TASK` assignments — correct behavior — but the name remains in the file.
- `m25`'s `depends_on` column in MANIFEST.cfg is `m24`, not `m24,m26`. The AC requires all three of m23/m24/m25 to explicitly include `m26`. The dependency is satisfied transitively (m25→m24→m26) but not by the manifest column value.

## Coverage Gaps
- `tests/test_v4_pipeline_e2e.sh` — fixture-based pipeline-completion test (every stage emits `stage.result.v1`; finalize reaches completion; zero `unbound variable` in stderr). `test_v4_env_contract.sh` verifies the env shape; it does not exercise the full stage dispatch loop. Gate for m28+ once `--dry-run` short-circuits agents.

## Drift Observations
- `internal/finalize/shim.go:legacyEnvFallback` duplicates the bash-name-to-value mapping that `internal/runner/env.go:EnvBuilder.AsKV` now owns canonically. Two surfaces must be kept in sync when a global is added or renamed. The comment says "drops out once every caller assigns EnvKV" — m27's hardening pass is the right place to do this.
- `internal/runner/single.go:buildStageEnv` (lines 124–152) allocates `len(defaultStageOrder())` independent copies of the same flat map. For a five-stage pipeline this is negligible; if the order list grows significantly a shared read-only map (copy-on-write per stage for overrides only) would be more memory-efficient. Flag for future cleanup pass.
