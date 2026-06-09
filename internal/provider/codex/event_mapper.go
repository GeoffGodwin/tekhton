// Package codex — Codex event → provider.Event translation.
// V5 m10 — mapToProviderEvent.
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
//
//	task_started        → EventTurnStart    (Turn = parsed turn_id)
//	task_complete       → EventTurnEnd      (Turn = parsed turn_id, Metadata["duration_ms"])
//	agent_message       → EventAssistantChunk (Content = agent text)
//	item: McpToolCall   → EventToolCall     (Content = tool name, Metadata["server"])
//	item: FileChange    → EventToolResult   (Content = "file_change")
//	token_count         → (not surfaced — telemetry only)
//	error               → EventTurnEnd      (Metadata["error"] = "true")
//	session_configured  → (not surfaced)
//	shutdown_complete   → (not surfaced)
//
// EventRunEnd is emitted by runCodexStreaming after process exit, not here.
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
		return provider.Event{}, false

	case EventTokenCount, EventSessionConfigured, EventShutdownComplete, EventUnknown:
		return provider.Event{}, false
	}

	return provider.Event{}, false
}
