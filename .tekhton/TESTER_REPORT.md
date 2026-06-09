## Planned Tests
- [x] `internal/provider/codex/auth_test.go` — resolveAuth returns env override for explicit codex.api_key
- [x] `internal/provider/codex/auth_test.go` — resolveAuth returns subscription tier when OAuth file exists
- [x] `internal/provider/codex/auth_test.go` — resolveAuth returns api tier (no override) when CODEX_API_KEY env set
- [x] `internal/provider/codex/auth_test.go` — resolveAuth returns error when no auth source available
- [x] `internal/provider/codex/auth_test.go` — resolveAuth explicit key takes precedence over OAuth file
- [x] `internal/provider/codex/ratelimit_test.go` — RateLimitWindow.Remaining returns correct value
- [x] `internal/provider/codex/ratelimit_test.go` — RateLimitWindow.Remaining clamps negatives to 0
- [x] `internal/provider/codex/ratelimit_test.go` — ShouldRetryAfter returns (d>0, true) for exhausted window with future ResetAt
- [x] `internal/provider/codex/ratelimit_test.go` — ShouldRetryAfter returns (0, false) when all windows have remaining capacity
- [x] `internal/provider/codex/ratelimit_test.go` — ShouldRetryAfter returns (0, false) for nil/empty snapshot
- [x] `internal/provider/codex/ratelimit_test.go` — UnmarshalRateLimits decodes windows from fixture JSON
- [x] `internal/provider/codex/retry_test.go` — DefaultRetryPolicy QUOTA is retryable, AUTH and BAD_REQUEST are not
- [x] `internal/provider/codex/retry_test.go` — backoffWithJitter grows exponentially and stays bounded by MaxDelay
- [x] `internal/provider/codex/retry_test.go` — RunAgentWithRetry returns success on first successful attempt
- [x] `internal/provider/codex/retry_test.go` — RunAgentWithRetry retries up to MaxAttempts on retryable subcategory
- [x] `internal/provider/codex/retry_test.go` — RunAgentWithRetry does not retry non-retryable subcategories (AUTH)
- [x] `internal/provider/codex/retry_test.go` — RunAgentWithRetry honors ctx.Done() mid-backoff and returns ctx.Err()
- [x] `internal/provider/codex/streaming_test.go` — EventRunEnd dropped when channel buffer full; channel close terminates for-range
- [x] `internal/provider/codex/streaming_test.go` — EventAssistantChunk Content field verified in MultipleEvents test
- [x] `internal/provider/codex/event_mapper_test.go` — out-of-range EventKind(999) not surfaced (forward-compat branch)
- [x] `internal/provider/codex/event_mapper_test.go` — TaskComplete with nil payload returns (_, false)

## Test Run Results
Passed: 82  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/provider/codex/auth_test.go`
- [x] `internal/provider/codex/ratelimit_test.go`
- [x] `internal/provider/codex/retry_test.go`
- [x] `internal/provider/codex/streaming_test.go`
- [x] `internal/provider/codex/event_mapper_test.go`

## Timing
- Test executions: 7
- Approximate total test execution time: 45s
- Test files written: 5
