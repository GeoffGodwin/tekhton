# Reviewer Report

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `cmd/tekhton/state.go::applyField`: Bool parse failure silently drops the value and skips `Extra`, whereas the Int branch `break`s and falls through to `Extra`. If a caller ever passes `--field auto_advance=maybe`, the value disappears without trace; an invalid int value surfaces in `Extra` instead. The bash writer only passes `"true"` or `""` so this cannot bite production today, but the behavioral asymmetry is a latent trap for future bool fields. Consider aligning to the int pattern (`break` on `ParseBool` error so invalid values fall through to `Extra`).
- The milestone's AC text refers to `tekhton state validate` ("already exists from m03") — that subcommand does not exist; only `state read/write/update/clear` are registered. The test correctly substitutes `tekhton state read` (exit 2 on corrupt JSON). The AC text drift is benign but worth fixing in the milestone file or noting for whoever edits m40.2.

## Coverage Gaps
- None

## Drift Observations
- `internal/runner/resume_test.go:68-79` — `resumeWithEnv` helper is a test-only method defined directly on `*Runner`. Since it bypasses `validateAndDefault` in favour of calling `requestFromSnapshot` + `ApplyEnvDefaults` manually, it diverges slightly from the production `Resume()` path. A future test that relies on validation semantics (e.g. m40.2 adding `milestone_id` restoration) might silently pass through the helper while failing on the production path. Consider adding a comment noting the divergence and pointing at `TestResumeProductionPath` as the canonical production-path test.
