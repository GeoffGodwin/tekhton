<!-- milestone-meta
id: "08"
status: "todo"
-->

# m08 (V5) — Codex JSON Event Decoder + Item Taxonomy + Outcome Mapping

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1, Milestone 8 — second of the Codex provider arc. m07 lands the scaffolding that invokes `codex exec --json` and captures stdout as raw bytes. m08 makes those bytes meaningful: a Go-side decoder for Codex's newline-delimited JSON event envelope, the `TurnItem` taxonomy, and the `CodexErrorInfo` → `provider.Outcome` mapping. After m08, `Provider.RunAgent` returns a `*provider.Result` whose `Outcome`, `TurnsUsed`, `LastReportPath`, `NullRun`, `ErrorCategory`, and `ErrorSubcategory` fields are all populated from the actual event stream — not just the exit code. The audit established the precise wire format: top-level `{"id": ..., "msg": {"type": <snake_case_event>, ...payload}}` lines, with `task_started`, `task_complete`, `token_count`, `error`, `agent_message`, `session_configured`, `shutdown_complete` event types and a typed `CodexErrorInfo` enum for error categorization. m08 implements every piece. |
| **Gap** | At m07 close, m07's `runCodex` returns raw stdout/stderr bytes. The bytes are JSONL but nothing parses them — `Result.Outcome` is derived solely from exit code, which is coarse and loses information (e.g., `task_complete` followed by exit 0 vs `error` event with `UsageLimitExceeded` followed by exit 1 — both are exit-1 outcomes via m07's mapping but mean very different things to the pipeline). The audit's `CodexErrorInfo` enum has 15 variants with HTTP-status-code refinement on several; we need typed Go counterparts and an explicit mapping table. Beyond errors, the `task_complete` event carries `last_agent_message`, `duration_ms`, `time_to_first_token_ms` — useful telemetry the supervisor can record. The `token_count` event carries `TokenUsage` (input/cached/output/reasoning/total) AND `RateLimitSnapshot` — the latter is m11's input, but m08 captures it in a typed result field for that handoff. |
| **m08 fills** | (1) `internal/provider/codex/events.go` — Go types mirroring the Codex protocol's `Event`, `EventMsg`, `TurnStartedEvent`, `TurnCompleteEvent`, `TokenCountEvent`, `ErrorEvent`, `CodexErrorInfo`. Implements `encoding/json.Unmarshaler` on `EventMsg` to handle the tagged union (`msg.type` discriminator). (2) `internal/provider/codex/items.go` — Go types for the `TurnItem` taxonomy (UserMessage, HookPrompt, AgentMessage, Plan, Reasoning, WebSearch, ImageView, ImageGeneration, FileChange, McpToolCall, ContextCompaction). m10 will surface these via streaming events; m08 only needs the type definitions. (3) `internal/provider/codex/decoder.go` — `decodeStream(io.Reader) ([]Event, error)` that consumes the JSONL stdout from m07's `runCodex`, parses each line, and returns the event sequence. Lenient: unknown event types yield a typed `UnknownEvent` rather than failing the whole decode. (4) `internal/provider/codex/outcome.go` — `deriveOutcome(events []Event, exitCode int) (*OutcomeResult, error)` that walks the event sequence and produces the typed result fields. `OutcomeResult` carries `Outcome`, `TurnsUsed`, `LastReportPath`, `NullRun`, `ErrorCategory`, `ErrorSubcategory`, `ErrorMessage`, `TokenUsage`, `RateLimitSnapshot`. The mapping table is the contract — see Goal 4. (5) Six fixture JSONL streams under `internal/provider/codex/testdata/event_streams/` covering happy path, context window exceeded, usage limit exceeded, server overloaded, unauthorized, null run. (6) `(*Provider).RunAgent` updated to call `decodeStream` + `deriveOutcome` and populate the returned `*provider.Result`. |
| **Depends on** | m07 |
| **Files changed** | `internal/provider/codex/events.go` (~200 LOC), `internal/provider/codex/items.go` (~180 LOC), `internal/provider/codex/decoder.go` (~120 LOC), `internal/provider/codex/outcome.go` (~180 LOC), `internal/provider/codex/codex.go` (modify — wire the decoder into RunAgent, ~30 LOC delta), `internal/provider/codex/events_test.go` (~180 LOC), `internal/provider/codex/decoder_test.go` (~140 LOC), `internal/provider/codex/outcome_test.go` (~200 LOC), `internal/provider/codex/testdata/event_streams/*.jsonl` (six fixtures), `VERSION` |

