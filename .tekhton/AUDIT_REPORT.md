## Test Audit Report

### Audit Summary
Tests audited: 5 files, 46 test functions
Verdict: PASS

### Findings

#### COVERAGE: DefaultRetryPolicy subcategory strings not cross-referenced against outcome.go
- File: internal/provider/codex/retry_test.go:22
- Issue: `TestDefaultRetryPolicy_RetryableSet` verifies the `RetryableSubcategories` map
  contains `"OVERLOADED"` and `"SERVER_5XX"` as retryable keys. However,
  `outcome.go:mapErrorToOutcome` (line 83-97) produces `"OVERLOAD"` (not `"OVERLOADED"`)
  for `ErrorKindServerOverloaded` and `"SERVER_ERROR"` (not `"SERVER_5XX"`) for
  `ErrorKindInternalServerError`. At runtime, these subcategories will never match
  their entries in `DefaultRetryPolicy().RetryableSubcategories`, so overloaded-server
  and 5xx errors are silently never retried despite the policy declaring them retryable.
  The integration tests (`TestRunAgentWithRetry_*`) only exercise the QUOTA and AUTH
  paths through real subprocesses; no test drives an OVERLOADED or SERVER_5XX error
  end-to-end, so the string mismatch goes undetected by the suite.
- Severity: MEDIUM
- Action: Add an integration test that emits `codex_error_info: "server_overloaded"` via
  a stub and asserts that `RunAgentWithRetry` retries (counter file shows >1 invocation).
  This will expose the `"OVERLOAD"` vs `"OVERLOADED"` mismatch and force alignment of
  either the policy key or the outcome mapper string. Similarly cover `"internal_server_error"`.
  Do not change the test to match the wrong string — fix the root cause (either
  `DefaultRetryPolicy` keys or `mapErrorToOutcome` return values).

#### COVERAGE: EventRunEnd buffer-full test makes no enforceable assertion
- File: internal/provider/codex/streaming_test.go:300
- Issue: `TestRunCodexStreaming_EventRunEnd_DroppedWhenBufferFull` uses `t.Logf` in
  both code paths (EventRunEnd present and EventRunEnd absent), so the test never
  calls `t.Error` or `t.Fatal` regardless of outcome. The test verifies that
  `runCodexStreaming` returns without error on a full buffer (the only real assertion)
  but makes no enforceable claim about whether EventRunEnd is dropped or delivered —
  the described behavior is documented but not enforced.
- Severity: LOW
- Action: If the intent is to document acceptable non-determinism (either outcome is
  fine), the test is functioning as designed; a comment clarifying this would help
  future readers. If the intent is to assert the drop behavior specifically, replace
  the second `t.Logf` with `t.Errorf` so a future change that starts delivering
  EventRunEnd consistently would be caught. Either way, add a brief comment explaining
  the non-asserting structure is deliberate.

#### None — no findings in auth_test.go
- File: internal/provider/codex/auth_test.go
- Issue: All five tests exercise `resolveAuth` directly with controlled env and temp
  files. Assertions match implementation precedence rules (explicit key → OAuth file →
  env var → error). Isolation is correct (t.Setenv + t.TempDir). No issues found.
- Severity: N/A
- Action: None.

#### None — no findings in ratelimit_test.go
- File: internal/provider/codex/ratelimit_test.go
- Issue: Computed expected values (700 remaining, 50 from fixture) are derived from
  the fixture data and implementation arithmetic, not hard-coded arbitrarily.
  Fixture file `testdata/ratelimit_snapshots/low_remaining.json` exists and contains
  the expected structure. Nil/empty/invalid JSON edge cases are all covered.
- Severity: N/A
- Action: None.

#### None — no findings in event_mapper_test.go
- File: internal/provider/codex/event_mapper_test.go
- Issue: Covers all event kinds (task_started, task_complete, agent_message,
  mcp_tool_call, file_change, error, session_configured, token_count,
  shutdown_complete, unknown, out-of-range), nil-payload variants for each mappable
  type, Timestamp non-zero, and Content/Metadata field correctness for surfaced events.
  Assertions align with `mapToProviderEvent` implementation.
- Severity: N/A
- Action: None.
