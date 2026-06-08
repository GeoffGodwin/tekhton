package security

import (
	"context"
	"fmt"

	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/geoffgodwin/tekhton/internal/provider"
)

// invokeReworkAgent renders the security_rework prompt with the
// SECURITY_FIXABLE_BLOCK env var exported and dispatches it via the
// package-level AgentRunner. Mirrors stages/security.sh:115-133.
//
// The bash side `export SECURITY_FIXABLE_BLOCK="$fixable_block"` is
// reproduced by setting it in the prompt-variable map (prompt.Render reads
// from the map, not from process env, so this avoids polluting global env
// state across the rework cycle).
func invokeReworkAgent(ctx context.Context, cfg config, fixableBlock string, cycle int) (*provider.Result, error) {
	vars := prompt.EnvVars()
	vars["SECURITY_FIXABLE_BLOCK"] = fixableBlock

	body, err := prompt.Render(cfg.PromptsDir, "security_rework", vars)
	if err != nil {
		return nil, fmt.Errorf("render security_rework: %w", err)
	}

	return cfg.Provider.RunAgent(ctx, &provider.Request{
		Prompt:       body,
		Label:        fmt.Sprintf("Security Rework (cycle %d)", cycle),
		Model:        cfg.CoderModel,
		MaxTurns:     cfg.CoderMaxTurns,
		WorkingDir:   cfg.ProjectDir,
		AllowedTools: cfg.CoderTools,
	})
}
