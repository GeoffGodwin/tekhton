## Planned Tests
- [x] `internal/supervisor/retry_test.go` — add TestRetryPolicy_Delay_BaseDelayZeroOverridesConfiguredFloor: verify BaseDelay<=0 short-circuits before the Floors map is consulted

## Test Run Results
Passed: 1  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/supervisor/retry_test.go`
