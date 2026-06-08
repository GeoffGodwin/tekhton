package security

import (
	"context"
	"fmt"
	"os"
	"strconv"

	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/geoffgodwin/tekhton/internal/provider"
)

// invokeScanAgent renders the security_scan prompt and dispatches it via
// the package-level Provider. Mirrors stages/security.sh:47-83 — turn
// clamp (with MILESTONE_MODE doubling) → SECURITY_REPORT_CONTENT export →
// render → run_agent. Returns the provider result so the stage can
// count agent calls.
func invokeScanAgent(ctx context.Context, cfg config) (*provider.Result, error) {
	turns := clampTurns(cfg)

	// Pre-load previous SECURITY_REPORT.md so the prompt can reference it
	// (matches the bash export SECURITY_REPORT_CONTENT line).
	vars := prompt.EnvVars()
	if data, err := os.ReadFile(cfg.ReportFile); err == nil {
		vars["SECURITY_REPORT_CONTENT"] = string(data)
	} else {
		vars["SECURITY_REPORT_CONTENT"] = ""
	}

	body, err := prompt.Render(cfg.PromptsDir, "security_scan", vars)
	if err != nil {
		return nil, fmt.Errorf("render security_scan: %w", err)
	}

	return cfg.Provider.RunAgent(ctx, &provider.Request{
		Prompt:       body,
		Label:        "Security (scan)",
		Model:        cfg.ScanModel,
		MaxTurns:     turns,
		WorkingDir:   cfg.ProjectDir,
		AllowedTools: cfg.ReviewerTools,
	})
}

// clampTurns ports stages/security.sh:48-59 verbatim. The bash logic is:
//
//	turns := SECURITY_MAX_TURNS (default 15)
//	if MILESTONE_MODE == "true":
//	    turns := MILESTONE_SECURITY_MAX_TURNS (default turns*2)
//	if turns < SECURITY_MIN_TURNS: turns := SECURITY_MIN_TURNS
//	if turns > SECURITY_MAX_TURNS_CAP: turns := SECURITY_MAX_TURNS_CAP
//
// The MILESTONE_SECURITY_MAX_TURNS branch defaults to `turns * 2`, NOT to
// the env-default of SECURITY_MAX_TURNS — see Watch For in the milestone.
func clampTurns(cfg config) int {
	turns := cfg.MaxTurns
	if cfg.MilestoneMode {
		if cfg.MilestoneSecurityTurns != "" {
			if n, err := strconv.Atoi(cfg.MilestoneSecurityTurns); err == nil && n > 0 {
				turns = n
			} else {
				turns = cfg.MaxTurns * 2
			}
		} else {
			turns = cfg.MaxTurns * 2
		}
	}
	if turns < cfg.MinTurns {
		turns = cfg.MinTurns
	}
	if turns > cfg.MaxTurnsCap {
		turns = cfg.MaxTurnsCap
	}
	return turns
}
