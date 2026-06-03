# Reviewer Report — m35.2 Security Stage Port

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `internal/stages/security/run.go:290-298` — `humanActionFile()` reads `HUMAN_ACTION_FILE` and `TEKHTON_DIR` directly from `os.Getenv` at call time rather than from the `cfg` snapshot assembled in `loadConfig`. This breaks the snapshot-at-entry pattern: every other env var is resolved once at stage entry. The function should be inlined into `loadConfig` and stored on the `config` struct as `HumanActionFile`. Low risk in practice (env doesn't change mid-stage), but it is an inconsistency worth closing before more env vars drift the same way.
- `internal/stages/security/run_test.go:627` — `var _ = time.Time{}` is redundant: `time.Date` is already used at line 489. Remove the sentinel.
- `internal/stages/security/run.go:195-202` — `DurationSec` is left at zero in all `StageResultV1` returns (pass, fail, skip, block). The bash stage emitted duration via `emit_stage_envelope`. The metrics dashboard will show 0 for security stage wall-clock time. Consistent with the docs (m34.1) and cleanup (m34.2) pattern, so this is a pre-existing gap in the Go-native stage ports rather than a new regression, but worth tracking.
- `cmd/tekhton/security_test.go:22-44` — `buildTekhtonBinary` is duplicated here; the coder already flagged this in Observed Issues. Extraction to a shared `testhelpers_test.go` should be done the next time any `cmd/tekhton/*_test.go` file needs the helper.

## Coverage Gaps
- `internal/stages/security/` package coverage is 78.6%, below the 80% line target. Uncovered lines are concentrated in `writePromptTmpFile` error paths (CreateTemp/WriteString/Close failures), the `resolveTekhtonBin` binary-resolution fallback chain (TEKHTON_HOME/bin path, LookPath path), and `writeHaltState` state-write error paths. The tester should add scenarios for: (a) a `CreateTemp` failure causing `invokeScanAgent` to return an error, (b) `resolveTekhtonBin` succeeding via `TEKHTON_HOME/bin/tekhton` and via `exec.LookPath`, and (c) `writeHaltState` called with a path that causes `store.Update` to fail.

## ACP Verdicts
No Architecture Change Proposals in the coder summary.

## Drift Observations
- `tekhton-legacy.sh:2585` — `run_stage_security` is called in the legacy bash pipeline dispatch block, but the function no longer exists (source line removed, `stages/security.sh` deleted). This is dead code in the normal V4 flow (the Go `internal/pipeline.Runner` routes security through `GoImpl`), but if the legacy bash dispatch path were ever reached for security it would fail with `command not found`. The same dead-code pattern exists for docs (m34.1) and cleanup (m34.2). Recommend removing all three legacy case blocks when the orchestrate loop completes its Go migration.
