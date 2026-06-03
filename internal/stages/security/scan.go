package security

import (
	"context"
	"fmt"
	"os"
	"strconv"

	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// invokeScanAgent renders the security_scan prompt and dispatches it via
// the package-level AgentRunner. Mirrors stages/security.sh:47-83 — turn
// clamp (with MILESTONE_MODE doubling) → SECURITY_REPORT_CONTENT export →
// render → run_agent. Returns the supervisor result so the stage can
// count agent calls.
func invokeScanAgent(ctx context.Context, cfg config, req *proto.StageRequestV1) (*proto.AgentResultV1, error) {
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

	promptFile, cleanup, err := writePromptTmpFile(body)
	if err != nil {
		return nil, fmt.Errorf("write security_scan prompt: %w", err)
	}
	defer cleanup()

	agentReq := &proto.AgentRequestV1{
		Proto:        proto.AgentRequestProtoV1,
		Label:        "Security (scan)",
		Model:        cfg.ScanModel,
		MaxTurns:     turns,
		PromptFile:   promptFile,
		WorkingDir:   cfg.ProjectDir,
		AllowedTools: cfg.ReviewerTools,
	}
	return agentRunner.Run(ctx, agentReq)
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
