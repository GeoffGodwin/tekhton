package proto

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Stage envelopes (m18). stage.request.v1 is the input the Go runner hands a
// bash stage subprocess; stage.result.v1 is the structured outcome the stage
// emits before exiting. The envelope is intentionally narrower than
// agent.response.v1 (m05): a stage is many agent calls + many bash actions, so
// the envelope captures *outcomes*, not the per-agent trace (CAUSAL_LOG.jsonl
// already owns that).

// StageRequestProtoV1 is the proto envelope tag for a stage-run request.
const StageRequestProtoV1 = "tekhton.stage.request.v1"

// StageResultProtoV1 is the proto envelope tag for a stage-run result.
const StageResultProtoV1 = "tekhton.stage.result.v1"

// Stage names recognized by the runner.
const (
	StageIntake   = "intake"
	StageCoder    = "coder"
	StageSecurity = "security"
	StageReview   = "review"
	StageTester   = "tester"
	StageCleanup  = "cleanup"
	StageDocs     = "docs"
)

// Stage verdicts. The bash stage tail blocks emit one of these strings via
// `tekhton stage emit --verdict ...`.
const (
	VerdictPass   = "pass"   // stage finished, downstream may proceed
	VerdictFail   = "fail"   // stage finished but its work failed (build broken, tests red)
	VerdictRework = "rework" // reviewer asked for another coder pass
	VerdictBlock  = "block"  // hard stop (security HIGH severity, intake reject)
	VerdictSkip   = "skip"   // optional stage skipped per config
)

// StageRequestV1 is the input envelope for a single stage run.
//
// The Go runner writes this to a temp file and passes the path via
// TEKHTON_STAGE_REQUEST_FILE. A stage may read it for richer context
// (review-cycle counter, build-attempt counter) but most stages today derive
// these from environment variables; the request file is the long-form contract.
type StageRequestV1 struct {
	Proto        string            `json:"proto"`
	Stage        string            `json:"stage"`
	Task         string            `json:"task"`
	Milestone    string            `json:"milestone,omitempty"`
	ReviewCycle  int               `json:"review_cycle"`
	BuildAttempt int               `json:"build_attempt"` // for coder reruns under build-gate retry
	EnvOverrides map[string]string `json:"env_overrides,omitempty"`
	ResultFile   string            `json:"result_file"` // path the stage writes to
	LogFile      string            `json:"log_file,omitempty"`
}

// StageResultV1 is the disposition envelope a stage writes before it exits.
//
// FilesTouched is best-effort — the bash side typically populates it from
// `git status --porcelain` after the stage agent runs. Empty is acceptable.
//
// NextAction is a stage-specific hint:
//   - review: "rework" | "approve"
//   - tester: "fix" | "pass"
//   - intake: "reject" | "accept" | "tweak"
//   - other stages: empty
type StageResultV1 struct {
	Proto        string   `json:"proto"`
	Stage        string   `json:"stage"`
	Verdict      string   `json:"verdict"`
	ExitReason   string   `json:"exit_reason"`
	AgentCalls   int      `json:"agent_calls"`
	FilesTouched []string `json:"files_touched,omitempty"`
	NextAction   string   `json:"next_action,omitempty"`
	DurationSec  int      `json:"duration_sec"`
	HumanAction  bool     `json:"human_action_required"`
	Error        string   `json:"error,omitempty"`
}

// ErrInvalidStageRequest is returned by Validate when the envelope is malformed.
var ErrInvalidStageRequest = errors.New("stage request: invalid")

// ErrInvalidStageResult is returned by Validate when the envelope is malformed.
var ErrInvalidStageResult = errors.New("stage result: invalid")

// IsKnownStage reports whether name matches one of the stage constants above.
// The Go runner uses this to gate the StageScript map lookup; bash callers
// validate via the stage tail block.
func IsKnownStage(name string) bool {
	switch name {
	case StageIntake, StageCoder, StageSecurity, StageReview, StageTester, StageCleanup, StageDocs:
		return true
	}
	return false
}

// IsKnownVerdict reports whether v matches one of the verdict constants.
func IsKnownVerdict(v string) bool {
	switch v {
	case VerdictPass, VerdictFail, VerdictRework, VerdictBlock, VerdictSkip:
		return true
	}
	return false
}

// Validate enforces the StageRequestV1 contract. It does NOT verify filesystem
// state — ResultFile / LogFile existence is the caller's responsibility.
func (r *StageRequestV1) Validate() error {
	if r == nil {
		return fmt.Errorf("%w: nil request", ErrInvalidStageRequest)
	}
	if r.Proto == "" {
		return fmt.Errorf("%w: missing proto", ErrInvalidStageRequest)
	}
	if r.Proto != StageRequestProtoV1 {
		return fmt.Errorf("%w: wrong proto %q (want %q)", ErrInvalidStageRequest, r.Proto, StageRequestProtoV1)
	}
	if r.Stage == "" {
		return fmt.Errorf("%w: missing stage", ErrInvalidStageRequest)
	}
	if !IsKnownStage(r.Stage) {
		return fmt.Errorf("%w: unknown stage %q", ErrInvalidStageRequest, r.Stage)
	}
	if r.ReviewCycle < 0 {
		return fmt.Errorf("%w: review_cycle must be >= 0", ErrInvalidStageRequest)
	}
	if r.BuildAttempt < 0 {
		return fmt.Errorf("%w: build_attempt must be >= 0", ErrInvalidStageRequest)
	}
	if r.ResultFile == "" {
		return fmt.Errorf("%w: missing result_file", ErrInvalidStageRequest)
	}
	return nil
}

// Validate enforces the StageResultV1 contract.
func (r *StageResultV1) Validate() error {
	if r == nil {
		return fmt.Errorf("%w: nil result", ErrInvalidStageResult)
	}
	if r.Proto == "" {
		return fmt.Errorf("%w: missing proto", ErrInvalidStageResult)
	}
	if r.Proto != StageResultProtoV1 {
		return fmt.Errorf("%w: wrong proto %q (want %q)", ErrInvalidStageResult, r.Proto, StageResultProtoV1)
	}
	if r.Stage == "" {
		return fmt.Errorf("%w: missing stage", ErrInvalidStageResult)
	}
	if !IsKnownStage(r.Stage) {
		return fmt.Errorf("%w: unknown stage %q", ErrInvalidStageResult, r.Stage)
	}
	if r.Verdict == "" {
		return fmt.Errorf("%w: missing verdict", ErrInvalidStageResult)
	}
	if !IsKnownVerdict(r.Verdict) {
		return fmt.Errorf("%w: unknown verdict %q", ErrInvalidStageResult, r.Verdict)
	}
	if r.AgentCalls < 0 {
		return fmt.Errorf("%w: agent_calls must be >= 0", ErrInvalidStageResult)
	}
	if r.DurationSec < 0 {
		return fmt.Errorf("%w: duration_sec must be >= 0", ErrInvalidStageResult)
	}
	return nil
}

// EnsureProto stamps the envelope tag on a request built field-by-field.
func (r *StageRequestV1) EnsureProto() {
	if r.Proto == "" {
		r.Proto = StageRequestProtoV1
	}
}

// EnsureProto stamps the envelope tag on a result built field-by-field.
func (r *StageResultV1) EnsureProto() {
	if r.Proto == "" {
		r.Proto = StageResultProtoV1
	}
}

// MarshalIndented produces a stable JSON encoding for stdout / golden fixtures.
func (r *StageRequestV1) MarshalIndented() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}

// MarshalIndented on the result side is symmetric.
func (r *StageResultV1) MarshalIndented() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}
