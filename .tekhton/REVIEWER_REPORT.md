# Reviewer Report — m35.1 Security Helpers Port

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
None

## Simple Blockers (jr coder)
None

## Non-Blocking Notes
- `internal/security/escalation.go::NewEscalator` constructs the HUMAN_ACTION_REQUIRED.md path as `projectDir/.tekhton/HUMAN_ACTION_REQUIRED.md`, but the production CLI in `cmd/tekhton/security.go` uses `humanActionPath(projectDir)` which resolves to `projectDir/HUMAN_ACTION_REQUIRED.md` (no `.tekhton/` prefix, per the drift CLI convention). In m35.1 this is harmless — only the CLI path is exercised by the bash shim — but in m35.2 a Go RunStage that calls `NewEscalator` would write to the wrong file and silently diverge from where bash writes today. Recommend either updating `NewEscalator` to use `humanActionPath` (or a shared equivalent), or adding a prominent comment that this constructor is test-only and m35.2 must use `NewEscalatorWithPath(humanActionPath(projectDir))`.

## Coverage Gaps
None

## ACP Verdicts
No Architecture Change Proposals section in CODER_SUMMARY.md.

## Drift Observations
- `cmd/tekhton/security_test.go` introduces `buildTekhtonBinary`, `filterEnv`, `readFileTrimNothing`, and `writeFile` as file-local helpers within `package main`. These patterns will be needed by any future `cmd/tekhton` test that must assert on OS-level exit codes via a real subprocess (meets-threshold, is-docs-only, handle-unfixable all use `os.Exit`). When m36.1 or a later milestone adds similar CLI smoke tests, these helpers will be duplicated or will need extraction to a shared `cmd/tekhton/testhelpers_test.go`. Worth extracting before there are two copies.
