<!-- milestone-meta
id: "10"
status: "todo"
-->

# m10 (V5) — Codex Streaming Events (provider.Event Emission Parity with Claude)

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1, Milestone 10 — fourth of the Codex provider arc. m07-m09 ship invocation + decoder + tool translator, but `runCodex` (m07) captures stdout into a `bytes.Buffer` first and only after the subprocess exits does m08's `decodeStream` walk the events. That means the TUI sidecar (m97 / m23) gets ZERO live feedback during a Codex run — the operator stares at a blank progress bar for minutes while the Codex agent works. m01 defined `provider.Event` with `EventTurnStart`, `EventToolCall`, `EventAssistantChunk`, `EventTurnEnd`, `EventRunEnd` for exactly this case. m10 wraps the m07 invocation with a streaming JSONL decoder that emits `provider.Event` to `req.EventChan` AS the events arrive — parity with how Claude provider streams. After m10, the TUI shows live turn counts, tool-call notifications, and final summaries from Codex runs identical to Claude's UX. |
| **Gap** | m07's `runCodex` is a blocking call: spawn, wait, return bytes. Even though Codex emits JSONL events incrementally on stdout, our code can't observe them until exit. For long-running Codex turns (minutes of agent work), that means: no TUI updates, no causal-log events, no early-bail on observed quota exhaustion, no operator visibility. The Claude provider (m01) wraps the supervisor's event channel and emits `provider.Event` per turn. m10 needs the Codex equivalent — a streaming decoder that reads stdout line-by-line as Codex writes, converts each event to `provider.Event`, and writes to `req.EventChan`. The mapping from Codex event types to `provider.EventKind` is the contract: `task_started` → `EventTurnStart`, `task_complete` → `EventTurnEnd`, `agent_message` → `EventAssistantChunk`, `McpToolCall` items → `EventToolCall`, etc. |
| **m10 fills** | (1) `internal/provider/codex/streaming.go` — `runCodexStreaming(ctx, bin, args, prompt, eventCh, timeout)` replacing the blocking `runCodex` when `eventCh != nil`. Spawns the process the same way m07 does, but pipes stdout to a `bufio.Scanner` that reads + decodes + emits events incrementally. Returns the captured raw stdout (for `RawProviderData`) AND a slice of all decoded events (for outcome derivation). (2) `internal/provider/codex/event_mapper.go` — `mapToProviderEvent(codexEvent Event) (provider.Event, bool)` translating each Codex event to the cross-provider shape. Returns `false` for Codex-internal events not surfaced to consumers (e.g., session_configured, shutdown_complete). (3) `(*Provider).RunAgent` updates to call `runCodexStreaming` when `req.EventChan != nil`, falling back to `runCodex` when the channel is nil. (4) Closing semantics: `EventRunEnd` is emitted as the last event, then `req.EventChan` is closed by the provider. (5) Tests + a fixture-driven streaming integration test. |
| **Depends on** | m07, m08 |
| **Files changed** | `internal/provider/codex/streaming.go` (~180 LOC), `internal/provider/codex/event_mapper.go` (~120 LOC), `internal/provider/codex/codex.go` (modify — switch path on EventChan presence, ~25 LOC delta), `internal/provider/codex/streaming_test.go` (~200 LOC), `internal/provider/codex/event_mapper_test.go` (~140 LOC), `internal/provider/codex/testdata/event_streams/` (reuse m08 fixtures), `VERSION` |

---

## Design

### Sequencing note

m10 depends on m08 (event type definitions) but can be implemented in
parallel with m09 (tool translator). The streaming logic is
independent of tool restriction.

### Goal 1 — Streaming subprocess wrapper

**File:** `internal/provider/codex/streaming.go`.

