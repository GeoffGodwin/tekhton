## Planned Tests
- [x] `internal/supervisor/errors_test.go` — add TestClassifyResult_FallsBackOnTransientErrorOutcome covering the OutcomeTransientError fallback branch (m07 gap, already done)
- [x] `internal/supervisor/retry_test.go` — TestShouldQuotaPause_AllPaths (nil arg path); TestRetry_QuotaExhausted_TriggersPause (ErrQuotaExhausted pause trigger); TestRetryLoop_OutcomeTransientError_UsesAeSubcatForDelay (subcat fallback branch)
- [x] `cmd/tekhton/quota_test.go` — TestQuotaStatusCmd_MissingFileReturnsActive (os.IsNotExist path); TestQuotaStatus_Human_PausedWithNoReason (Human() paused + empty reason)

## Test Run Results
Passed: 6  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/supervisor/errors_test.go`
- [x] `internal/supervisor/retry_test.go`
- [x] `cmd/tekhton/quota_test.go`
