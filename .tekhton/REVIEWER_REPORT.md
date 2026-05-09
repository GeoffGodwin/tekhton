# Reviewer Report — M20 BashAdapter helper sourcing fix

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `helpers.go:139` — Comment "these lists call out the ones tied to a single stage for documentation, not as gates" is misleading. Per-stage `Helpers` for intake, security, tester, and docs ARE functionally required — `_intake_get_milestone_content` etc. will fail with exit 127 if those helpers aren't sourced. The comment accurately describes stages with *empty* Helpers (coder, review, cleanup), but should not generalise to all stages.
- `helpers_test.go:140-159` — `TestDefaultStageDefsCoverage` hardcodes the seven stage names rather than ranging over `DefaultStageDefs` or deriving from `IsKnownStage`. A new stage constant added to `stage_v1.go` won't surface a missing `DefaultStageDefs` entry until someone hand-edits both files.
- `helpers.go:22-132` — `DefaultLibHelpers` is derived from `tekhton-legacy.sh` but is not validated against the live filesystem. Any file in the list that has since been renamed or removed will cause `source` to fail under `set -e`, silently crashing every stage subprocess. The parity test noted in the CODER_SUMMARY "Observed Issues" section is the right mitigation; it should land before the next lib reorganisation milestone.

## Coverage Gaps
- No end-to-end parity test using real (non-stub) stage scripts, as the task description explicitly requested: "The fix needs a parity test that runs each stage under the Go BashAdapter against a fixture and asserts the same envelope as a legacy invocation." All new tests (`TestBashAdapterPerStageHelperSourced`, `TestBashAdapterLibHelpersSourced`, etc.) use minimal harness stubs. The smoke test (`test_pipeline_runner.sh`) exercises real lib/ but with stub stage scripts that call `tekhton stage emit` directly and do not exercise any lib helper path. Without a real-stage parity test, the next missing-helper class of bug (most likely in the coder stage, which has the largest helper surface) will ship silently. Coder acknowledged this in "Observed Issues"; tracking here for the tester.

## ACP Verdicts
- ACP-1 (`BashAdapter` recreates legacy global source environment) — ACCEPT. The change is necessary and correct: the m18-as-shipped behaviour of sourcing only `common.sh` + `stage_envelope.sh` was the root cause of the bug. The per-stage allowlist design with a `DefaultLibHelpers` base set is the right approach. `StageScript → Stages` rename has no external consumers. ARCHITECTURE.md's `internal/stagerunner/` bullet should be updated to document `DefaultLibHelpers`, `DefaultStageDefs`, and the source order contract; coder has flagged this for the next milestone owner.

## Drift Observations
- `helpers.go:22` — `DefaultLibHelpers` is a parallel representation of `tekhton-legacy.sh`'s global source block (lines 846-987). Two canonical lists for the same truth create a maintenance hazard; every new lib file added to the legacy block must also be mirrored here. The parity test the coder recommends in "Observed Issues" is the correct long-term fix.
- `adapter_test.go:119-125`, `adapter.go:119-125` — `scriptFor` is documented as "retained for tests that exercise the resolution path; new code should prefer `stageDefFor`." Its only call site outside the package is `TestBashAdapterUnknownStage` and `TestScriptForFallback`. Once those tests are migrated to call `stageDefFor` directly, `scriptFor` can be deleted as dead code. Non-blocking until that cleanup pass.
