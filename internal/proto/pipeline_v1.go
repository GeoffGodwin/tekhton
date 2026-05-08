package proto

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Pipeline-attempt extension envelopes (m18). These extend m12's
// attempt.request.v1 / attempt.result.v1 with the per-stage breakdown the
// runner now produces. The m12 envelopes remain the canonical contract for
// the outer loop in lib/orchestrate_main.sh; the extensions below are written
// alongside (not in place of) AttemptResultV1 by the m18 runner so that
// downstream consumers can read either shape.

// PipelineAttemptRequestProtoV1 is the proto tag for the per-attempt
// request the m18 pipeline runner consumes. Distinct from
// AttemptRequestProtoV1 (m12 outer-loop request) — the runner takes the
// outer-loop request, populates per-attempt fields (review_cycle starting at 1,
// build_attempt starting at 0, an order list resolved from PIPELINE_ORDER),
// and serializes this envelope.
const PipelineAttemptRequestProtoV1 = "tekhton.pipeline.attempt.request.v1"

// PipelineAttemptResultProtoV1 is the proto tag for the per-attempt result
// emitted by the m18 runner.
const PipelineAttemptResultProtoV1 = "tekhton.pipeline.attempt.result.v1"

// PipelineAttemptRequestV1 is what the runner consumes per outer-loop iteration.
//
// Order names the stages to schedule, in execution order, derived from
// PIPELINE_ORDER (standard | test_first). Stages absent from Order are not
// run regardless of config.
type PipelineAttemptRequestV1 struct {
	Proto     string `json:"proto"`
	Task      string `json:"task"`
	Milestone string `json:"milestone,omitempty"`

	// Resolved stage schedule for this attempt. Coder runs first under
	// "standard"; tester runs first under "test_first".
	Order []string `json:"order"`

	// Cycle counters seeded by the outer loop.
	ReviewCycle  int `json:"review_cycle"`  // starts at 1
	BuildAttempt int `json:"build_attempt"` // starts at 0

	// Limits. Zero means use the runner default.
	MaxReviewCycles int `json:"max_review_cycles,omitempty"`
	MaxBuildRetries int `json:"max_build_retries,omitempty"`

	// Per-stage env overrides keyed by stage name. Each map is forwarded to
	// the bash subprocess via the BashAdapter at stage launch time.
	StageEnv map[string]map[string]string `json:"stage_env,omitempty"`

	// Artifact paths.
	LogDir     string `json:"log_dir,omitempty"`
	ResultDir  string `json:"result_dir,omitempty"`
	ProjectDir string `json:"project_dir"`
}

// StageBreakdown captures one stage's contribution to a pipeline attempt.
type StageBreakdown struct {
	Stage       string `json:"stage"`
	Verdict     string `json:"verdict"`
	ExitReason  string `json:"exit_reason,omitempty"`
	AgentCalls  int    `json:"agent_calls"`
	DurationSec int    `json:"duration_sec"`
	NextAction  string `json:"next_action,omitempty"`

	// Cycle counters at the time the stage ran. Useful for understanding
	// why a stage appears multiple times in the breakdown (review reworks).
	ReviewCycle  int `json:"review_cycle,omitempty"`
	BuildAttempt int `json:"build_attempt,omitempty"`
}

// PipelineAttemptResultV1 is the per-attempt result the runner emits.
//
// Outcome uses the same vocabulary as AttemptResultV1 (success | failure_*).
// Stages is the ordered breakdown — review reworks appear as multiple
// "review" entries; build-gate retries appear as multiple "coder" entries.
type PipelineAttemptResultV1 struct {
	Proto       string           `json:"proto"`
	Outcome     string           `json:"outcome"`
	Verdict     string           `json:"verdict"`
	Stages      []StageBreakdown `json:"stages"`
	AgentCalls  int              `json:"agent_calls"`
	DurationSec int              `json:"duration_sec"`

	// Failure detail.
	BlockingStage string `json:"blocking_stage,omitempty"`
	Error         string `json:"error,omitempty"`
}

// ErrInvalidPipelineRequest is returned by Validate when the envelope is malformed.
var ErrInvalidPipelineRequest = errors.New("pipeline attempt request: invalid")

// Validate enforces the PipelineAttemptRequestV1 contract.
func (r *PipelineAttemptRequestV1) Validate() error {
	if r == nil {
		return fmt.Errorf("%w: nil request", ErrInvalidPipelineRequest)
	}
	if r.Proto == "" {
		return fmt.Errorf("%w: missing proto", ErrInvalidPipelineRequest)
	}
	if r.Proto != PipelineAttemptRequestProtoV1 {
		return fmt.Errorf("%w: wrong proto %q (want %q)", ErrInvalidPipelineRequest, r.Proto, PipelineAttemptRequestProtoV1)
	}
	if len(r.Order) == 0 {
		return fmt.Errorf("%w: empty stage order", ErrInvalidPipelineRequest)
	}
	for i, s := range r.Order {
		if !IsKnownStage(s) {
			return fmt.Errorf("%w: order[%d]=%q is not a known stage", ErrInvalidPipelineRequest, i, s)
		}
	}
	if r.ReviewCycle < 0 {
		return fmt.Errorf("%w: review_cycle must be >= 0", ErrInvalidPipelineRequest)
	}
	if r.BuildAttempt < 0 {
		return fmt.Errorf("%w: build_attempt must be >= 0", ErrInvalidPipelineRequest)
	}
	if r.MaxReviewCycles < 0 {
		return fmt.Errorf("%w: max_review_cycles must be >= 0", ErrInvalidPipelineRequest)
	}
	if r.MaxBuildRetries < 0 {
		return fmt.Errorf("%w: max_build_retries must be >= 0", ErrInvalidPipelineRequest)
	}
	if r.ProjectDir == "" {
		return fmt.Errorf("%w: missing project_dir", ErrInvalidPipelineRequest)
	}
	return nil
}

// EnsureProto stamps the envelope tag on a request built field-by-field.
func (r *PipelineAttemptRequestV1) EnsureProto() {
	if r.Proto == "" {
		r.Proto = PipelineAttemptRequestProtoV1
	}
}

// EnsureProto stamps the envelope tag on a result built field-by-field.
func (r *PipelineAttemptResultV1) EnsureProto() {
	if r.Proto == "" {
		r.Proto = PipelineAttemptResultProtoV1
	}
}

// MarshalIndented produces a stable JSON encoding for stdout / golden fixtures.
func (r *PipelineAttemptRequestV1) MarshalIndented() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}

// MarshalIndented on the result side is symmetric.
func (r *PipelineAttemptResultV1) MarshalIndented() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}
