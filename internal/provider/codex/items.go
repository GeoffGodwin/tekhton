// Package codex — TurnItem taxonomy.
// V5 m08 — type definitions. m10 surfaces these via streaming events.
package codex

import "encoding/json"

// TurnItem is the tagged union of all item types in a Codex turn.
// Kind is the discriminator; typed payload fields are populated
// for matching items.
type TurnItem struct {
	Kind             ItemKind
	McpToolCall      *McpToolCallItem
	FileChange       *FileChangeItem
	UserMessage      *UserMessageItem
	AgentMessage     *AgentMessageItem
	Plan             *PlanItem
	Reasoning        *ReasoningItem
	ContextCompaction *ContextCompactionItem
}

// ItemKind enumerates TurnItem variants.
type ItemKind int

const (
	ItemUnknown          ItemKind = iota
	ItemUserMessage                // "user_message"
	ItemHookPrompt                 // "hook_prompt"
	ItemAgentMessage               // "agent_message"
	ItemPlan                       // "plan"
	ItemReasoning                  // "reasoning"
	ItemWebSearch                  // "web_search"
	ItemImageView                  // "image_view"
	ItemImageGeneration            // "image_generation"
	ItemFileChange                 // "file_change"
	ItemMcpToolCall                // "mcp_tool_call"
	ItemContextCompaction          // "context_compaction"
)

// McpToolCallItem carries an MCP tool invocation.
type McpToolCallItem struct {
	Tool   string `json:"tool"`
	Server string `json:"server"`
}

// FileChangeItem carries a file modification record.
type FileChangeItem struct {
	Path string `json:"path,omitempty"`
	Kind string `json:"kind,omitempty"` // "create" | "modify" | "delete"
}

// UserMessageItem carries a user message in the turn.
type UserMessageItem struct {
	Content string `json:"content,omitempty"`
}

// AgentMessageItem carries an agent message chunk.
type AgentMessageItem struct {
	Content string `json:"content,omitempty"`
}

// PlanItem carries a planning step.
type PlanItem struct {
	Content string `json:"content,omitempty"`
}

// ReasoningItem carries an internal reasoning chunk.
type ReasoningItem struct {
	Content string `json:"content,omitempty"`
}

// ContextCompactionItem signals a context-compaction event.
type ContextCompactionItem struct{}

// UnmarshalJSON decodes a TurnItem from its JSON representation.
// The JSON shape for an item event carries a "item_kind" discriminator
// alongside the payload fields in the same object.
func (t *TurnItem) UnmarshalJSON(data []byte) error {
	var probe struct {
		Kind string `json:"item_kind"`
	}
	if err := json.Unmarshal(data, &probe); err != nil {
		return err
	}
	switch probe.Kind {
	case "mcp_tool_call":
		t.Kind = ItemMcpToolCall
		t.McpToolCall = &McpToolCallItem{}
		return json.Unmarshal(data, t.McpToolCall)
	case "file_change":
		t.Kind = ItemFileChange
		t.FileChange = &FileChangeItem{}
		return json.Unmarshal(data, t.FileChange)
	case "user_message":
		t.Kind = ItemUserMessage
		t.UserMessage = &UserMessageItem{}
		return json.Unmarshal(data, t.UserMessage)
	case "agent_message":
		t.Kind = ItemAgentMessage
		t.AgentMessage = &AgentMessageItem{}
		return json.Unmarshal(data, t.AgentMessage)
	case "plan":
		t.Kind = ItemPlan
		t.Plan = &PlanItem{}
		return json.Unmarshal(data, t.Plan)
	case "reasoning":
		t.Kind = ItemReasoning
		t.Reasoning = &ReasoningItem{}
		return json.Unmarshal(data, t.Reasoning)
	case "context_compaction":
		t.Kind = ItemContextCompaction
		t.ContextCompaction = &ContextCompactionItem{}
	default:
		t.Kind = ItemUnknown
	}
	return nil
}