---

## Design

### Sequencing note

m08 is independent at the source level (no other package depends on
its internals beyond `codex.Provider`) but is the gateway to m09 / m10
/ m11 — each of those reads parsed events. Land m08 first so the
downstream milestones have typed inputs.

### Goal 1 — Top-level event envelope + EventMsg variants

**File:** `internal/provider/codex/events.go`.

```go
package codex

import (
    "encoding/json"
    "fmt"
)

// Event mirrors the Codex protocol's top-level event envelope:
//
//   {"id": "<submission-id>", "msg": {"type": "<event_type>", ...}}
//
// V5 m08 — defined. m09-m11 consume these.
type Event struct {
    ID  string  `json:"id"`
    Msg EventMsg `json:"msg"`
}

// EventMsg is the tagged union of all event types Codex emits in
// --json mode. The Kind field is the discriminator; the typed payload
// fields are populated for matching events.
type EventMsg struct {
    Kind             EventKind
    TaskStarted      *TaskStartedEvent
    TaskComplete     *TaskCompleteEvent
    TokenCount       *TokenCountEvent
    Error            *ErrorEvent
    AgentMessage     *AgentMessageEvent
    SessionConfigured *SessionConfiguredEvent
    ShutdownComplete *ShutdownCompleteEvent
    Item             *TurnItem  // For item events.
    Unknown          *json.RawMessage  // Forward-compat for unrecognized types.
    RawType          string     // The raw msg.type string, for diagnostics.
}

// EventKind is the typed discriminator. The string mapping matches
// the Codex protocol's snake_case serde tags.
type EventKind int

const (
    EventUnknown EventKind = iota
    EventTaskStarted        // "task_started" (alias "turn_started")
    EventTaskComplete       // "task_complete" (alias "turn_complete")
    EventTokenCount         // "token_count"
    EventError              // "error"
    EventAgentMessage       // "agent_message"
    EventSessionConfigured  // "session_configured"
    EventShutdownComplete   // "shutdown_complete"
    EventItem               // any "item.*" event
)

// UnmarshalJSON implements the tagged-union decode.
func (m *EventMsg) UnmarshalJSON(data []byte) error {
    var probe struct {
        Type string `json:"type"`
    }
    if err := json.Unmarshal(data, &probe); err != nil {
        return fmt.Errorf("codex event: probe type: %w", err)
    }
    m.RawType = probe.Type
    switch probe.Type {
    case "task_started", "turn_started":
        m.Kind = EventTaskStarted
        m.TaskStarted = &TaskStartedEvent{}
        return json.Unmarshal(data, m.TaskStarted)
    case "task_complete", "turn_complete":
        m.Kind = EventTaskComplete
        m.TaskComplete = &TaskCompleteEvent{}
        return json.Unmarshal(data, m.TaskComplete)
    case "token_count":
        m.Kind = EventTokenCount
        m.TokenCount = &TokenCountEvent{}
        return json.Unmarshal(data, m.TokenCount)
    case "error":
        m.Kind = EventError
        m.Error = &ErrorEvent{}
        return json.Unmarshal(data, m.Error)
    // ... agent_message, session_configured, shutdown_complete, item.*
    default:
        m.Kind = EventUnknown
        raw := json.RawMessage(data)
        m.Unknown = &raw
    }
    return nil
}

type TaskStartedEvent struct {
    TurnID              string `json:"turn_id"`
    TraceID             string `json:"trace_id,omitempty"`
    StartedAt           *int64 `json:"started_at,omitempty"`
    ModelContextWindow  *int64 `json:"model_context_window,omitempty"`
    CollaborationMode   string `json:"collaboration_mode_kind,omitempty"`
}

type TaskCompleteEvent struct {
    TurnID              string `json:"turn_id"`
    LastAgentMessage    string `json:"last_agent_message,omitempty"`
    CompletedAt         *int64 `json:"completed_at,omitempty"`
    DurationMS          *int64 `json:"duration_ms,omitempty"`
    TimeToFirstTokenMS  *int64 `json:"time_to_first_token_ms,omitempty"`
}

type TokenCountEvent struct {
    Info       *TokenUsageInfo    `json:"info,omitempty"`
    RateLimits *RateLimitSnapshot `json:"rate_limits,omitempty"`
}

type TokenUsageInfo struct {
    InputTokens           int64 `json:"input_tokens"`
    CachedInputTokens     int64 `json:"cached_input_tokens"`
    OutputTokens          int64 `json:"output_tokens"`
    ReasoningOutputTokens int64 `json:"reasoning_output_tokens"`
    TotalTokens           int64 `json:"total_tokens"`
}

type RateLimitSnapshot struct {
    // Field set per Codex protocol's RateLimitSnapshot — captured here
    // as raw JSON for m11 to interpret. Avoids m08 needing to know
    // the exact rate-limit window schema; m11 owns that.
    Raw json.RawMessage `json:"-"`
}

type ErrorEvent struct {
    Message        string                  `json:"message"`
    CodexErrorInfo *CodexErrorInfo         `json:"codex_error_info,omitempty"`
}

type CodexErrorInfo struct {
    Kind     CodexErrorKind
    HTTPCode int  // populated for kinds that carry status codes
}

type CodexErrorKind int

const (
    ErrorKindUnknown CodexErrorKind = iota
    ErrorKindContextWindowExceeded
    ErrorKindUsageLimitExceeded
    ErrorKindServerOverloaded
    ErrorKindCyberPolicy
    ErrorKindHTTPConnectionFailed
    ErrorKindResponseStreamConnectionFailed
    ErrorKindInternalServerError
    ErrorKindUnauthorized
    ErrorKindBadRequest
    ErrorKindSandboxError
    ErrorKindResponseStreamDisconnected
    ErrorKindResponseTooManyFailedAttempts
    ErrorKindActiveTurnNotSteerable
    ErrorKindThreadRollbackFailed
    ErrorKindOther
)

// UnmarshalJSON handles CodexErrorInfo's two shapes: a bare string
// variant ("context_window_exceeded") and an object variant with
// embedded fields ({"http_connection_failed": {"http_status_code": 503}}).
func (c *CodexErrorInfo) UnmarshalJSON(data []byte) error {
    // ... two-mode decoder per Codex protocol's serde enum shape
}
```

