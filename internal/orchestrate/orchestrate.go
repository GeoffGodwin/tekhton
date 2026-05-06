// Package orchestrate owns the outer pipeline loop ported from
// lib/orchestrate.sh as part of the m12 wedge.
//
// The bash front-end (tekhton.sh) renders task / milestone context, then
// hands a tekhton.attempt.request.v1 envelope to this package via
// `tekhton orchestrate run-attempt`. The Loop type wraps the attempt-driving
// logic that bash previously held in run_complete_loop: safety bounds,
// progress detection, recovery dispatch, state save.
//
// Stage execution itself stays in bash for m12 (CLAUDE.md Rule 9 wedge
// discipline — port the loop, not the stages). The stages are driven via
// StageRunner, which the cmd/tekhton wire-up implements as an exec into
// `tekhton.sh --run-stages`. Tests substitute a fake StageRunner.
package orchestrate

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// StageRunner runs a single iteration of the bash pipeline stages and reports
// the structured outcome. The real implementation shells back to tekhton.sh;
// tests substitute a fake to drive the recovery dispatch.
type StageRunner interface {
	RunStages(ctx context.Context, req *proto.AttemptRequestV1, attempt int) (StageOutcome, error)
}

// StageOutcome is the structured report from one iteration. It mirrors the
// bash globals AGENT_ERROR_CATEGORY / AGENT_ERROR_SUBCATEGORY / VERDICT and
// the failure-context primary/secondary cause slots that lib/orchestrate.sh
// reads after _run_pipeline_stages returns.
type StageOutcome struct {
	Success    bool
	TurnsUsed  int
	AgentCalls int

	// Failure detail. Empty when Success.
	ErrorCategory    string
	ErrorSubcategory string
	ErrorMessage     string
	Verdict          string

	// M129 cause slots — populated by stage classifier.
	PrimaryCat    string
	PrimarySub    string
	PrimarySignal string
	SecondaryCat  string
	SecondarySub  string

	// M130 build-fix routing token (LAST_BUILD_CLASSIFICATION).
	BuildClassification string

	// True when BUILD_ERRORS_FILE is non-empty after the stage run.
	BuildErrorsPresent bool
}

// Config carries orchestrator policy from pipeline.conf.
type Config struct {
	MaxPipelineAttempts     int
	AutonomousTimeoutSecs   int
	MaxAutonomousAgentCalls int
	ProgressCheckEnabled    bool

	// M130 amendments — feature flags from pipeline.conf.
	BuildFixClassificationRequired bool
	UIGateEnvRetryEnabled          bool
}

// DefaultConfig returns the same defaults the bash side applies via
// config_defaults.sh.
func DefaultConfig() Config {
	return Config{
		MaxPipelineAttempts:            5,
		AutonomousTimeoutSecs:          7200,
		MaxAutonomousAgentCalls:        200,
		ProgressCheckEnabled:           true,
		BuildFixClassificationRequired: true,
		UIGateEnvRetryEnabled:          true,
	}
}

// Loop is the in-process replacement for run_complete_loop in
// lib/orchestrate.sh. Construct via New, drive via RunAttempt.
type Loop struct {
	cfg     Config
	stages  StageRunner
	now     func() time.Time

	// Per-invocation guards — match the persistent _ORCH_*_RETRIED globals
	// in lib/orchestrate_cause.sh.
	envGateRetried     bool
	mixedBuildRetried  bool
}

// New constructs a Loop with the given runner and config.
func New(stages StageRunner, cfg Config) *Loop {
	return &Loop{
		cfg:    cfg,
		stages: stages,
		now:    time.Now,
	}
}

// SetEnvGateRetried lets external callers (CLI flags, tests) prime the
// persistent _ORCH_ENV_GATE_RETRIED guard. Not used by RunAttempt internally.
func (l *Loop) SetEnvGateRetried(v bool) { l.envGateRetried = v }

// SetMixedBuildRetried primes the _ORCH_MIXED_BUILD_RETRIED guard. Symmetric
// with SetEnvGateRetried.
func (l *Loop) SetMixedBuildRetried(v bool) { l.mixedBuildRetried = v }

// ErrAttemptCanceled is returned when ctx is canceled mid-attempt.
var ErrAttemptCanceled = errors.New("orchestrate: attempt canceled")

