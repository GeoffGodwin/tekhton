package proto

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Orchestration envelopes (m12). attempt.request.v1 is the input to a single
// pipeline attempt driven by `internal/orchestrate.Loop.RunAttempt`;
// attempt.result.v1 is the structured result the orchestrator emits back
// (success outcome, recovery class on failure, accumulated counters).
//
// The bash orchestrator's RUN_SUMMARY.json is the V3 source of truth for the
// shape of an attempt result. Field names below are chosen to match that file
// modulo lowercase/snake_case where V3 used CamelCase; the parity check at
// scripts/orchestrate-parity-check.sh asserts the two stay in lock-step.

// AttemptRequestProtoV1 is the proto envelope tag for a run-attempt request.
const AttemptRequestProtoV1 = "tekhton.attempt.request.v1"

// AttemptResultProtoV1 is the proto envelope tag for a run-attempt result.
const AttemptResultProtoV1 = "tekhton.attempt.result.v1"

// RecoveryClass enumerates the recovery actions the loop returns when an
// attempt fails. Mirrors `_classify_failure` in
// lib/orchestrate_classify.sh:121 — keep the string vocabulary in sync so
// the bash shim and the Go owner agree byte-for-byte.
const (
	RecoverySaveExit         = "save_exit"
	RecoverySplit            = "split"
	RecoveryBumpReview       = "bump_review"
	RecoveryRetryCoderBuild  = "retry_coder_build"
	RecoveryRetryUIGateEnv   = "retry_ui_gate_env"
	RecoveryEscalateTurns    = "escalate_turns"
	RecoveryNone             = "" // success path — no recovery needed
)

// AttemptOutcome enumerates the high-level outcomes of a pipeline attempt.
const (
	AttemptOutcomeSuccess         = "success"
	AttemptOutcomeFailureRetry    = "failure_retry"    // recoverable; loop will iterate
	AttemptOutcomeFailureSaveExit = "failure_save_exit" // non-recoverable; state saved
	AttemptOutcomeStuck           = "stuck"             // progress detector tripped
	AttemptOutcomeSafetyBound     = "safety_bound"      // max_attempts/timeout/agent_cap
)

// AttemptRequestV1 is the input envelope for a single pipeline attempt.
//
// The bash front-end of tekhton.sh renders the task / milestone context, then
// hands this envelope to the Go orchestrator. The orchestrator drives one or
// more iterations of the bash stage runner until success or recovery exit.
type AttemptRequestV1 struct {
	Proto              string `json:"proto"`
	RunID              string `json:"run_id,omitempty"`
	Task               string `json:"task"`
	StartAt            string `json:"start_at,omitempty"`
	Milestone          string `json:"milestone,omitempty"`
	MilestoneMode      bool   `json:"milestone_mode,omitempty"`
	ProjectDir         string `json:"project_dir"`
	LogFile            string `json:"log_file,omitempty"`

	// Safety bounds — config-driven per pipeline.conf.
	MaxPipelineAttempts     int `json:"max_pipeline_attempts,omitempty"`
	AutonomousTimeoutSecs   int `json:"autonomous_timeout_secs,omitempty"`
	MaxAutonomousAgentCalls int `json:"max_autonomous_agent_calls,omitempty"`

	// Resume state — populated when restarting from a saved PIPELINE_STATE.
	ResumeAttempt    int `json:"resume_attempt,omitempty"`
	ResumeAgentCalls int `json:"resume_agent_calls,omitempty"`
}

// AttemptResultV1 is the result envelope for a single run-attempt invocation.
//
// Counters are cumulative across iterations driven by Loop.RunAttempt. On
// success Recovery is empty and Outcome is AttemptOutcomeSuccess. On failure
// Recovery names the action the bash front-end should take (save state, re-run
// with bumped review cycles, split the milestone, etc.).
type AttemptResultV1 struct {
	Proto    string `json:"proto"`
	RunID    string `json:"run_id,omitempty"`
	Outcome  string `json:"outcome"`
	Recovery string `json:"recovery,omitempty"`

	Attempts        int   `json:"attempts"`
	AgentCalls      int   `json:"agent_calls"`
	ElapsedSecs     int64 `json:"elapsed_secs"`
	TotalTurns      int   `json:"total_turns,omitempty"`

	// Failure detail — populated only when Outcome != success.
	ErrorCategory    string `json:"error_category,omitempty"`
	ErrorSubcategory string `json:"error_subcategory,omitempty"`
	ErrorMessage     string `json:"error_message,omitempty"`
	CauseSummary     string `json:"cause_summary,omitempty"` // M129 primary/secondary cause join

	// Resume hints — populated on save_exit.
	ResumeStartAt    string `json:"resume_start_at,omitempty"`
	ResumeArtifact   string `json:"resume_artifact,omitempty"`
	ResumeFlags      string `json:"resume_flags,omitempty"`
}

// ErrInvalidAttemptRequest is returned by Validate when the envelope is
// malformed. Wrapped errors carry field-specific context.
var ErrInvalidAttemptRequest = errors.New("attempt request: invalid")

// Validate enforces the AttemptRequestV1 contract. Like AgentRequestV1.Validate
// it does NOT verify filesystem state — ProjectDir existence is the caller's
// responsibility.
func (r *AttemptRequestV1) Validate() error {
	if r == nil {
		return fmt.Errorf("%w: nil request", ErrInvalidAttemptRequest)
	}
	if r.Proto == "" {
		return fmt.Errorf("%w: missing proto", ErrInvalidAttemptRequest)
	}
	if r.Proto != AttemptRequestProtoV1 {
		return fmt.Errorf("%w: wrong proto %q (want %q)", ErrInvalidAttemptRequest, r.Proto, AttemptRequestProtoV1)
	}
	if r.Task == "" {
		return fmt.Errorf("%w: missing task", ErrInvalidAttemptRequest)
	}
	if r.ProjectDir == "" {
		return fmt.Errorf("%w: missing project_dir", ErrInvalidAttemptRequest)
	}
	if r.MaxPipelineAttempts < 0 {
		return fmt.Errorf("%w: max_pipeline_attempts must be >= 0", ErrInvalidAttemptRequest)
	}
	if r.AutonomousTimeoutSecs < 0 {
		return fmt.Errorf("%w: autonomous_timeout_secs must be >= 0", ErrInvalidAttemptRequest)
	}
	if r.MaxAutonomousAgentCalls < 0 {
		return fmt.Errorf("%w: max_autonomous_agent_calls must be >= 0", ErrInvalidAttemptRequest)
	}
	return nil
}

// EnsureProto stamps the envelope tag on a request built field-by-field.
func (r *AttemptRequestV1) EnsureProto() {
	if r.Proto == "" {
		r.Proto = AttemptRequestProtoV1
	}
}

// EnsureProto stamps the envelope tag on a result built field-by-field.
func (r *AttemptResultV1) EnsureProto() {
	if r.Proto == "" {
		r.Proto = AttemptResultProtoV1
	}
}

// MarshalIndented produces a stable JSON encoding for stdout / golden fixtures.
func (r *AttemptResultV1) MarshalIndented() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}

// MarshalIndented on the request side is symmetric with AgentRequestV1.
func (r *AttemptRequestV1) MarshalIndented() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}