### Goal 2 — Item taxonomy

**File:** `internal/provider/codex/items.go`.

Mirrors the `TurnItem` enum from the Codex protocol's
`turn_item.rs`. Each variant becomes a typed Go struct; the dispatch
parallels EventMsg's UnmarshalJSON pattern.

```go
type TurnItem struct {
    Kind ItemKind
    UserMessage      *UserMessageItem
    HookPrompt       *HookPromptItem
    AgentMessage     *AgentMessageItem
    Plan             *PlanItem
    Reasoning        *ReasoningItem
    WebSearch        *WebSearchItem
    ImageView        *ImageViewItem
    ImageGeneration  *ImageGenerationItem
    FileChange       *FileChangeItem
    McpToolCall      *McpToolCallItem
    ContextCompaction *ContextCompactionItem
}

type ItemKind int

const (
    ItemUnknown ItemKind = iota
    ItemUserMessage
    ItemHookPrompt
    ItemAgentMessage
    ItemPlan
    ItemReasoning
    ItemWebSearch
    ItemImageView
    ItemImageGeneration
    ItemFileChange
    ItemMcpToolCall
    ItemContextCompaction
)

// Per-item struct definitions follow protocol exactly — fields match
// the Rust source one-for-one (id, content arrays, optional phase,
// etc.). See internal/provider/codex/items.go for the full set.
```

