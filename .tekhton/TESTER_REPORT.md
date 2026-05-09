## Planned Tests
- [x] `internal/stagerunner/parity_test.go:TestDefaultLibHelpersParityWithLegacy` — DefaultLibHelpers matches tekhton-legacy.sh global source block in order
- [x] `internal/stagerunner/parity_test.go:TestDefaultLibHelpersFilesExist` — every file in DefaultLibHelpers exists in the live repo
- [x] `internal/stagerunner/parity_test.go:TestDefaultStageDefsHelperFilesExist` — every per-stage helper file in DefaultStageDefs exists in the live repo
- [x] `internal/stagerunner/parity_test.go:TestDefaultStageDefsHelpersMatchLegacy` — each stage's Helpers matches the per-stage lib block in tekhton-legacy.sh
- [x] `internal/stagerunner/parity_test.go:TestBashAdapterRealHelperIntegration` — BashAdapter with real common.sh + real intake_helpers.sh produces a valid envelope

## Test Run Results
Passed: 20  Failed: 1

Full suite: Shell 501 passed / 1 failed (test_wedge_audit_m10.sh — pre-existing, not caused by
this work). Go: 20 pass / 1 fail in stagerunner (TestDefaultStageDefsHelpersMatchLegacy,
intentional — catches the bug below). Python: passed.

## Bugs Found
- BUG: [internal/stagerunner/helpers.go:155] DefaultStageDefs["review"].Helpers is empty but stages/review.sh:368 calls _route_specialist_rework() which is defined in stages/review_helpers.sh; the BashAdapter will fail with exit 127 when specialist reviews are enabled and one fails

## Files Modified
- [x] `internal/stagerunner/parity_test.go`