```go
package codex

import (
    "bufio"
    "bytes"
    "context"
    "encoding/json"
    "fmt"
    "io"
    "os/exec"
    "strings"
    "sync"
    "time"

    "github.com/geoffgodwin/tekhton/internal/provider"
)

// runCodexStreaming invokes codex like runCodex (m07) but consumes
// stdout incrementally with a goroutine that parses each line and
// emits provider.Event to eventCh as events arrive. The function
// returns when the subprocess exits and the streaming goroutine has
// drained the final partial buffer.
//
// Returns:
//   - rawStdout: the captured stdout bytes (for Result.RawProviderData)
//   - events: every decoded Codex event (for deriveOutcome)
//   - stderr: captured stderr bytes
//   - exitCode: subprocess exit code
//   - err: process-level error (binary missing, etc.); nil for exit-code-based failures
//
// Contract: eventCh receives a provider.EventRunEnd as the FINAL event
// (signaling consumers it's done), then is closed by this function.
// Callers MUST consume eventCh in a for-range loop to avoid blocking
// the streaming goroutine.
func runCodexStreaming(parent context.Context, bin string, args []string, prompt string, eventCh chan<- provider.Event, timeout time.Duration) (rawStdout []byte, events []Event, stderr []byte, exitCode int, err error) {
    ctx := parent
    if timeout > 0 {
        var cancel context.CancelFunc
        ctx, cancel = context.WithTimeout(parent, timeout)
        defer cancel()
    }

    cmd := exec.CommandContext(ctx, bin, args...)
    cmd.Stdin = strings.NewReader(prompt)

    stdoutPipe, pipeErr := cmd.StdoutPipe()
    if pipeErr != nil {
        return nil, nil, nil, -1, fmt.Errorf("stdout pipe: %w", pipeErr)
    }
    var errBuf bytes.Buffer
    cmd.Stderr = &errBuf
    cmd.WaitDelay = 5 * time.Second

    if startErr := cmd.Start(); startErr != nil {
        return nil, nil, nil, -1, fmt.Errorf("start: %w", startErr)
    }

    var (
        rawBuf      bytes.Buffer
        eventsBuf   []Event
        mu          sync.Mutex
        scanDone    = make(chan struct{})
    )

    go func() {
        defer close(scanDone)
        scanner := bufio.NewScanner(stdoutPipe)
        scanner.Buffer(make([]byte, 0, 64*1024), 256*1024)
        for scanner.Scan() {
            lineBytes := scanner.Bytes()
            // Copy the line — scanner reuses its buffer.
            line := make([]byte, len(lineBytes))
            copy(line, lineBytes)
            // Tee to rawBuf for postmortem capture.
            mu.Lock()
            rawBuf.Write(line)
            rawBuf.WriteByte('\n')
            mu.Unlock()

            // Decode + map.
            var codexEv Event
            if jsonErr := json.Unmarshal(line, &codexEv); jsonErr == nil {
                mu.Lock()
                eventsBuf = append(eventsBuf, codexEv)
                mu.Unlock()
                if provEv, ok := mapToProviderEvent(codexEv); ok && eventCh != nil {
                    select {
                    case eventCh <- provEv:
                    case <-ctx.Done():
                        return
                    }
                }
            } else {
                // Malformed JSON — record but don't emit.
                raw := json.RawMessage(line)
                mu.Lock()
                eventsBuf = append(eventsBuf, Event{
                    Msg: EventMsg{Kind: EventUnknown, Unknown: &raw, RawType: "parse_error"},
                })
                mu.Unlock()
            }
        }
    }()

    waitErr := cmd.Wait()
    <-scanDone  // Ensure the streaming goroutine finished draining.

    // Emit EventRunEnd then close the channel.
    if eventCh != nil {
        select {
        case eventCh <- provider.Event{Kind: provider.EventRunEnd, Timestamp: time.Now()}:
        default:
        }
        close(eventCh)
    }

    mu.Lock()
    rawStdout = append(rawStdout, rawBuf.Bytes()...)
    events = append(events, eventsBuf...)
    mu.Unlock()

    if waitErr != nil {
        if exitErr, ok := waitErr.(*exec.ExitError); ok {
            return rawStdout, events, errBuf.Bytes(), exitErr.ExitCode(), nil
        }
        return rawStdout, events, errBuf.Bytes(), -1, fmt.Errorf("wait: %w", waitErr)
    }
    return rawStdout, events, errBuf.Bytes(), 0, nil
}
```

### Goal 2 — Codex event → provider.Event mapper

**File:** `internal/provider/codex/event_mapper.go`.