### Goal 3 — JSONL decoder

**File:** `internal/provider/codex/decoder.go`.

```go
package codex

import (
    "bufio"
    "bytes"
    "encoding/json"
    "fmt"
    "io"
)

// decodeStream consumes the JSONL stdout from runCodex and returns the
// event sequence. Lenient: malformed lines yield a typed
// UnknownEvent rather than aborting the decode; the caller decides
// whether to fail.
//
// Reads line by line so the byte buffer is bounded by the largest
// single event (typically <64KB; we configure 256KB max line size to
// be safe).
func decodeStream(r io.Reader) ([]Event, error) {
    scanner := bufio.NewScanner(r)
    scanner.Buffer(make([]byte, 0, 64*1024), 256*1024)

    var events []Event
    lineNo := 0
    for scanner.Scan() {
        lineNo++
        line := bytes.TrimSpace(scanner.Bytes())
        if len(line) == 0 {
            continue
        }
        var ev Event
        if err := json.Unmarshal(line, &ev); err != nil {
            // Fail-soft: record a synthetic Unknown event so the caller
            // can surface the parse error without losing prior events.
            raw := json.RawMessage(line)
            ev = Event{
                Msg: EventMsg{Kind: EventUnknown, Unknown: &raw, RawType: fmt.Sprintf("parse_error_line_%d", lineNo)},
            }
        }
        events = append(events, ev)
    }
    if err := scanner.Err(); err != nil {
        return events, fmt.Errorf("codex decoder: scan: %w", err)
    }
    return events, nil
}
```

### Goal 4 — Outcome derivation (the mapping table)

**File:** `internal/provider/codex/outcome.go`.

The mapping from event sequence + exit code to `provider.Outcome` is
m08's contract. Implementers reference this table exactly.

