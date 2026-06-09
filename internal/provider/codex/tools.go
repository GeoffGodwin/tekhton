package codex

import (
	"fmt"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// translateTools converts a Tekhton ToolSchema slice into Codex CLI
// invocation arguments. Returns:
//   - extraArgs: -c key=value config overrides for tool restriction
//   - sandboxOverride: a sandbox mode string ("read-only" |
//     "workspace-write" | ""); empty means use the default
//
// The translation derives Codex semantics from Tekhton's BehaviorHints:
//
//	ModifiesFiles=true OR ExecutesShell=true → "workspace-write"
//	Reads=true and others false              → "read-only"
//
// Per-tool granularity (Read vs Write vs Edit vs Bash vs Glob vs Grep)
// is expressed via Codex's permissions config layer. The tool_map.go
// table maps each Tekhton name to its Codex permission key.
func translateTools(tools []provider.ToolSchema) (extraArgs []string, sandboxOverride string, err error) {
	if len(tools) == 0 {
		return nil, "", nil
	}

	for _, t := range tools {
		if valErr := provider.ValidateToolSchema(t); valErr != nil {
			return nil, "", fmt.Errorf("codex: invalid tool %q: %w", t.Name, valErr)
		}
	}

	var anyModifies, anyShell, anyReads bool
	for _, t := range tools {
		if t.BehaviorHints.ModifiesFiles {
			anyModifies = true
		}
		if t.BehaviorHints.ExecutesShell {
			anyShell = true
		}
		if t.BehaviorHints.Reads {
			anyReads = true
		}
	}

	switch {
	case anyModifies || anyShell:
		sandboxOverride = "workspace-write"
	case anyReads:
		sandboxOverride = "read-only"
	}

	allowed := make([]string, 0, len(tools))
	for _, t := range tools {
		codexName, ok := codexToolName(t.Name)
		if !ok {
			// Unknown tool — grant the catch-all shell permission.
			allowed = append(allowed, "shell")
			continue
		}
		allowed = append(allowed, codexName)
	}
	extraArgs = []string{
		"-c", fmt.Sprintf("tools.allowed=%s", joinAllowed(allowed)),
	}
	return extraArgs, sandboxOverride, nil
}

// joinAllowed formats a slice of permission key names as a
// Codex inline-config array literal: ["name1","name2",...].
func joinAllowed(names []string) string {
	parts := make([]string, 0, len(names))
	for _, n := range names {
		parts = append(parts, fmt.Sprintf("%q", n))
	}
	return "[" + strings.Join(parts, ",") + "]"
}
