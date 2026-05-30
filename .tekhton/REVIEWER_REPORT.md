# Reviewer Report — m33.2 Dashboard Parsers (Review Cycle 1)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
None

## Simple Blockers (jr coder)
None

## Non-Blocking Notes
- `parse_reviewer.go:19` — `mustCompileAnchored` is a misleading name. The function is `regexp.MustCompile` verbatim; the anchors come from the caller's pattern string, not from this helper. Rename to `mustCompile` or drop the helper and inline `regexp.MustCompile` directly.
- `parse_intake.go:25` — `statusInlineRE` is declared in the intake parser's var block but consumed only by `parse_coder.go:28`. Cross-file sharing within a package is valid Go, but the variable should live next to its only caller. Move to `parse_coder.go`.
- `parse_intake.go:109` — `atoiSafe` manually re-implements digit-by-digit parsing instead of `strconv.Atoi`. Input is already constrained to pure-digit strings by the calling regex, so `strconv.Atoi` is equivalent and more idiomatic. Harmless, but nonstandard.
- `parse.go:35` — `NewStatusReader(e *Emitter)` diverges from the milestone spec's stated constructor signature `NewStatusReader(env *runner.StageEnvV1)`. Avoiding the `internal/runner` dependency is the right call (cleaner layering), but the deviation from the acceptance criterion text should be noted at MANIFEST sync.
- `tests/test_dashboard_parse_parity.sh:14-15` — Parity gate documents the substitution: shape assertions on fixtures instead of byte-for-byte comparison against captured bash output (unavoidable since the bash parsers are deleted in this same milestone). The trade-off is correct; the comment documents why.

## Coverage Gaps
- `parse_runs.go::parseMetricsJSONL` — no unit test for an existing but zero-byte or all-blank `metrics.jsonl` file. `os.Open` succeeds, the scanner produces no lines, and the function returns nil, correctly triggering the `RUN_SUMMARY_*.json` fallback. Low-priority since the `MissingInputs` test covers absent files and the fallback contract is covered by `TestParseRunSummaries_FromRunSummaryFiles`.

## ACP Verdicts
No `## Architecture Change Proposals` section in CODER_SUMMARY.md.

## Drift Observations
- `internal/dashboard/emit_reports.go:84-101` — `parseTestAudit` stays inline in the emitter rather than behind a `StatusReader` method. Reasonable for now (simpler than the other parsers), but `EmitReports` is the only emit function that doesn't follow the `e.statusReader().Parse<Kind>(...)` pattern. If a `ParseTestAudit` method is ever needed for a Cobra arm or isolation testing, the pattern will need retrofitting.
- `lib/diagnose_output_extra.sh::emit_dashboard_diagnosis` + `internal/dashboard` — Two write paths remain for `data/diagnosis.js`: bash `emit_dashboard_diagnosis` (via the inlined `_diagnose_write_js_file` helper) and Go `EmitDiagnosis`. Coder correctly marks this out-of-scope; surfacing here so it reaches the drift audit cycle.
- The three m33.1 non-blocking notes carried forward (from the prior review cycle) that were in-scope for m33.2: (1) `dashboard_shim.sh` stale source line — RESOLVED (removed). (2) `dashboard_v1_extra.go:154` camelCase init fields — still present but unchanged by m33.2 scope; remains a pending concern for the JS reader alignment check.