```go
package codex

import "github.com/geoffgodwin/tekhton/internal/provider"

type OutcomeResult struct {
    Outcome           provider.Outcome
    TurnsUsed         int
    LastReportPath    string  // From task_complete.last_agent_message OR --output-last-message path
    NullRun           bool
    ErrorCategory     string  // "UPSTREAM" | "ENVIRONMENT" | ""
    ErrorSubcategory  string  // CodexErrorKind name
    ErrorMessage      string
    TokenUsage        *TokenUsageInfo
    RateLimits        *RateLimitSnapshot
}

// deriveOutcome walks the event sequence and produces a typed outcome.
// The mapping table:
//
//  Event sequence pattern                    → Outcome / ErrorCategory
//  --------------------------------------------- -----------------------------
//  task_started, ..., task_complete          → OutcomeSuccess
//  no task_started seen                       → OutcomeNullRun
//  error{ContextWindowExceeded}               → OutcomeUnknown / "CONTEXT_OVERFLOW"
//  error{UsageLimitExceeded}                  → OutcomeUpstreamError / "QUOTA"
//  error{ServerOverloaded}                    → OutcomeUpstreamError / "OVERLOADED"
//  error{HTTPConnectionFailed}                → OutcomeUpstreamError / "NETWORK"
//  error{ResponseStreamConnectionFailed}      → OutcomeUpstreamError / "STREAM"
//  error{ResponseStreamDisconnected}          → OutcomeUpstreamError / "STREAM"
//  error{InternalServerError}                 → OutcomeUpstreamError / "SERVER_5XX"
//  error{ResponseTooManyFailedAttempts}       → OutcomeUpstreamError / "RETRY_EXHAUSTED"
//  error{Unauthorized}                        → OutcomeUpstreamError / "AUTH"
//  error{BadRequest}                          → OutcomeUpstreamError / "BAD_REQUEST"
//  error{CyberPolicy}                         → OutcomeAborted / "POLICY"
//  error{SandboxError}                        → OutcomeAborted / "SANDBOX"
//  error{ActiveTurnNotSteerable}              → OutcomeAborted / "STEER_CONFLICT"
//  error{ThreadRollbackFailed}                → OutcomeUnknown / "ROLLBACK_FAILED"
//  error{Other}                               → OutcomeUnknown / "OTHER"
//  (no event sequence, exit code 124)         → OutcomeTimeout
//  (no event sequence, exit code 137|143)     → OutcomeAborted
func deriveOutcome(events []Event, exitCode int) (*OutcomeResult, error) {
    out := &OutcomeResult{}

    var (
        sawStart      bool
        sawComplete   bool
        lastError     *ErrorEvent
        turns         int
        lastTaskComplete *TaskCompleteEvent
        lastTokenCount   *TokenCountEvent
    )

    for _, ev := range events {
        switch ev.Msg.Kind {
        case EventTaskStarted:
            sawStart = true
            turns++
        case EventTaskComplete:
            sawComplete = true
            lastTaskComplete = ev.Msg.TaskComplete
        case EventTokenCount:
            lastTokenCount = ev.Msg.TokenCount
        case EventError:
            lastError = ev.Msg.Error
        }
    }

    if lastTokenCount != nil {
        out.TokenUsage = lastTokenCount.Info
        out.RateLimits = lastTokenCount.RateLimits
    }
    if lastTaskComplete != nil {
        out.LastReportPath = lastTaskComplete.LastAgentMessage
    }
    out.TurnsUsed = turns

    // Error categorization takes precedence over success.
    if lastError != nil {
        out.ErrorMessage = lastError.Message
        // Apply the mapping table — see implementation.
        applyErrorMapping(out, lastError)
        return out, nil
    }

    if !sawStart {
        // No event sequence — fall through to exit-code interpretation
        // for the null-run / timeout / abort cases.
        out.NullRun = true
        out.Outcome = interpretExitCode(exitCode)
        return out, nil
    }
    if sawComplete {
        out.Outcome = provider.OutcomeSuccess
        return out, nil
    }
    // Started but never completed — treat as unknown.
    out.Outcome = provider.OutcomeUnknown
    return out, nil
}

// applyErrorMapping walks the table above and populates out.Outcome,
// ErrorCategory, ErrorSubcategory based on lastError.CodexErrorInfo.
func applyErrorMapping(out *OutcomeResult, err *ErrorEvent) {
    if err.CodexErrorInfo == nil {
        out.Outcome = provider.OutcomeUpstreamError
        out.ErrorCategory = "UPSTREAM"
        out.ErrorSubcategory = "UNTYPED"
        return
    }
    switch err.CodexErrorInfo.Kind {
    case ErrorKindContextWindowExceeded:
        out.Outcome = provider.OutcomeUnknown
        out.ErrorCategory = "UPSTREAM"
        out.ErrorSubcategory = "CONTEXT_OVERFLOW"
    case ErrorKindUsageLimitExceeded:
        out.Outcome = provider.OutcomeUpstreamError
        out.ErrorCategory = "UPSTREAM"
        out.ErrorSubcategory = "QUOTA"
    // ... full table per the doc comment above
    }
}
```

### Goal 5 — Fixture event streams

**Directory:** `internal/provider/codex/testdata/event_streams/`.

Six recorded JSONL streams:
- `happy_path.jsonl` — task_started + agent_message + token_count + task_complete + shutdown_complete
- `context_window_exceeded.jsonl` — task_started + agent_message + error{ContextWindowExceeded}
- `usage_limit_exceeded.jsonl` — task_started + error{UsageLimitExceeded} mid-turn
- `server_overloaded.jsonl` — task_started + error{ServerOverloaded}
- `unauthorized.jsonl` — error{Unauthorized} immediately (no task_started)
- `null_run.jsonl` — empty file (Codex exited without emitting events; e.g., immediate auth failure)

Each fixture is committed as the wire-format contract. `outcome_test.go`
runs `decodeStream` + `deriveOutcome` against each and asserts the
expected `OutcomeResult` fields.

### Goal 6 — Wire decoder into RunAgent

**File:** `internal/provider/codex/codex.go` (m07 file, modify).

