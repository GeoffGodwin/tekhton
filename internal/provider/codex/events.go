// Package codex — Event type definitions.
// V5 m08 — defined here; m09-m11 consume these.
package codex

import (
	"encoding/json"
	"fmt"
)

// Event mirrors the Codex protocol's top-level event envelope:
//
//	{"id": "<submission-id>", "msg": {"type": "<event_type>", ...}}
type Event struct {
	ID  string   `json:"id"`
	Msg EventMsg `json:"msg"`
}

// EventMsg is the tagged union of all event types Codex emits in
// --json mode. Kind is the discriminator; typed payload fields are
// populated for matching events.
type EventMsg struct {
	Kind              EventKind
	TaskStarted       *TaskStartedEvent
	TaskComplete      *TaskCompleteEvent
	TokenCount        *TokenCountEvent
	Error             *ErrorEvent
	AgentMessage      *AgentMessageEvent
	SessionConfigured *SessionConfiguredEvent
	ShutdownComplete  *ShutdownCompleteEvent
	Item              *TurnItem        // For item events.
	Unknown           *json.RawMessage // Forward-compat.
	RawType           string           // Raw msg.type string, for diagnostics.
}

// EventKind is the typed discriminator.
type EventKind int

const (
	EventUnknown          EventKind = iota
	EventTaskStarted                // "task_started" / "turn_started"
	EventTaskComplete               // "task_complete" / "turn_complete"
	EventTokenCount                 // "token_count"
	EventError                      // "error"
	EventAgentMessage               // "agent_message"
	EventSessionConfigured          // "session_configured"
	EventShutdownComplete           // "shutdown_complete"
	EventItem                       // "item" / "item.*"
)

// UnmarshalJSON implements the tagged-union decode for EventMsg.
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
	case "agent_message":
		m.Kind = EventAgentMessage
		m.AgentMessage = &AgentMessageEvent{}
		return json.Unmarshal(data, m.AgentMessage)
	case "session_configured":
		m.Kind = EventSessionConfigured
		m.SessionConfigured = &SessionConfiguredEvent{}
	case "shutdown_complete":
		m.Kind = EventShutdownComplete
		m.ShutdownComplete = &ShutdownCompleteEvent{}
	case "item":
		m.Kind = EventItem
		m.Item = &TurnItem{}
		return json.Unmarshal(data, m.Item)
	default:
		m.Kind = EventUnknown
		raw := json.RawMessage(data)
		m.Unknown = &raw
	}
	return nil
}

// TaskStartedEvent payload for "task_started" events.
type TaskStartedEvent struct {
	TurnID             string `json:"turn_id"`
	TraceID            string `json:"trace_id,omitempty"`
	StartedAt          *int64 `json:"started_at,omitempty"`
	ModelContextWindow *int64 `json:"model_context_window,omitempty"`
	CollaborationMode  string `json:"collaboration_mode_kind,omitempty"`
}

// TaskCompleteEvent payload for "task_complete" events.
type TaskCompleteEvent struct {
	TurnID             string `json:"turn_id"`
	LastAgentMessage   string `json:"last_agent_message,omitempty"`
	CompletedAt        *int64 `json:"completed_at,omitempty"`
	DurationMS         *int64 `json:"duration_ms,omitempty"`
	TimeToFirstTokenMS *int64 `json:"time_to_first_token_ms,omitempty"`
}

// TokenCountEvent payload for "token_count" events.
type TokenCountEvent struct {
	Info       *TokenUsageInfo    `json:"info,omitempty"`
	RateLimits *RateLimitSnapshot `json:"rate_limits,omitempty"`
}

// TokenUsageInfo holds per-invocation token usage telemetry.
type TokenUsageInfo struct {
	InputTokens           int64 `json:"input_tokens"`
	CachedInputTokens     int64 `json:"cached_input_tokens"`
	OutputTokens          int64 `json:"output_tokens"`
	ReasoningOutputTokens int64 `json:"reasoning_output_tokens"`
	TotalTokens           int64 `json:"total_tokens"`
}

// RateLimitSnapshot holds rate-limit window data from "token_count" events.
// Stored as raw JSON; m11 interprets the schema.
type RateLimitSnapshot struct {
	Raw json.RawMessage `json:"-"`
}