```go
package codex

import (
    "time"

    "github.com/geoffgodwin/tekhton/internal/provider"
)

// mapToProviderEvent translates a Codex event to a provider.Event.
// Returns (event, true) if the event should be surfaced to consumers;
// (zero, false) for Codex-internal events (session lifecycle, etc.).
//
// Mapping table:
//   task_started        → EventTurnStart    (turn = TaskStarted.turn_id parsed)
//   task_complete       → EventTurnEnd      (turn = TaskComplete.turn_id parsed)
//   agent_message       → EventAssistantChunk (Content = agent text)
//   item: McpToolCall   → EventToolCall     (Content = tool name)
//   item: FileChange    → EventToolResult   (Content = "file_change")
//   token_count         → (not surfaced — telemetry only)
//   error               → EventTurnEnd      with Metadata["error"] = message
//   session_configured  → (not surfaced)
//   shutdown_complete   → (not surfaced)
//
// EventRunEnd is emitted by runCodexStreaming itself after the
// process exits, not by this mapper.
func mapToProviderEvent(ev Event) (provider.Event, bool) {
    ts := time.Now()
    switch ev.Msg.Kind {
    case EventTaskStarted:
        if ev.Msg.TaskStarted == nil {
            return provider.Event{}, false
        }
        return provider.Event{
            Kind:      provider.EventTurnStart,
            Timestamp: ts,
            Turn:      parseTurnID(ev.Msg.TaskStarted.TurnID),
        }, true
    case EventTaskComplete:
        if ev.Msg.TaskComplete == nil {
            return provider.Event{}, false
        }
        meta := map[string]string{}
        if ev.Msg.TaskComplete.DurationMS != nil {
            meta["duration_ms"] = formatInt(*ev.Msg.TaskComplete.DurationMS)
        }
        return provider.Event{
            Kind:      provider.EventTurnEnd,
            Timestamp: ts,
            Turn:      parseTurnID(ev.Msg.TaskComplete.TurnID),
            Metadata:  meta,
        }, true
    case EventAgentMessage:
        // Codex agent_message events carry incremental text. m08
        // doesn't parse the content (just types the event); m10's
        // mapper pulls the first message chunk.
        return provider.Event{
            Kind:      provider.EventAssistantChunk,
            Timestamp: ts,
            Content:   extractAgentText(ev),
        }, true
    case EventError:
        if ev.Msg.Error == nil {
            return provider.Event{Kind: provider.EventTurnEnd, Timestamp: ts}, true
        }
        return provider.Event{
            Kind:      provider.EventTurnEnd,
            Timestamp: ts,
            Content:   ev.Msg.Error.Message,
            Metadata:  map[string]string{"error": "true"},
        }, true
    case EventTokenCount, EventSessionConfigured, EventShutdownComplete, EventUnknown:
        return provider.Event{}, false
    case EventItem:
        if ev.Msg.Item == nil {
            return provider.Event{}, false
        }
        switch ev.Msg.Item.Kind {
        case ItemMcpToolCall:
            if ev.Msg.Item.McpToolCall == nil {
                return provider.Event{}, false
            }
            return provider.Event{
                Kind:      provider.EventToolCall,
                Timestamp: ts,
                Content:   ev.Msg.Item.McpToolCall.Tool,
                Metadata: map[string]string{
                    "server": ev.Msg.Item.McpToolCall.Server,
                },
            }, true
        case ItemFileChange:
            return provider.Event{
                Kind:      provider.EventToolResult,
                Timestamp: ts,
                Content:   "file_change",
            }, true
        }
    }
    return provider.Event{}, false
}
```

### Goal 3 — Switch path in RunAgent

**File:** `internal/provider/codex/codex.go`.

