package provider

import "time"

// Event is one streaming event from an agent run. The TUI sidecar (m97)
// consumes Events for live progress display; stages may consume them for
// cycle bookkeeping.
//
// Channel ownership: the provider writes and closes EventChan when the
// run ends. Consumers MUST drain with:
//
//	for ev := range ch { ... }
type Event struct {
	Kind      EventKind
	Timestamp time.Time
	Turn      int               // 1-indexed; 0 if not turn-specific.
	Content   string            // AssistantChunk: chunk text; ToolCall: tool name.
	Metadata  map[string]string // Per-Kind extras (tool args, error category, etc.).
}

// EventKind classifies a streaming event from a provider.
type EventKind int

const (
	EventUnknown        EventKind = iota
	EventTurnStart                // A new turn begins.
	EventAssistantChunk           // A chunk of the assistant response.
	EventToolCall                 // The assistant invoked a tool.
	EventToolResult               // The tool returned a result.
	EventTurnEnd                  // Turn complete.
	EventRunEnd                   // The whole run is done.
)
