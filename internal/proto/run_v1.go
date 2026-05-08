package proto

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Run-level envelopes (m19). RunRequestV1 is what `tekhton run` consumes —
// the union of every flag that drives the pipeline (--task, --complete,
// --resume, --human, --milestone, --auto-advance, --dry-run, --no-tui).
// RunResultV1 is the structured run-level outcome — the bash finalize chain
// reads it via TEKHTON_RUN_RESULT_FILE so future hook ports can consume it
// without a separate contract negotiation.
//
// These extend (not replace) the m12 attempt.* and m18 pipeline.attempt.*
// envelopes. The runner writes both sets per attempt: per-attempt fields are
// the m18 PipelineAttemptResultV1; the cumulative run-level summary is the
// RunResultV1 below.

// RunRequestProtoV1 is the proto envelope tag for a `tekhton run` request.
const RunRequestProtoV1 = "tekhton.run.request.v1"

// RunResultProtoV1 is the proto envelope tag for a `tekhton run` result.
const RunResultProtoV1 = "tekhton.run.result.v1"

// Mode names. Exactly one is set on every RunRequestV1 (validated by Validate).
const (
	RunModeTask      = "task"
	RunModeHuman     = "human"
	RunModeMilestone = "milestone"
	RunModeResume    = "resume"
)

// Disposition names. Set by RunCompleteLoop and the single-attempt path on the
// RunResultV1 envelope. The bash finalize bridge reads this via
// TEKHTON_RUN_DISPOSITION so existing hook code can branch on it.
const (
	RunDispositionSuccess = "success"
	RunDispositionFailure = "failure"
	RunDispositionStuck   = "stuck"
	RunDispositionTimeout = "timeout"
	// RunDispositionAgentCap is reserved for the MAX_AUTONOMOUS_AGENT_CALLS
	// safety bound so finalize hooks can distinguish it from generic failure.
	RunDispositionAgentCap = "agent_cap"
)

// RunRequestV1 is the input envelope for `tekhton run`. The Cobra command
// builds it from CLI flags; tests build it directly.
type RunRequestV1 struct {
	Proto string `json:"proto"`

	// Mode names which run flag drove the request. Exactly one of
	// task / human / milestone / resume must be non-empty when validated.
	Mode string `json:"mode"`

	// Task is the free-form task description (--task). Optional for resume
	// mode (the resume path reads it from PIPELINE_STATE.json instead).
	Task string `json:"task,omitempty"`

	// HumanTag scopes --human note filtering when Mode == human.
	HumanTag string `json:"human_tag,omitempty"`

	// Milestone names a specific milestone id when Mode == milestone.
	Milestone string `json:"milestone,omitempty"`

	// Complete toggles the outer retry loop (--complete).
	Complete bool `json:"complete"`

	// AutoAdvance enables milestone auto-advance (--auto-advance, requires Mode == milestone).
	AutoAdvance      bool `json:"auto_advance,omitempty"`
	AutoAdvanceLimit int  `json:"auto_advance_limit,omitempty"`

	// DryRun shells out to lib/dry_run.sh for a preview without invoking agents.
	DryRun bool `json:"dry_run,omitempty"`

	// NoTUI suppresses the Python TUI sidecar even when auto-detection would
	// normally enable it.
	NoTUI bool `json:"no_tui,omitempty"`

	// Project / home discovery — usually populated from env at CLI parse time.
	ProjectDir  string `json:"project_dir"`
	TekhtonHome string `json:"tekhton_home"`

	// Safety bounds and budget overrides (mirrors lib/orchestrate_main.sh
	// reads from pipeline.conf). Zero means use the runner default.
	MaxPipelineAttempts     int `json:"max_pipeline_attempts,omitempty"`
	AutonomousTimeoutSecs   int `json:"autonomous_timeout_secs,omitempty"`
	MaxAutonomousAgentCalls int `json:"max_autonomous_agent_calls,omitempty"`
}