```go
func (p *Provider) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
    // ... existing m07 setup
    stdout, stderr, exitCode, runErr := runCodex(ctx, p.BinaryPath, args, req.Prompt, req.Timeout)
    if runErr != nil && exitCode == 0 {
        return nil, fmt.Errorf("codex provider: invoke: %w", runErr)
    }

    // m08 — decode the JSONL stream and derive outcome.
    events, decodeErr := decodeStream(bytes.NewReader(stdout))
    if decodeErr != nil {
        // Decode error is non-fatal — log it and fall through to
        // exit-code-based outcome. Prevents a single malformed event
        // line from aborting an otherwise successful run.
        log.Printf("codex provider: decode warning: %v", decodeErr)
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
        RawProviderData:  stdout,  // Capture raw events for postmortem.
    }, nil
}
```

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/provider/codex/events.go` | Create | Top-level Event + EventMsg + per-event structs + tagged-union unmarshaler. ~200 LOC. |
| `internal/provider/codex/items.go` | Create | TurnItem taxonomy with all 11 variants. ~180 LOC. |
| `internal/provider/codex/decoder.go` | Create | `decodeStream(io.Reader) []Event` lenient parser. ~120 LOC. |
| `internal/provider/codex/outcome.go` | Create | `deriveOutcome` + mapping table + `applyErrorMapping`. ~180 LOC. |
| `internal/provider/codex/codex.go` | Modify | Wire `decodeStream` + `deriveOutcome` into `RunAgent`. |
| `internal/provider/codex/events_test.go` | Create | Unmarshaler tests per event type. ~180 LOC. |
| `internal/provider/codex/decoder_test.go` | Create | Stream decode tests including lenient unknown-event handling. ~140 LOC. |
| `internal/provider/codex/outcome_test.go` | Create | Full table-driven outcome derivation per fixture. ~200 LOC. |
| `internal/provider/codex/testdata/event_streams/*.jsonl` | Create | Six fixtures. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] `internal/provider/codex/events.go` exports `Event`, `EventMsg`, `EventKind`, `TaskStartedEvent`, `TaskCompleteEvent`, `TokenCountEvent`, `TokenUsageInfo`, `RateLimitSnapshot`, `ErrorEvent`, `CodexErrorInfo`, `CodexErrorKind`. Verified by `go doc`.
- [ ] `EventMsg.UnmarshalJSON` correctly populates the typed payload field for `task_started`, `task_complete`, `token_count`, `error`, `agent_message`, `session_configured`, `shutdown_complete`. Verified by table-driven `TestEventMsg_Unmarshal`.
- [ ] `EventMsg.UnmarshalJSON` accepts both `task_started` and `turn_started` (and the equivalent for `task_complete`/`turn_complete`) — the protocol's alias pair. Verified by alias rows in the table.
- [ ] Unknown event types decode to `EventKind == EventUnknown` with the raw bytes preserved in `Unknown`. Verified by `TestEventMsg_Unmarshal/unknown_type`.
- [ ] `CodexErrorInfo.UnmarshalJSON` handles both the bare-string variant (`"context_window_exceeded"`) and the object variant (`{"http_connection_failed":{"http_status_code":503}}`). Verified by `TestCodexErrorInfo_Unmarshal`.
- [ ] `decodeStream` against `testdata/event_streams/happy_path.jsonl` returns ≥5 events including a `task_started`, a `task_complete`, and a `token_count`. Verified by `TestDecodeStream_HappyPath`.
- [ ] `decodeStream` against an empty file returns an empty slice and a nil error. Verified by `TestDecodeStream_Empty`.
- [ ] `decodeStream` against a file with a malformed JSON line returns the malformed line as `EventUnknown` with `RawType` starting `parse_error_line_`. Verified by `TestDecodeStream_MalformedLine`.
- [ ] `deriveOutcome(happy_path_events, 0)` returns `{Outcome: OutcomeSuccess, TurnsUsed: 1, NullRun: false, ErrorCategory: ""}` and a non-nil `TokenUsage`. Verified by `TestDeriveOutcome/happy_path`.
- [ ] `deriveOutcome(usage_limit_events, 1)` returns `{Outcome: OutcomeUpstreamError, ErrorCategory: "UPSTREAM", ErrorSubcategory: "QUOTA"}`. Verified by `TestDeriveOutcome/usage_limit`.
- [ ] `deriveOutcome(context_window_events, 1)` returns `{ErrorSubcategory: "CONTEXT_OVERFLOW"}`. Verified.
- [ ] `deriveOutcome(unauthorized_events, 1)` returns `{ErrorSubcategory: "AUTH"}`. Verified.
- [ ] `deriveOutcome(null_run_events, 1)` returns `{Outcome: OutcomeNullRun, NullRun: true}`. Verified.
- [ ] `deriveOutcome` populates `TokenUsage` and `RateLimits` when a `token_count` event was in the stream. Verified.
- [ ] `(*Provider).RunAgent` against a stub binary that emits the happy_path fixture returns `*provider.Result` with the m08-populated fields (`TurnsUsed > 0`, `LastReportPath` non-empty). Verified by an integration test using a stub binary.
- [ ] No regression in m07's tests (`flags_test.go`, `exec_test.go`, `codex_test.go`).
- [ ] `golangci-lint run ./internal/provider/codex/...` and `go vet` clean.
- [ ] Full suite passes.

## Watch For

- **The alias pair is real.** The Codex protocol carries BOTH
  `task_started` and `turn_started` as serde aliases for the same
  variant. Different CLI versions emit one or the other. Both must
  decode correctly. Same for `task_complete`/`turn_complete`.
- **`CodexErrorInfo` has two serde shapes.** Variants without inline
  data serialize as bare strings (`"context_window_exceeded"`);
  variants with inline data (HTTP status codes) serialize as
  `{"http_connection_failed":{"http_status_code":503}}`. The
  Unmarshaler MUST handle both shapes — start by trying the bare
  string, fall through to the object form.
- **The mapping table is the contract.** Every CodexErrorKind has a
  designated `OutcomeResult.ErrorSubcategory` string. Tekhton's
  pipeline state machine routes on these. Adding a new
  Subcategory string after m08 ships means a coordinated update
  with the recovery logic — do it deliberately, not casually.
- **`OutcomeNullRun` is for "no events at all".** The Codex CLI
  exiting after a `task_started` but BEFORE a `task_complete` is
  NOT a null run — it's an interrupted run, mapped to
  `OutcomeUnknown`. Don't conflate the two; the recovery policy
  differs.
- **Lenient decoding is intentional.** A single malformed event
  shouldn't lose the events that came before. The synthetic
  `parse_error_line_N` UnknownEvent gives the caller visibility
  without aborting the decode. Don't replace this with a strict
  error-out behavior.
- **`RawProviderData` carries the original bytes.** Postmortem
  debugging benefits from the unmodified stdout. Don't try to
  re-marshal events into `RawProviderData` — that loses byte
  identity. Store the raw stdout slice.
- **Don't process `agent_message` content for tool calls in m08.**
  m10 owns streaming event emission and tool-call extraction. m08
  just types `AgentMessage`; it doesn't act on its content beyond
  counting turn boundaries.

## Seeds Forward

- **m09 — Tool schema.** Consumes `TurnItem.McpToolCall` and
  `FileChange` to round-trip tool invocations. m08's typed Item
  struct is the input.
- **m10 — Streaming events.** Re-uses `decodeStream` but emits
  `provider.Event` per decoded Codex event as they arrive (rather
  than collecting then deriving). m08's lenient decode logic
  applies unchanged.
- **m11 — Rate limits.** `OutcomeResult.RateLimits` carries the raw
  RateLimitSnapshot. m11 interprets the snapshot's window/remaining
  fields to drive retry timing.
- **Codex protocol evolution.** Adding new `CodexErrorKind`
  variants downstream is just an enum value + a mapping table entry.
  The lenient decoder treats unknowns as `ErrorKindUnknown` with
  `OutcomeUpstreamError / "OTHER"` fallback — no Codex update
  bricks the pipeline.
- **Telemetry surfacing.** `TokenUsageInfo` is a clean signal for
  cost tracking. A future arc can stamp it into the causal log per
  run for cost analysis dashboards. Out of m08 scope; the typed
  field is positioned for it.