// RunAttempt drives the outer loop until the pipeline reports success, hits a
// safety bound, or classifies into a non-recoverable failure. The result
// envelope carries cumulative counters and the recovery class on failure.
func (l *Loop) RunAttempt(ctx context.Context, req *proto.AttemptRequestV1) (*proto.AttemptResultV1, error) {
	if req == nil {
		return nil, fmt.Errorf("orchestrate: nil request")
	}
	if err := req.Validate(); err != nil {
		return nil, fmt.Errorf("orchestrate: %w", err)
	}

	cfg := l.applyRequestOverrides(req)
	start := l.now()
	attempt := req.ResumeAttempt
	agentCalls := req.ResumeAgentCalls
	totalTurns := 0

	res := &proto.AttemptResultV1{
		Proto: proto.AttemptResultProtoV1,
		RunID: req.RunID,
	}

	for {
		if err := ctx.Err(); err != nil {
			res.Outcome = proto.AttemptOutcomeFailureSaveExit
			res.Recovery = proto.RecoverySaveExit
			res.ErrorMessage = "context canceled"
			res.Attempts = attempt
			res.AgentCalls = agentCalls
			res.ElapsedSecs = int64(l.now().Sub(start).Seconds())
			res.TotalTurns = totalTurns
			return res, fmt.Errorf("%w: %v", ErrAttemptCanceled, err)
		}

		attempt++
		elapsed := int64(l.now().Sub(start).Seconds())

		// Safety: wall-clock timeout (parity with lib/orchestrate.sh:177).
		if cfg.AutonomousTimeoutSecs > 0 && elapsed >= int64(cfg.AutonomousTimeoutSecs) {
			res.Outcome = proto.AttemptOutcomeSafetyBound
			res.Recovery = proto.RecoverySaveExit
			res.ErrorMessage = fmt.Sprintf("autonomous_timeout reached (%ds)", cfg.AutonomousTimeoutSecs)
			res.Attempts = attempt - 1
			res.AgentCalls = agentCalls
			res.ElapsedSecs = elapsed
			res.TotalTurns = totalTurns
			return res, nil
		}

		// Safety: max consecutive failures (parity with lib/orchestrate.sh:184).
		if cfg.MaxPipelineAttempts > 0 && attempt > cfg.MaxPipelineAttempts {
			res.Outcome = proto.AttemptOutcomeSafetyBound
			res.Recovery = proto.RecoverySaveExit
			res.ErrorMessage = fmt.Sprintf("max_pipeline_attempts reached (%d)", cfg.MaxPipelineAttempts)
			res.Attempts = attempt - 1
			res.AgentCalls = agentCalls
			res.ElapsedSecs = elapsed
			res.TotalTurns = totalTurns
			return res, nil
		}

		// Safety: agent-call cap (parity with lib/orchestrate.sh:191).
		if cfg.MaxAutonomousAgentCalls > 0 && agentCalls >= cfg.MaxAutonomousAgentCalls {
			res.Outcome = proto.AttemptOutcomeSafetyBound
			res.Recovery = proto.RecoverySaveExit
			res.ErrorMessage = fmt.Sprintf("max_autonomous_agent_calls reached (%d)", cfg.MaxAutonomousAgentCalls)
			res.Attempts = attempt - 1
			res.AgentCalls = agentCalls
			res.ElapsedSecs = elapsed
			res.TotalTurns = totalTurns
			return res, nil
		}

		// Run the bash pipeline stages for this iteration.
		outcome, err := l.stages.RunStages(ctx, req, attempt)
		if err != nil {
			res.Outcome = proto.AttemptOutcomeFailureSaveExit
			res.Recovery = proto.RecoverySaveExit
			res.ErrorMessage = err.Error()
			res.Attempts = attempt
			res.AgentCalls = agentCalls + outcome.AgentCalls
			res.ElapsedSecs = int64(l.now().Sub(start).Seconds())
			res.TotalTurns = totalTurns + outcome.TurnsUsed
			return res, err
		}

		agentCalls += outcome.AgentCalls
		totalTurns += outcome.TurnsUsed

		if outcome.Success {
			res.Outcome = proto.AttemptOutcomeSuccess
			res.Recovery = proto.RecoveryNone
			res.Attempts = attempt
			res.AgentCalls = agentCalls
			res.ElapsedSecs = int64(l.now().Sub(start).Seconds())
			res.TotalTurns = totalTurns
			return res, nil
		}

		// Failure path — classify and act.
		decision := l.Classify(outcome, cfg)
		switch decision {
		case proto.RecoveryRetryCoderBuild,
			proto.RecoveryRetryUIGateEnv,
			proto.RecoveryBumpReview,
			proto.RecoveryEscalateTurns:
			// Recoverable — record persistent guard and iterate.
			l.markGuard(decision)
			continue

		case proto.RecoverySplit:
			// Split is currently driven by the bash side (milestone_split.sh
			// is m11/m14 territory). For now, save_exit so the bash front-end
			// can run the split and resume.
			res.Outcome = proto.AttemptOutcomeFailureSaveExit
			res.Recovery = proto.RecoverySplit
			res.ErrorCategory = outcome.ErrorCategory
			res.ErrorSubcategory = outcome.ErrorSubcategory
			res.ErrorMessage = outcome.ErrorMessage
			res.CauseSummary = formatCauseSummary(outcome)
			res.Attempts = attempt
			res.AgentCalls = agentCalls
			res.ElapsedSecs = int64(l.now().Sub(start).Seconds())
			res.TotalTurns = totalTurns
			return res, nil

		case proto.RecoverySaveExit:
			fallthrough
		default:
			res.Outcome = proto.AttemptOutcomeFailureSaveExit
			res.Recovery = proto.RecoverySaveExit
			res.ErrorCategory = outcome.ErrorCategory
			res.ErrorSubcategory = outcome.ErrorSubcategory
			res.ErrorMessage = outcome.ErrorMessage
			res.CauseSummary = formatCauseSummary(outcome)
			res.Attempts = attempt
			res.AgentCalls = agentCalls
			res.ElapsedSecs = int64(l.now().Sub(start).Seconds())
			res.TotalTurns = totalTurns
			return res, nil
		}
	}
}