// RunResultV1 is the cumulative run-level outcome the runner emits. Sums
// per-attempt counters, names the disposition, and surfaces the final recovery
// class on failure. Written to disk under .tekhton/RUN_RESULT.json so the
// finalize bridge can read it from bash.
type RunResultV1 struct {
	Proto       string `json:"proto"`
	Disposition string `json:"disposition"`
	RunID       string `json:"run_id,omitempty"`

	Attempts    int   `json:"attempts"`
	AgentCalls  int   `json:"agent_calls"`
	ElapsedSecs int64 `json:"elapsed_secs"`

	// Failure detail. Empty on success.
	Recovery     string `json:"recovery,omitempty"`
	ErrorMessage string `json:"error_message,omitempty"`
	ErrorClass   string `json:"error_class,omitempty"`

	// Resume hints — populated on save_exit dispositions.
	ResumeStartAt string `json:"resume_start_at,omitempty"`
	ResumeFlags   string `json:"resume_flags,omitempty"`
}

// ErrInvalidRunRequest is returned by Validate when the envelope is malformed.
var ErrInvalidRunRequest = errors.New("run request: invalid")

// IsKnownRunMode reports whether the string is one of the four run-mode
// constants.
func IsKnownRunMode(mode string) bool {
	switch mode {
	case RunModeTask, RunModeHuman, RunModeMilestone, RunModeResume:
		return true
	}
	return false
}

// Validate enforces the RunRequestV1 contract.
func (r *RunRequestV1) Validate() error {
	if r == nil {
		return fmt.Errorf("%w: nil request", ErrInvalidRunRequest)
	}
	if r.Proto == "" {
		return fmt.Errorf("%w: missing proto", ErrInvalidRunRequest)
	}
	if r.Proto != RunRequestProtoV1 {
		return fmt.Errorf("%w: wrong proto %q (want %q)", ErrInvalidRunRequest, r.Proto, RunRequestProtoV1)
	}
	if !IsKnownRunMode(r.Mode) {
		return fmt.Errorf("%w: unknown mode %q", ErrInvalidRunRequest, r.Mode)
	}
	switch r.Mode {
	case RunModeTask:
		if r.Task == "" {
			return fmt.Errorf("%w: task mode requires non-empty task", ErrInvalidRunRequest)
		}
	case RunModeMilestone:
		if r.Milestone == "" {
			return fmt.Errorf("%w: milestone mode requires non-empty milestone", ErrInvalidRunRequest)
		}
	}
	if r.AutoAdvance && r.Mode != RunModeMilestone {
		return fmt.Errorf("%w: auto-advance requires milestone mode", ErrInvalidRunRequest)
	}
	if r.ProjectDir == "" {
		return fmt.Errorf("%w: missing project_dir", ErrInvalidRunRequest)
	}
	if r.TekhtonHome == "" {
		return fmt.Errorf("%w: missing tekhton_home", ErrInvalidRunRequest)
	}
	if r.MaxPipelineAttempts < 0 {
		return fmt.Errorf("%w: max_pipeline_attempts must be >= 0", ErrInvalidRunRequest)
	}
	if r.AutonomousTimeoutSecs < 0 {
		return fmt.Errorf("%w: autonomous_timeout_secs must be >= 0", ErrInvalidRunRequest)
	}
	if r.MaxAutonomousAgentCalls < 0 {
		return fmt.Errorf("%w: max_autonomous_agent_calls must be >= 0", ErrInvalidRunRequest)
	}
	if r.AutoAdvanceLimit < 0 {
		return fmt.Errorf("%w: auto_advance_limit must be >= 0", ErrInvalidRunRequest)
	}
	return nil
}

// EnsureProto stamps the envelope tag on a request built field-by-field.
func (r *RunRequestV1) EnsureProto() {
	if r.Proto == "" {
		r.Proto = RunRequestProtoV1
	}
}

// EnsureProto stamps the envelope tag on a result built field-by-field.
func (r *RunResultV1) EnsureProto() {
	if r.Proto == "" {
		r.Proto = RunResultProtoV1
	}
}

// MarshalIndented produces a stable JSON encoding.
func (r *RunRequestV1) MarshalIndented() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}

// MarshalIndented on the result side is symmetric.
func (r *RunResultV1) MarshalIndented() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}
