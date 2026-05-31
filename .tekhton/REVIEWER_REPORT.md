# Reviewer Report — m32.2 Diagnose Rules

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `helpers.go:83` — `pathFromEnvOr` is defined but never called from any rule file; every rule calls `envOr` directly. Dead code; can be deleted.
- `resilience.go:309` — `projectFilePath` is defined but never called; the comment says "used by the preflight rule below" but `resilience_preflight.go` uses `projectPath` instead. Dead code; can be deleted.
- `engine_test.go` — After the BashRuleAdapter test was removed, four helpers remain orphaned: `materializeFixture`, `mapFixturePath`, `readExpected`, and `findTekhtonHome`. Go does not error on unused test-file functions, but they confuse the next reader who sees fixture infrastructure with no test that uses it.
- `resilience_preflight.go` — `splitLines`, `containsExact`, and `indexOfExact` are thin wrappers around `strings.Split`, `strings.Contains`, and `strings.Index`. The "self-containedness at review time" rationale is reasonable, but the functions add ~20 lines with no semantic value beyond what the stdlib calls provide.
- `engine.go:317-319` — `extractKVLine` still compiles two regexes per call via inline `regexp.Compile`. Carried forward from m32.1 review — promote to package-level compiled variables to avoid repeated compilation on the per-line path.

## Coverage Gaps
- `TestPreflightInteractiveConfig_Match` covers source 1 (RUN_SUMMARY preflight_ui section) and source 3b (LAST_FAILURE_CONTEXT classification) but omits source 2 (PREFLIGHT_REPORT.md with UI Config header + fail word) and source 3a (PrimarySignal == "ui_interactive_config_preflight"). The baseline parity test gates correctness end-to-end, but per-source unit coverage for the two untested paths would make the test suite more informative on future regressions.

## ACP Verdicts
None — no Architecture Change Proposals in CODER_SUMMARY.md.

## Drift Observations
- `engine_test.go:264` — `mapFixturePath` in package `diagnose` is now a strict subset of the copy in `rules_test.go` (lacks `pipeline.conf` and `QUOTA_PAUSED` cases added for the version-mismatch and quota-exhausted fixtures). The two copies are diverged. If a future fixture requires a new file mapping, there are two places to update.