// applyRequestOverrides folds per-request bounds onto the loop's defaults so
// the bash front-end can override pipeline.conf values without mutating the
// Loop struct.
func (l *Loop) applyRequestOverrides(req *proto.AttemptRequestV1) Config {
	cfg := l.cfg
	if req.MaxPipelineAttempts > 0 {
		cfg.MaxPipelineAttempts = req.MaxPipelineAttempts
	}
	if req.AutonomousTimeoutSecs > 0 {
		cfg.AutonomousTimeoutSecs = req.AutonomousTimeoutSecs
	}
	if req.MaxAutonomousAgentCalls > 0 {
		cfg.MaxAutonomousAgentCalls = req.MaxAutonomousAgentCalls
	}
	return cfg
}

// markGuard records persistent retry guards that survive across iterations.
// Mirrors _ORCH_ENV_GATE_RETRIED / _ORCH_MIXED_BUILD_RETRIED in
// lib/orchestrate_cause.sh — the retry-once contract relies on
// these surviving from one iteration to the next within the same RunAttempt.
func (l *Loop) markGuard(decision string) {
	switch decision {
	case proto.RecoveryRetryUIGateEnv:
		l.envGateRetried = true
	case proto.RecoveryRetryCoderBuild:
		// Only mark mixed-build guard when classifier is mixed_uncertain.
		// (The non-mixed branches always retry without the guard.)
		// The Classify call site has already validated the guard was clear
		// before returning RetryCoderBuild on a mixed_uncertain class.
		l.mixedBuildRetried = true
	}
}

// formatCauseSummary builds the M129 "primary; secondary" cause string the
// bash _save_orchestration_state caller appends to PIPELINE_STATE notes.
func formatCauseSummary(o StageOutcome) string {
	if o.PrimaryCat == "" && o.SecondaryCat == "" {
		return ""
	}
	if o.PrimaryCat != "" {
		s := o.PrimaryCat + "/" + o.PrimarySub
		if o.PrimarySignal != "" {
			s += " (" + o.PrimarySignal + ")"
		}
		if o.SecondaryCat != "" {
			s += "; secondary: " + o.SecondaryCat + "/" + o.SecondarySub
		}
		return s
	}
	return o.SecondaryCat + "/" + o.SecondarySub
}
