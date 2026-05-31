# Reviewer Report — m31.2 UI Gates

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `ui_helpers.go` exports `RenderDiagnosis(DiagnosisInput) string` rather than `WriteGateDiagnosis(w ErrorsWriter, ...) error` as the acceptance criterion specified. The coder extracted the write side into `ErrorsWriter.WriteUIDiagnosis(block)`, making `RenderDiagnosis` a pure renderer. Behavior is byte-identical to the bash heredoc; the design split is cleaner. The API deviation was not declared as an ACP in CODER_SUMMARY.md. Worth noting for the acceptance audit step; not worth a rework cycle.
- `UIPhase` has a `Now func() time.Time` struct field AND accepts `in.Now` from `PhaseInput`. Both are checked in sequence (`p.Now` preferred, `in.Now` as fallback). Other phases (`AnalyzePhase`, `CompilePhase` in `phases.go`) only use `in.Now`. The redundancy is harmless but creates an inconsistency in the Phase API.
- Hardened-timeout clamping in `ui.go:137-139` is done manually (`if hardenedTO > in.Remaining`) rather than via the shared `effectiveTimeout` helper used for the normal-run timeout. Behavior is equivalent; the inconsistency is minor readability debt.
- VERSION reads `4.31.2` at review time (acceptance criterion says `4.31.0`). The coder correctly set it to `4.31.0`; the pipeline's own version-bump logic incremented PATCH twice during subsequent non-milestone runs. Not a coder defect.
- MANIFEST.cfg rows `m31.2|UI Gates|todo` and `m31|Gates Port|split` are expected pre-finalization state. The finalize orchestrator will flip them on approval. Not a coder defect.

## Coverage Gaps
- The 3-run scenario — M54 remediation fires AND its rerun fails AND the generic flakiness retry also fires — has no dedicated unit test. `TestUIPhase_RemediationRetry` only exercises the 2-run path (remediation rerun passes). A test with `exits: []int{1, 1, 1}` and a returning-true Remediator would pin this branch in regression coverage.

## Drift Observations
- `ui.go`: `UIPhase.CmdAvailable func(cmd string) bool` is a public field used as a testability seam for `checkUITestCmdAvailable`. `AnalyzePhase` and `CompilePhase` handle their equivalent availability checks differently (empty-cmd short-circuit, no injectable hook). The asymmetry will be visible to any m57 contributor adding a new Phase — document or normalize the pattern in a future cleanup pass.
