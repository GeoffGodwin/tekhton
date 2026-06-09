## Test Audit Report

### Audit Summary
Tests audited: 2 files, 25 test functions
(`internal/provider/codex/streaming_test.go`: 9 functions,
`internal/provider/codex/event_mapper_test.go`: 16 functions)
Verdict: PASS

### Findings

#### COVERAGE: nil TaskComplete payload path not tested
- File: internal/provider/codex/event_mapper_test.go (no line — missing test)
- Issue: `event_mapper.go:43-45` has an explicit nil guard for `TaskComplete`:
  `if ev.Msg.TaskComplete == nil { return provider.Event{}, false }`. Analogous
  nil-payload tests exist for `TaskStarted` (line 134) and `McpToolCall` (line 202)
  but `TaskComplete` with a nil payload has no test. A future refactor that removes
  the guard would not be caught.
- Severity: LOW
- Action: Add `TestMapToProviderEvent_TaskComplete_NilPayload` mirroring the
  `TaskStarted_NilPayload` pattern.

#### COVERAGE: EventAssistantChunk Content not verified in MultipleEvents test
- File: internal/provider/codex/streaming_test.go:249-284
- Issue: `TestRunCodexStreaming_MultipleEvents` asserts the correct sequence of
  `provider.EventKind` values but does not check the `Content` field of the
  `EventAssistantChunk` event (expected "hello" from the agent_message stub line).
  The Kind-only check would pass even if `extractAgentText` were broken and returned
  empty content.
- Severity: LOW
- Action: Add `if got[1].Content != "hello" { t.Errorf(...) }` after the Kind loop.

#### COVERAGE: EventRunEnd drop on full channel not tested
- File: internal/provider/codex/streaming.go:117-123 (impl); streaming_test.go (missing test)
- Issue: The implementation emits `EventRunEnd` via `select { case ch<-ev: default: }`.
  If the channel buffer is full, `EventRunEnd` is silently dropped, violating the
  contract documented in the godoc ("eventCh receives EventRunEnd as the FINAL event").
  All test channels have generous buffers (16–64 items) and never approach capacity,
  so no test exercises this path. `TestRunCodexStreaming_EmitsRunEnd` would not catch a
  regression in the drop behavior.
- Severity: LOW
- Action: Either document the drop-on-full behavior explicitly (if intentional), or
  change to a blocking send (remove `default:`) and add a test confirming EventRunEnd
  is always delivered even with a 1-item channel.

---

## Planned Tests
- [x] `internal/provider/codex/streaming_test.go` — TestRunCodexStreaming_EmitsTurnStart: streaming goroutine emits EventTurnStart before subprocess exits
- [x] `internal/provider/codex/streaming_test.go` — TestRunCodexStreaming_EmitsRunEnd: EventRunEnd is the last event and channel is closed afterward
- [x] `internal/provider/codex/streaming_test.go` — TestRunCodexStreaming_RawStdoutParity: streaming path captures same raw bytes as blocking path
- [x] `internal/provider/codex/streaming_test.go` — TestRunCodexStreaming_ContextCancel: context cancellation stops streaming goroutine without leak
- [x] `internal/provider/codex/streaming_test.go` — TestRunCodexStreaming_NilChannel: works correctly when eventCh is nil (no panic, captures events)
- [x] `internal/provider/codex/streaming_test.go` — TestRunCodexStreaming_MalformedJSON: malformed JSONL lines don't crash; recorded as unknown events
- [x] `internal/provider/codex/streaming_test.go` — TestRunCodexStreaming_MultipleEvents: multiple event types decoded and emitted in order
- [x] `internal/provider/codex/event_mapper_test.go` — TestMapToProviderEvent/task_started: returns EventTurnStart with correct Turn field
- [x] `internal/provider/codex/event_mapper_test.go` — TestMapToProviderEvent/task_complete: returns EventTurnEnd with Turn and duration_ms metadata
- [x] `internal/provider/codex/event_mapper_test.go` — TestMapToProviderEvent/agent_message: returns EventAssistantChunk with Content
- [x] `internal/provider/codex/event_mapper_test.go` — TestMapToProviderEvent/mcp_tool_call_item: returns EventToolCall with tool name and server metadata
- [x] `internal/provider/codex/event_mapper_test.go` — TestMapToProviderEvent/file_change_item: returns EventToolResult with "file_change" Content
- [x] `internal/provider/codex/event_mapper_test.go` — TestMapToProviderEvent/session_configured: returns (_, false) — not surfaced
- [x] `internal/provider/codex/event_mapper_test.go` — TestMapToProviderEvent/token_count: returns (_, false) — not surfaced
- [x] `internal/provider/codex/event_mapper_test.go` — TestMapToProviderEvent/error_event: returns EventTurnEnd with error metadata
- [x] `internal/provider/codex/event_mapper_test.go` — TestMapToProviderEvent/unknown_kind: returns (_, false)
- [x] `internal/provider/codex/streaming_test.go` — TestRunAgent_StreamingPathUsed: RunAgent with non-nil EventChan drains events including EventRunEnd
- [x] `internal/provider/codex/streaming_test.go` — TestRunAgent_BlockingPathFallback: RunAgent with nil EventChan uses blocking path, still returns valid Result

## Test Run Results
Passed: 55  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/provider/codex/streaming_test.go`
- [x] `internal/provider/codex/event_mapper_test.go`

## Timing
- Test executions: 4
- Approximate total test execution time: 35s
- Test files written: 2
