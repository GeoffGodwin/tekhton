package claude

import (
	"fmt"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// claudeNativeTool is the wire format the Claude CLI tool_use block expects.
type claudeNativeTool struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description"`
	InputSchema map[string]interface{} `json:"input_schema"`
}

// translateTools converts a Tekhton ToolSchema slice to Claude's native
// tool_use input format. Returns nil, nil on empty input — the Claude CLI
// treats "no tools provided" as "use the default built-in tool set", which
// is the correct behaviour for current Tekhton stages that don't yet
// populate Request.Tools (m03 ships the translator; m04 wires stages).
//
// Emitting an empty JSON array instead would signal "no tools available"
// to the Claude CLI and break coder-stage agents that rely on built-ins.
func translateTools(in []provider.ToolSchema) ([]claudeNativeTool, error) {
	if len(in) == 0 {
		return nil, nil
	}
	out := make([]claudeNativeTool, 0, len(in))
	for _, t := range in {
		if err := provider.ValidateToolSchema(t); err != nil {
			return nil, fmt.Errorf("claude: translate tool %q: %w", t.Name, err)
		}
		out = append(out, claudeNativeTool{
			Name:        t.Name,
			Description: t.Description,
			InputSchema: translateParameters(t.Parameters),
		})
	}
	return out, nil
}

// translateParameters maps a ParameterSchema to the map[string]interface{}
// shape the Claude CLI input_schema field expects.
func translateParameters(p provider.ParameterSchema) map[string]interface{} {
	props := make(map[string]interface{}, len(p.Properties))
	for name, prop := range p.Properties {
		props[name] = translateProperty(prop)
	}
	required := p.Required
	if required == nil {
		required = []string{}
	}
	return map[string]interface{}{
		"type":                 p.Type,
		"properties":           props,
		"required":             required,
		"additionalProperties": p.AdditionalProperties,
	}
}

// translateProperty maps a ParameterProperty to its wire-format map.
func translateProperty(p provider.ParameterProperty) map[string]interface{} {
	out := map[string]interface{}{
		"type":        p.Type,
		"description": p.Description,
	}
	if p.Items != nil {
		out["items"] = translateProperty(*p.Items)
	}
	if len(p.Enum) > 0 {
		out["enum"] = p.Enum
	}
	return out
}
