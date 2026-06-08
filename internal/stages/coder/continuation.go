package coder

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// ContinuationConfig holds the M14 continuation-loop knobs. The orchestrator
// resolves these from the Config snapshot at stage entry; tests pass
// explicit values to drive specific budgets and attempt caps.
type ContinuationConfig struct {
	// Enabled mirrors CONTINUATION_ENABLED. Default true.
	Enabled bool

	// MaxAttempts mirrors MAX_CONTINUATION_ATTEMPTS. Default 3.
	MaxAttempts int

	// Budget mirrors EFFECTIVE_CODER_MAX_TURNS. Threaded into each
	// continuation pass verbatim.
	Budget int

	// Template is the prompt template to render per attempt. Always "coder"
	// in production — continuation does NOT use tag-specific templates.
	Template string

	// Model and AgentTools threaded into the agent request.
	Model      string
	AgentTools string
}

// DefaultContinuationConfig returns the bash defaults byte-identically.
func DefaultContinuationConfig() *ContinuationConfig {
	return &ContinuationConfig{
		Enabled:     true,
		MaxAttempts: 3,
		Budget:      80,
		Template:    "coder",
		Model:       "claude-sonnet-4-6",
	}
}

// ContinuationOutcome names the loop's terminal disposition. The
// orchestrator branches on this to decide whether to proceed to the
// completion gate or save state.
type ContinuationOutcome string

const (
	OutcomeComplete       ContinuationOutcome = "complete"
	OutcomeNoMoreProgress ContinuationOutcome = "no_more_progress"
	OutcomeUpstreamError  ContinuationOutcome = "upstream_error"
	OutcomeNoSummary      ContinuationOutcome = "no_summary"
)

// ContinuationResult is the loop's return envelope.
type ContinuationResult struct {
	AttemptsRun     int
	CumulativeTurns int
	Outcome         ContinuationOutcome
}

// RunContinuation executes the M14 CONTINUATION_ENABLED loop. Mirrors
// stages/coder.sh:949-1019 line-for-line.
//
// Sequence per attempt:
//  1. Build CONTINUATION_CONTEXT via Deps.BuildContinuationContext.
//  2. Render coder.prompt.md with the new context.
//  3. Invoke the coder agent with cfg.Budget.
//  4. Accumulate turns.
//  5. UPSTREAM error → OutcomeUpstreamError (short-circuit).
//  6. Missing summary → reconstruct if substantive, else OutcomeNoSummary.
//  7. Status COMPLETE → OutcomeComplete.
//  8. No substantive new progress → OutcomeNoMoreProgress.
//
// The MAX_CONTINUATION_ATTEMPTS=3 default is load-bearing: raising it
// multiplies the per-stage worst-case turn count. Operators tuning this
// should understand the multiplicative cost.
func RunContinuation(ctx context.Context, cfg *ContinuationConfig, deps *Deps) (*ContinuationResult, error) {
	if cfg == nil {
		cfg = DefaultContinuationConfig()
	}
	if cfg.MaxAttempts <= 0 {
		cfg.MaxAttempts = 3
	}
	if cfg.Template == "" {
		cfg.Template = "coder"
	}
	if !cfg.Enabled {
		return &ContinuationResult{Outcome: OutcomeNoMoreProgress}, nil
	}
	result := &ContinuationResult{}

	for attempt := 1; attempt <= cfg.MaxAttempts; attempt++ {
		result.AttemptsRun = attempt

		contCtx := ""
		if deps != nil && deps.BuildContinuationContext != nil {
			contCtx = deps.BuildContinuationContext("coder", attempt, cfg.MaxAttempts,
				result.CumulativeTurns, cfg.Budget)
		}

		prompt := ""
		if deps != nil && deps.RenderPrompt != nil {
			vars := map[string]string{"CONTINUATION_CONTEXT": contCtx}
			p, err := deps.RenderPrompt(cfg.Template, vars)
			if err != nil {
				return result, fmt.Errorf("render %s: %w", cfg.Template, err)
			}
			prompt = p
		}

		if deps == nil || deps.RunAgent == nil {
			// No agent wired — return after one attempt so tests can drive
			// the no-agent branch.
			result.Outcome = OutcomeNoSummary
			return result, nil
		}

		req := &proto.AgentRequestV1{
			Proto:        proto.AgentRequestProtoV1,
			Label:        fmt.Sprintf("Coder (continuation %d)", attempt),
			Model:        cfg.Model,
			MaxTurns:     cfg.Budget,
			PromptFile:   prompt,
			AllowedTools: cfg.AgentTools,
		}
		res, err := deps.RunAgent(ctx, req)
		if err != nil {
			return result, err
		}
		if res != nil {
			result.CumulativeTurns += res.TurnsUsed
			// UPSTREAM short-circuit — same vocabulary as the senior coder
			// invocation. Tests assert single-attempt return.
			if res.ErrorCategory == "UPSTREAM" {
				result.Outcome = OutcomeUpstreamError
				return result, nil
			}
		}

		summary := readContSummary(deps)
		if summary == "" {
			if deps.IsSubstantiveWork != nil && deps.IsSubstantiveWork() {
				_ = ReconstructSummary(ctx, summaryPathFromDeps(deps), "COMPLETE", deps)
				continue
			}
			result.Outcome = OutcomeNoSummary
			return result, nil
		}
		if strings.Contains(summary, "## Status") && strings.Contains(summary, "COMPLETE") {
			result.Outcome = OutcomeComplete
			return result, nil
		}
		if deps.IsSubstantiveWork != nil && !deps.IsSubstantiveWork() {
			result.Outcome = OutcomeNoMoreProgress
			return result, nil
		}
	}
	result.Outcome = OutcomeNoMoreProgress
	return result, nil
}

// readContSummary reads CODER_SUMMARY.md best-effort from the env-resolved
// path. Returns "" when missing.
func readContSummary(_ *Deps) string {
	path := os.Getenv("CODER_SUMMARY_FILE")
	if path == "" {
		path = ".tekhton/CODER_SUMMARY.md"
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

// summaryPathFromDeps returns the CODER_SUMMARY.md path the reconstruct
// helper should write to. Resolved from env at call time so tests setting
// CODER_SUMMARY_FILE see the override.
func summaryPathFromDeps(_ *Deps) string {
	path := os.Getenv("CODER_SUMMARY_FILE")
	if path == "" {
		path = ".tekhton/CODER_SUMMARY.md"
	}
	return path
}
