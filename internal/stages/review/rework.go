package review

import (
	"context"
	"fmt"

	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/geoffgodwin/tekhton/internal/provider"
	reviewparse "github.com/geoffgodwin/tekhton/internal/review"
	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
)

// runRework drives the senior/jr/both routing matrix from stages/review.sh:271-352
// and the build-gate post-fix-pass escalation. Returns the agent-call count
// dispatched (so the caller can roll it into the StageResultV1 envelope) and
// a non-nil error only when the build gate cannot recover.
func runRework(ctx context.Context, cfg *config, report *reviewparse.Report,
	budget reviewparse.CycleBudget, log staglog.Logger,
) (int, error) {
	hasComplex := report.HasComplexBlockers()
	hasSimple := report.HasSimpleBlockers()
	calls := 0

	if hasComplex > 0 {
		log.Info(fmt.Sprintf("Routing to senior coder rework (%d complex, %d simple blockers).",
			hasComplex, hasSimple))
		if err := invokeCoderRework(ctx, cfg, budget); err != nil {
			return calls, fmt.Errorf("senior coder rework: %w", err)
		}
		calls++
		if hasSimple > 0 {
			log.Info("Simple blockers remain. Invoking jr coder...")
			if err := invokeJrCoderRework(ctx, cfg, budget, true); err != nil {
				return calls, fmt.Errorf("jr coder follow-up: %w", err)
			}
			calls++
		}
	} else if hasSimple > 0 {
		log.Info(fmt.Sprintf("Routing to jr coder rework (%d simple blockers).", hasSimple))
		if err := invokeJrCoderRework(ctx, cfg, budget, false); err != nil {
			return calls, fmt.Errorf("jr coder rework: %w", err)
		}
		calls++
	}

	// Build gate + escalation.
	if err := buildGateRunner.Run(ctx, cfg.ProjectDir, "post-fix-pass"); err != nil {
		log.Warn("Build gate failed after fix pass — escalating to build-fix-minimal.")
		if err := invokeBuildFixMinimal(ctx, cfg); err != nil {
			return calls, fmt.Errorf("build_fix_minimal escalation: %w", err)
		}
		calls++
		if err := buildGateRunner.Run(ctx, cfg.ProjectDir, "post-fix-pass-retry"); err != nil {
			return calls, fmt.Errorf("build_failure_after_retry: %w", err)
		}
	}
	return calls, nil
}

// invokeCoderRework renders coder_rework.prompt.md (NOT coder.prompt.md —
// see m37 parent Watch For) and invokes the senior-coder model.
func invokeCoderRework(ctx context.Context, cfg *config, budget reviewparse.CycleBudget) error {
	vars := prompt.EnvVars()
	vars["REVIEW_CYCLE"] = fmt.Sprintf("%d", budget.Current)

	body, err := prompt.Render(cfg.PromptsDir, "coder_rework", vars)
	if err != nil {
		return fmt.Errorf("render coder_rework: %w", err)
	}
	return dispatchAgent(ctx, cfg, body, &provider.Request{
		Label:        fmt.Sprintf("Coder (rework cycle %d)", budget.Current),
		Model:        cfg.CoderModel,
		MaxTurns:     cfg.EffectiveCoderTurns,
		WorkingDir:   cfg.ProjectDir,
		AllowedTools: cfg.CoderTools,
	})
}

// invokeJrCoderRework renders jr_coder.prompt.md. afterSenior signals the
// "JR_AFTER_SENIOR=yes" branch the bash version sets before render so the
// prompt knows it is a follow-up pass.
func invokeJrCoderRework(ctx context.Context, cfg *config, budget reviewparse.CycleBudget, afterSenior bool) error {
	vars := prompt.EnvVars()
	vars["REVIEW_CYCLE"] = fmt.Sprintf("%d", budget.Current)
	if afterSenior {
		vars["JR_AFTER_SENIOR"] = "yes"
	} else {
		vars["JR_AFTER_SENIOR"] = ""
	}

	body, err := prompt.Render(cfg.PromptsDir, "jr_coder", vars)
	if err != nil {
		return fmt.Errorf("render jr_coder: %w", err)
	}
	return dispatchAgent(ctx, cfg, body, &provider.Request{
		Label:        fmt.Sprintf("Jr Coder (cycle %d)", budget.Current),
		Model:        cfg.JrCoderModel,
		MaxTurns:     cfg.EffectiveJrTurns,
		WorkingDir:   cfg.ProjectDir,
		AllowedTools: cfg.JrCoderTools,
	})
}

// invokeBuildFixMinimal renders build_fix_minimal.prompt.md with the
// CODER_MAX_TURNS/3 turn budget (matches stages/review.sh:341).
func invokeBuildFixMinimal(ctx context.Context, cfg *config) error {
	vars := prompt.EnvVars()
	body, err := prompt.Render(cfg.PromptsDir, "build_fix_minimal", vars)
	if err != nil {
		return fmt.Errorf("render build_fix_minimal: %w", err)
	}
	turns := cfg.CoderMaxTurns / 3
	if turns < 1 {
		turns = 1
	}
	return dispatchAgent(ctx, cfg, body, &provider.Request{
		Label:        "Coder (post-fix-pass build fix)",
		Model:        cfg.CoderModel,
		MaxTurns:     turns,
		WorkingDir:   cfg.ProjectDir,
		AllowedTools: cfg.BuildFixTools,
	})
}

// dispatchAgent dispatches an agent call via the config's Provider.
func dispatchAgent(ctx context.Context, cfg *config, body string, req *provider.Request) error {
	req.Prompt = body
	_, err := cfg.Provider.RunAgent(ctx, req)
	return err
}
