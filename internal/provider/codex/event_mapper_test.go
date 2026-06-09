package codex

import (
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// makeTaskStartedEvent builds a task_started Event with the given turn_id.
func makeTaskStartedEvent(turnID string) Event {
	return Event{
		ID: "sub-1",
		Msg: EventMsg{
			Kind:    EventTaskStarted,
			RawType: "task_started",
			TaskStarted: &TaskStartedEvent{
				TurnID: turnID,
			},
		},
	}
}

// makeTaskCompleteEvent builds a task_complete Event.
func makeTaskCompleteEvent(turnID string, durationMS *int64) Event {
	return Event{
		ID: "sub-1",
		Msg: EventMsg{
			Kind:    EventTaskComplete,
			RawType: "task_complete",
			TaskComplete: &TaskCompleteEvent{
				TurnID:     turnID,
				DurationMS: durationMS,
			},
		},
	}
}

// makeAgentMessageEvent builds an agent_message Event.
func makeAgentMessageEvent(content string) Event {
	return Event{
		ID: "sub-1",
		Msg: EventMsg{
			Kind:    EventAgentMessage,
			RawType: "agent_message",
			AgentMessage: &AgentMessageEvent{Content: content},
		},
	}
}

// makeMcpToolCallItemEvent builds an item Event with an MCP tool call.
func makeMcpToolCallItemEvent(tool, server string) Event {
	return Event{
		ID: "sub-1",
		Msg: EventMsg{
			Kind:    EventItem,
			RawType: "item",
			Item: &TurnItem{
				Kind:        ItemMcpToolCall,
				McpToolCall: &McpToolCallItem{Tool: tool, Server: server},
			},
		},
	}
}

// makeFileChangeItemEvent builds an item Event with a file change.
func makeFileChangeItemEvent() Event {
	return Event{
		ID: "sub-1",
		Msg: EventMsg{
			Kind:    EventItem,
			RawType: "item",
			Item: &TurnItem{
				Kind:       ItemFileChange,
				FileChange: &FileChangeItem{Path: "main.go"},
			},
		},
	}
}

// makeErrorEvent builds an error Event.
func makeErrorEvent(message string, info *CodexErrorInfo) Event {
	return Event{
		ID: "sub-1",
		Msg: EventMsg{
			Kind:    EventError,
			RawType: "error",
			Error:   &ErrorEvent{Message: message, CodexErrorInfo: info},
		},
	}
}

// makeSessionConfiguredEvent builds a session_configured Event.
func makeSessionConfiguredEvent() Event {
	return Event{
		ID: "sub-1",
		Msg: EventMsg{
			Kind:              EventSessionConfigured,
			RawType:           "session_configured",
			SessionConfigured: &SessionConfiguredEvent{},
		},
	}
}

// makeTokenCountEvent builds a token_count Event.
func makeTokenCountEvent() Event {
	return Event{
		ID: "sub-1",
		Msg: EventMsg{
			Kind:    EventTokenCount,
			RawType: "token_count",
		},
	}
}

// int64Ptr is a helper to get a pointer to an int64.
func int64Ptr(v int64) *int64 { return &v }

// --- Tests ---

func TestMapToProviderEvent_TaskStarted(t *testing.T) {
	ev := makeTaskStartedEvent("3")
	got, ok := mapToProviderEvent(ev)
	if !ok {
		t.Fatal("mapToProviderEvent returned false for task_started")
	}
	if got.Kind != provider.EventTurnStart {
		t.Errorf("Kind = %v, want EventTurnStart", got.Kind)
	}
	if got.Turn != 3 {
		t.Errorf("Turn = %d, want 3", got.Turn)
	}
}

func TestMapToProviderEvent_TaskStarted_NilPayload(t *testing.T) {
	ev := Event{Msg: EventMsg{Kind: EventTaskStarted, TaskStarted: nil}}
	_, ok := mapToProviderEvent(ev)
	if ok {
		t.Error("expected false for task_started with nil payload, got true")
	}
}

func TestMapToProviderEvent_TaskComplete(t *testing.T) {
	ms := int64Ptr(1234)
	ev := makeTaskCompleteEvent("2", ms)
	got, ok := mapToProviderEvent(ev)
	if !ok {
		t.Fatal("mapToProviderEvent returned false for task_complete")
	}
	if got.Kind != provider.EventTurnEnd {
		t.Errorf("Kind = %v, want EventTurnEnd", got.Kind)
	}
	if got.Turn != 2 {
		t.Errorf("Turn = %d, want 2", got.Turn)
	}
	if got.Metadata["duration_ms"] != "1234" {
		t.Errorf("Metadata[duration_ms] = %q, want %q", got.Metadata["duration_ms"], "1234")
	}
}

func TestMapToProviderEvent_TaskComplete_NoDuration(t *testing.T) {
	ev := makeTaskCompleteEvent("1", nil)
	got, ok := mapToProviderEvent(ev)
	if !ok {
		t.Fatal("mapToProviderEvent returned false")
	}
	if _, hasDuration := got.Metadata["duration_ms"]; hasDuration {
		t.Error("duration_ms should not be set when DurationMS is nil")
	}
}

func TestMapToProviderEvent_AgentMessage(t *testing.T) {
	ev := makeAgentMessageEvent("Hello from agent")
	got, ok := mapToProviderEvent(ev)
	if !ok {
		t.Fatal("mapToProviderEvent returned false for agent_message")
	}
	if got.Kind != provider.EventAssistantChunk {
		t.Errorf("Kind = %v, want EventAssistantChunk", got.Kind)
	}
	if got.Content != "Hello from agent" {
		t.Errorf("Content = %q, want %q", got.Content, "Hello from agent")
	}
}

func TestMapToProviderEvent_McpToolCall(t *testing.T) {
	ev := makeMcpToolCallItemEvent("Read", "filesystem")
	got, ok := mapToProviderEvent(ev)
	if !ok {
		t.Fatal("mapToProviderEvent returned false for mcp_tool_call item")
	}
	if got.Kind != provider.EventToolCall {
		t.Errorf("Kind = %v, want EventToolCall", got.Kind)
	}
	if got.Content != "Read" {
		t.Errorf("Content = %q, want %q", got.Content, "Read")
	}
	if got.Metadata["server"] != "filesystem" {
		t.Errorf("Metadata[server] = %q, want %q", got.Metadata["server"], "filesystem")
	}
}

func TestMapToProviderEvent_McpToolCall_NilPayload(t *testing.T) {
	ev := Event{
		Msg: EventMsg{
			Kind:    EventItem,
			RawType: "item",
			Item:    &TurnItem{Kind: ItemMcpToolCall, McpToolCall: nil},
		},
	}
	_, ok := mapToProviderEvent(ev)
	if ok {
		t.Error("expected false for mcp_tool_call with nil payload, got true")
	}
}

func TestMapToProviderEvent_FileChange(t *testing.T) {
	ev := makeFileChangeItemEvent()
	got, ok := mapToProviderEvent(ev)
	if !ok {
		t.Fatal("mapToProviderEvent returned false for file_change item")
	}
	if got.Kind != provider.EventToolResult {
		t.Errorf("Kind = %v, want EventToolResult", got.Kind)
	}
	if got.Content != "file_change" {
		t.Errorf("Content = %q, want %q", got.Content, "file_change")
	}
}

func TestMapToProviderEvent_ErrorEvent(t *testing.T) {
	ev := makeErrorEvent("quota exceeded", &CodexErrorInfo{Kind: ErrorKindUsageLimitExceeded})
	got, ok := mapToProviderEvent(ev)
	if !ok {
		t.Fatal("mapToProviderEvent returned false for error event")
	}
	if got.Kind != provider.EventTurnEnd {
		t.Errorf("Kind = %v, want EventTurnEnd", got.Kind)
	}
	if got.Content != "quota exceeded" {
		t.Errorf("Content = %q, want %q", got.Content, "quota exceeded")
	}
	if got.Metadata["error"] != "true" {
		t.Errorf("Metadata[error] = %q, want %q", got.Metadata["error"], "true")
	}
}

func TestMapToProviderEvent_ErrorEvent_NilPayload(t *testing.T) {
	ev := Event{Msg: EventMsg{Kind: EventError, Error: nil}}
	got, ok := mapToProviderEvent(ev)
	if !ok {
		t.Fatal("expected true for error event with nil payload (returns bare EventTurnEnd)")
	}
	if got.Kind != provider.EventTurnEnd {
		t.Errorf("Kind = %v, want EventTurnEnd", got.Kind)
	}
}

func TestMapToProviderEvent_SessionConfigured_NotSurfaced(t *testing.T) {
	ev := makeSessionConfiguredEvent()
	_, ok := mapToProviderEvent(ev)
	if ok {
		t.Error("session_configured should not be surfaced (expected false)")
	}
}

func TestMapToProviderEvent_TokenCount_NotSurfaced(t *testing.T) {
	ev := makeTokenCountEvent()
	_, ok := mapToProviderEvent(ev)
	if ok {
		t.Error("token_count should not be surfaced (expected false)")
	}
}

func TestMapToProviderEvent_ShutdownComplete_NotSurfaced(t *testing.T) {
	ev := Event{Msg: EventMsg{Kind: EventShutdownComplete, RawType: "shutdown_complete"}}
	_, ok := mapToProviderEvent(ev)
	if ok {
		t.Error("shutdown_complete should not be surfaced (expected false)")
	}
}

func TestMapToProviderEvent_Unknown_NotSurfaced(t *testing.T) {
	ev := Event{Msg: EventMsg{Kind: EventUnknown, RawType: "some_future_event"}}
	_, ok := mapToProviderEvent(ev)
	if ok {
		t.Error("unknown event kind should not be surfaced (expected false)")
	}
}

func TestMapToProviderEvent_Item_NilItem(t *testing.T) {
	ev := Event{Msg: EventMsg{Kind: EventItem, Item: nil}}
	_, ok := mapToProviderEvent(ev)
	if ok {
		t.Error("item event with nil Item should not be surfaced (expected false)")
	}
}

func TestMapToProviderEvent_Item_UnknownKind(t *testing.T) {
	ev := Event{
		Msg: EventMsg{
			Kind:    EventItem,
			RawType: "item",
			Item:    &TurnItem{Kind: ItemUnknown},
		},
	}
	_, ok := mapToProviderEvent(ev)
	if ok {
		t.Error("item with unknown kind should not be surfaced (expected false)")
	}
}

// TestMapToProviderEvent_Timestamp verifies the returned event always
// has a non-zero Timestamp (set by mapToProviderEvent itself).
func TestMapToProviderEvent_Timestamp(t *testing.T) {
	ev := makeTaskStartedEvent("1")
	got, ok := mapToProviderEvent(ev)
	if !ok {
		t.Fatal("unexpected false")
	}
	if got.Timestamp.IsZero() {
		t.Error("Timestamp is zero; mapToProviderEvent must set it")
	}
}

// TestMapToProviderEvent_OutOfRangeEventKind verifies that an EventKind value
// not listed in the switch (e.g., a future protocol addition) is not surfaced.
// This exercises the implicit fallthrough at the bottom of mapToProviderEvent
// that provides forward-compatibility with unknown event types.
func TestMapToProviderEvent_OutOfRangeEventKind(t *testing.T) {
	ev := Event{Msg: EventMsg{Kind: EventKind(999), RawType: "future_unknown_event"}}
	_, ok := mapToProviderEvent(ev)
	if ok {
		t.Error("out-of-range EventKind(999) should not be surfaced (expected false)")
	}
}

// TestMapToProviderEvent_TaskComplete_NilPayload verifies that a task_complete
// event with a nil payload returns (_, false) without panicking. Mirrors the
// analogous test for task_started and mcp_tool_call.
func TestMapToProviderEvent_TaskComplete_NilPayload(t *testing.T) {
	ev := Event{Msg: EventMsg{Kind: EventTaskComplete, TaskComplete: nil}}
	_, ok := mapToProviderEvent(ev)
	if ok {
		t.Error("expected false for task_complete with nil payload, got true")
	}
}
