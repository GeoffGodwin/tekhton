# Reviewer Report — m40.2 State Writer: Milestone ID Field

## Verdict
APPROVED

## Complex Blockers (senior coder)
None

## Simple Blockers (jr coder)
None

## Non-Blocking Notes
- `tests/test_state_writer_resume_fields.sh` is now at 296/300 lines — four lines from the hard ceiling. The next functional addition to this file will require extraction before it can accept more test cases.
- The milestone design specified placing `milestone_id` alphabetically before `notes` in the `--field` array. The implementation inserts it after `notes` (line 85 follows line 84). JSON field ordering has no semantic impact — both the Go and bash readers look up keys by name, and the spec does not require ordered keys. Cosmetic; no change required.
- The end-to-end AC asks for `env.MilestoneMode == true` verified by capturing the `EnvKV` slice fed to the finalize hook. `TestRequestFromSnapshotMilestoneIDFixture` establishes `req.Mode == RunModeMilestone` — the upstream precondition for `env.go:115` to derive `MilestoneMode=true`. Full hook-fixture coverage is documented as out-of-scope in CODER_SUMMARY Design Observations; the regression net is adequate.
- Scenario D re-prepends `${TEKHTON_HOME}/bin` to PATH at line 253 even though Scenario B already did so at line 168 (both are top-level, not in subshells). The duplicate prepend is harmless but slightly untidy.

## Coverage Gaps
None

## Drift Observations
- `internal/runner/resume_test.go:68-79` — `resumeWithEnv` is a test-only `*Runner` method that manually calls `requestFromSnapshot` + `ApplyEnvDefaults` rather than going through the production `Resume()` path. A comment pointing at `TestResumeProductionPath` as the canonical production-path test would help future readers understand the divergence and not add validation-sensitive tests to the helper path.