```go
func (p *Provider) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
    if req == nil {
        return nil, errors.New("codex provider: nil request")
    }
    args, err := buildExecArgs(req)
    if err != nil {
        return nil, fmt.Errorf("codex provider: build args: %w", err)
    }

    var (
        stdout   []byte
        events   []Event
        exitCode int
        runErr   error
    )
    if req.EventChan != nil {
        // m10 — streaming path.
        stdout, events, _, exitCode, runErr = runCodexStreaming(ctx, p.BinaryPath, args, req.Prompt, req.EventChan, req.Timeout)
    } else {
        // m07 — blocking path (callers that don't need streaming).
        stdout, _, exitCode, runErr = runCodex(ctx, p.BinaryPath, args, req.Prompt, req.Timeout)
        if runErr == nil || exitCode != 0 {
            // Decode events from captured stdout.
            events, _ = decodeStream(bytes.NewReader(stdout))
        }
    }
    if runErr != nil && exitCode == 0 {
        return nil, fmt.Errorf("codex provider: invoke: %w", runErr)
    }
    result, _ := deriveOutcome(events, exitCode)

    return &provider.Result{
        Outcome:          result.Outcome,
        TurnsUsed:        result.TurnsUsed,
        ExitCode:         exitCode,
        ErrorCategory:    result.ErrorCategory,
        ErrorSubcategory: result.ErrorSubcategory,
        ErrorMessage:     result.ErrorMessage,
        LastReportPath:   result.LastReportPath,
        NullRun:          result.NullRun,
        RawProviderData:  stdout,
    }, nil
}
```

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/provider/codex/streaming.go` | Create | `runCodexStreaming` with goroutine-based incremental decode. ~180 LOC. |
| `internal/provider/codex/event_mapper.go` | Create | `mapToProviderEvent` translation. ~120 LOC. |
| `internal/provider/codex/codex.go` | Modify | Switch path based on `req.EventChan` presence. ~25 LOC. |
| `internal/provider/codex/streaming_test.go` | Create | Tests for the streaming wrapper using stub binaries that emit JSONL incrementally. ~200 LOC. |
| `internal/provider/codex/event_mapper_test.go` | Create | Table-driven mapper tests. ~140 LOC. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] `runCodexStreaming` emits `provider.EventTurnStart` to `eventCh` when a `task_started` Codex event is decoded mid-stream (before subprocess exit). Verified by `TestRunCodexStreaming_EmitsTurnStart` using a stub binary that sleeps between events.
- [ ] `runCodexStreaming` emits `provider.EventRunEnd` as the FINAL event then closes `eventCh`. Verified by `TestRunCodexStreaming_EmitsRunEnd`.
- [ ] The streaming goroutine writes to `rawBuf` and `eventsBuf` under a mutex; concurrent access from the main goroutine after wait is safe. Verified by `-race`.
- [ ] Streaming path produces byte-identical `rawStdout` to the blocking path against the same JSONL fixture. Verified by `TestRunCodexStreaming_RawStdoutParity`.
- [ ] `mapToProviderEvent(task_started_event)` returns `{Kind: EventTurnStart, Turn: <id>}`. Verified by `TestMapToProviderEvent/task_started`.
- [ ] `mapToProviderEvent(task_complete_event)` returns `{Kind: EventTurnEnd, Turn: <id>, Metadata["duration_ms"]: <ms>}`. Verified.
- [ ] `mapToProviderEvent(agent_message_event)` returns `{Kind: EventAssistantChunk, Content: <text>}`. Verified.
- [ ] `mapToProviderEvent(McpToolCall item)` returns `{Kind: EventToolCall, Content: <tool>, Metadata["server"]: <server>}`. Verified.
- [ ] `mapToProviderEvent(session_configured_event)` returns `(_, false)` — not surfaced. Verified.
- [ ] `mapToProviderEvent(token_count_event)` returns `(_, false)`. Verified.
- [ ] `(*Provider).RunAgent` with `req.EventChan` non-nil uses streaming path; with nil uses blocking path. Verified by integration tests against both.
- [ ] A caller that closes its context mid-stream causes the streaming goroutine to exit without leaking. Verified by `-race` + a context-cancel test.
- [ ] No regression in m07 / m08 / m09 tests.
- [ ] `golangci-lint run` and `go vet` clean.
- [ ] Full suite passes.

## Watch For

- **Always emit `EventRunEnd` and ALWAYS close `eventCh`.** Consumers
  use `for ev := range eventCh { ... }` to drain. A leaked channel
  (no close) means the consumer goroutine hangs forever. The defer
  pattern in `runCodexStreaming` ensures both happen even on
  process-level errors.
- **The streaming goroutine and main goroutine share `rawBuf` and
  `eventsBuf`.** A mutex is required. Don't try to be clever with
  channels-as-locks — the wait pattern (Start → goroutine reading →
  Wait → drain `<-scanDone`) is the contract.
- **The scanner buffer must be large enough.** Codex events can be
  several KB for complex agent_message content. `256KB` is the
  configured max; if a single event exceeds this, the scanner
  errors and we lose the event. Watch for `bufio.Scanner.Err() ==
  bufio.ErrTooLong` in test runs and bump the cap if it surfaces.
- **`provider.EventChan` must not be `req.EventChan` — they're the
  same channel.** The signature is `chan<- provider.Event` from
  the streaming function's perspective. The receiver side is the
  consumer's `<-chan provider.Event`. The provider OWNS write +
  close; consumer OWNS read.
- **Don't try to surface every Codex event.** `session_configured`,
  `shutdown_complete`, `token_count` are not user-facing — they're
  telemetry. Surface them only if a future TUI iteration wants
  that detail.
- **The non-streaming path stays intact.** Callers that don't care
  about live updates (CI integrations, tests) pass `eventCh = nil`
  and get the blocking m07 behavior unchanged. Don't deprecate
  this path.

## Seeds Forward

- **m11 — Rate-limit detection.** A streaming `token_count` event
  with a low `rate_limits.remaining` can be observed mid-turn,
  enabling early bail. m11's quota policy CAN consume mid-stream
  `token_count` events directly via this milestone's seam — but
  the MVP version just uses the final event captured in
  `OutcomeResult.RateLimits`.
- **Per-stage event consumption.** When stages migrate to Codex
  (m12), they set up an event channel and drain it in a goroutine
  matching their TUI integration pattern. The cross-provider
  shape from m01 + this m10 mapping means stages don't need
  Codex-specific code.
- **Causal log integration.** A future enhancement could surface
  `provider.Event` directly into `internal/causality/` for live
  observability. Out of MVP scope; the seam is positioned.
- **Backpressure handling.** If `eventCh` consumer is slow, the
  streaming goroutine blocks on the channel send. The current
  implementation uses unbuffered semantics. A buffered channel
  (default depth 64) at the consumer site would smooth bursty
  Codex output. Document this in the provider seam doc.