// ErrorEvent payload for "error" events.
type ErrorEvent struct {
	Message        string          `json:"message"`
	CodexErrorInfo *CodexErrorInfo `json:"codex_error_info,omitempty"`
}

// AgentMessageEvent payload for "agent_message" events.
type AgentMessageEvent struct {
	Content string `json:"content,omitempty"`
}

// SessionConfiguredEvent is a lifecycle event; no payload used.
type SessionConfiguredEvent struct{}

// ShutdownCompleteEvent is a lifecycle event; no payload used.
type ShutdownCompleteEvent struct{}

// CodexErrorInfo carries the typed error category from Codex.
type CodexErrorInfo struct {
	Kind     CodexErrorKind
	HTTPCode int // populated for kinds that carry HTTP status codes
}

// CodexErrorKind enumerates Codex error categories.
type CodexErrorKind int

const (
	ErrorKindUnknown                        CodexErrorKind = iota
	ErrorKindContextWindowExceeded                         // "context_window_exceeded"
	ErrorKindUsageLimitExceeded                            // "usage_limit_exceeded"
	ErrorKindServerOverloaded                              // "server_overloaded"
	ErrorKindCyberPolicy                                   // "cyber_policy"
	ErrorKindHTTPConnectionFailed                          // "http_connection_failed"
	ErrorKindResponseStreamConnectionFailed                // "response_stream_connection_failed"
	ErrorKindInternalServerError                           // "internal_server_error"
	ErrorKindUnauthorized                                  // "unauthorized"
	ErrorKindBadRequest                                    // "bad_request"
	ErrorKindSandboxError                                  // "sandbox_error"
	ErrorKindResponseStreamDisconnected                    // "response_stream_disconnected"
	ErrorKindResponseTooManyFailedAttempts                 // "response_too_many_failed_attempts"
	ErrorKindActiveTurnNotSteerable                        // "active_turn_not_steerable"
	ErrorKindThreadRollbackFailed                          // "thread_rollback_failed"
	ErrorKindOther                                         // catch-all
)

// UnmarshalJSON handles CodexErrorInfo's two wire shapes:
//   - bare string: "context_window_exceeded"
//   - object: {"http_connection_failed": {"http_status_code": 503}}
func (c *CodexErrorInfo) UnmarshalJSON(data []byte) error {
	// Try bare string first.
	var s string
	if err := json.Unmarshal(data, &s); err == nil {
		c.Kind = parseCodexErrorKind(s)
		return nil
	}
	// Try object shape.
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(data, &obj); err != nil {
		return fmt.Errorf("codex error info: unexpected shape: %w", err)
	}
	for k, v := range obj {
		c.Kind = parseCodexErrorKind(k)
		// Extract optional http_status_code from the nested object.
		var inner struct {
			HTTPStatus int `json:"http_status_code"`
		}
		if jsonErr := json.Unmarshal(v, &inner); jsonErr == nil {
			c.HTTPCode = inner.HTTPStatus
		}
		break // first key is the discriminator
	}
	return nil
}

func parseCodexErrorKind(s string) CodexErrorKind {
	switch s {
	case "context_window_exceeded":
		return ErrorKindContextWindowExceeded
	case "usage_limit_exceeded":
		return ErrorKindUsageLimitExceeded
	case "server_overloaded":
		return ErrorKindServerOverloaded
	case "cyber_policy":
		return ErrorKindCyberPolicy
	case "http_connection_failed":
		return ErrorKindHTTPConnectionFailed
	case "response_stream_connection_failed":
		return ErrorKindResponseStreamConnectionFailed
	case "internal_server_error":
		return ErrorKindInternalServerError
	case "unauthorized":
		return ErrorKindUnauthorized
	case "bad_request":
		return ErrorKindBadRequest
	case "sandbox_error":
		return ErrorKindSandboxError
	case "response_stream_disconnected":
		return ErrorKindResponseStreamDisconnected
	case "response_too_many_failed_attempts":
		return ErrorKindResponseTooManyFailedAttempts
	case "active_turn_not_steerable":
		return ErrorKindActiveTurnNotSteerable
	case "thread_rollback_failed":
		return ErrorKindThreadRollbackFailed
	default:
		return ErrorKindOther
	}
}
