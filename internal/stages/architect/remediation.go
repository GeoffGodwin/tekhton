package architect

import (
	"context"
	"fmt"

	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// remediationKind identifies which architect rework path runs.
type remediationKind string

const (
	remediationSr remediationKind = "sr_rework"
	remediationJr remediationKind = "jr_rework"
)

// runRework dispatches a single architect remediation pass via the
// package-level AgentRunner. Mirrors stages/architect.sh:160-194 — sr
// covers ONLY Simplification, jr covers Staleness + Dead Code + Naming.
// The two coder dispatches stay separate so operators can tune the two
// models (CLAUDE_CODER_MODEL vs CLAUDE_JR_CODER_MODEL) independently.
func runRework(ctx context.Context, kind remediationKind, cfg config) error {
	var (
		template string
		label    string
		model    string
		turns    int
		tools    string
	)
	switch kind {
	case remediationSr:
		template = "architect_sr_rework"
		label = "Coder (architect remediation)"
		model = cfg.CoderModel
		turns = cfg.CoderMaxTurns
		tools = cfg.CoderTools
	case remediationJr:
		template = "architect_jr_rework"
		label = "Jr Coder (architect remediation)"
		model = cfg.JrCoderModel
		turns = cfg.JrCoderMaxTurns
		tools = cfg.JrCoderTools
	default:
		return fmt.Errorf("architect: unknown remediation kind %q", kind)
	}
	return invokeAgent(ctx, cfg, label, model, turns, template, tools, nil)
}

// runBuildFix invokes the build_fix_minimal prompt with a CODER_MAX_TURNS/3
// budget. Mirrors stages/architect.sh:201-210. The integer division is
// preserved verbatim.
func runBuildFix(ctx context.Context, cfg config) error {
	turns := cfg.CoderMaxTurns / 3
	if turns < 1 {
		turns = 1
	}
	return invokeAgent(ctx, cfg,
		"Coder (architect build fix)",
		cfg.CoderModel,
		turns,
		"build_fix_minimal",
		cfg.BuildFixTools,
		nil,
	)
}

// runExpeditedReview invokes the architect_review prompt with the standard
// reviewer model + turn budget. Mirrors stages/architect.sh:240-250. The
// PRIOR_BLOCKERS_BLOCK is cleared so a stale value from the main reviewer
// loop does not bleed into the expedited cycle.
func runExpeditedReview(ctx context.Context, cfg config) error {
	overrides := map[string]string{
		"PRIOR_BLOCKERS_BLOCK": "",
	}
	return invokeAgent(ctx, cfg,
		"Reviewer (architect expedited)",
		cfg.StandardModel,
		cfg.ReviewerMaxTurns,
		"architect_review",
		cfg.ReviewerTools,
		overrides,
	)
}

// invokeAgent is the shared dispatcher for all architect-stage agent calls.
// Mirrors run_agent in lib/agent.sh — renders the prompt, writes the body
// to a temp file, dispatches via the package-level AgentRunner seam.
//
// The varOverrides argument inserts/overwrites prompt variables before
// render so callers can scope additional values without polluting the
// shared env.
func invokeAgent(ctx context.Context, cfg config, label, model string, turns int,
	template, tools string, varOverrides map[string]string,
) error {
	vars := prompt.EnvVars()
	for k, v := range varOverrides {
		vars[k] = v
	}

	body, err := prompt.Render(cfg.PromptsDir, template, vars)
	if err != nil {
		return fmt.Errorf("architect: render %s: %w", template, err)
	}

	promptFile, cleanup, err := writePromptTmpFile(body)
	if err != nil {
		return fmt.Errorf("architect: write prompt %s: %w", template, err)
	}
	defer cleanup()

	agentReq := &proto.AgentRequestV1{
		Proto:        proto.AgentRequestProtoV1,
		Label:        label,
		Model:        model,
		MaxTurns:     turns,
		PromptFile:   promptFile,
		WorkingDir:   cfg.ProjectDir,
		AllowedTools: tools,
	}
	_, err = agentRunner.Run(ctx, agentReq)
	return err
}
