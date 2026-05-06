package proto

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Agent supervision wire format. agent.request.v1 is what bash callers feed
// into `tekhton supervise` on stdin; agent.response.v1 is what supervise prints
// on stdout. Field names, casing, and shape are part of the contract — once
// shipped, additions are allowed (additive only) but renames and re-types
// require a v2 envelope.
//
// The string vocabulary in Outcome and ErrorCategory mirrors the V3 bash
// supervisor exactly so the parity tests in m10 can compare result objects
// directly. See lib/errors.sh for the V3 source of truth (UPSTREAM,
// ENVIRONMENT, AGENT_SCOPE, PIPELINE).

// AgentRequestProtoV1 is the proto envelope tag for a supervise request.
const AgentRequestProtoV1 = "tekhton.agent.request.v1"

// AgentResultProtoV1 is the proto envelope tag for a supervise response.
const AgentResultProtoV1 = "tekhton.agent.response.v1"

// Outcome enum — all valid values for AgentResultV1.Outcome.
const (
	OutcomeSuccess         = "success"
	OutcomeTurnExhausted   = "turn_exhausted"
	OutcomeActivityTimeout = "activity_timeout"
	OutcomeTransientError  = "transient_error"
	OutcomeFatalError      = "fatal_error"
)

// AgentRequestV1 is the supervise input envelope. Required fields: Proto,
// Label, Model, PromptFile. Everything else is optional with sensible
// supervisor-side defaults (m06+ fills in the runtime semantics; m05 only
// validates the envelope shape).
type AgentRequestV1 struct {
	Proto               string            `json:"proto"`
	RunID               string            `json:"run_id,omitempty"`
	Label               string            `json:"label"`
	Model               string            `json:"model"`
	MaxTurns            int               `json:"max_turns,omitempty"`
	PromptFile          string            `json:"prompt_file"`
	WorkingDir          string            `json:"working_dir,omitempty"`
	TimeoutSecs         int               `json:"timeout_secs,omitempty"`
	ActivityTimeoutSecs int               `json:"activity_timeout_secs,omitempty"`
	EnvOverrides        map[string]string `json:"env,omitempty"`
}

// AgentResultV1 is the supervise output envelope. ExitCode mirrors the
// underlying agent process's exit so bash callers can branch on $? exactly as
// they do today; the supervisor itself uses sysexits-style codes (64/70) when
// the failure is internal to the supervisor (envelope invalid, panic, etc.).
//
// RetryAfter is additive in m08 — when an api_rate_limit / quota_exhausted
// classification is produced, the supervisor surfaces the upstream
// Retry-After header value verbatim (raw string: integer seconds OR
// HTTP-Date) so the retry envelope can drive a quota pause off it without
// re-parsing claude stderr. Empty when no Retry-After was observed.
type AgentResultV1 struct {
	Proto            string   `json:"proto"`
	RunID            string   `json:"run_id,omitempty"`
	Label            string   `json:"label,omitempty"`
	ExitCode         int      `json:"exit_code"`
	TurnsUsed        int      `json:"turns_used,omitempty"`
	DurationMs       int64    `json:"duration_ms,omitempty"`
	Outcome          string   `json:"outcome"`
	ErrorCategory    string   `json:"error_category,omitempty"`
	ErrorSubcategory string   `json:"error_subcategory,omitempty"`
	ErrorTransient   bool     `json:"error_transient,omitempty"`
	ErrorMessage     string   `json:"error_message,omitempty"`
	RetryAfter       string   `json:"retry_after,omitempty"`
	LastEventID      string   `json:"last_event_id,omitempty"`
	StdoutTail       []string `json:"stdout_tail,omitempty"`
}

// StdoutTailMaxLines bounds StdoutTail at the V3 ring-buffer width. Callers
// that fill the tail must trim to this length so a runaway agent's stdout
// can't balloon the response envelope.
const StdoutTailMaxLines = 50

// ErrInvalidRequest is returned by validation when the envelope is malformed.
// Wrapped errors carry field-specific context.
var ErrInvalidRequest = errors.New("agent request: invalid")

// Validate checks AgentRequestV1 for the contract-required fields. It does
// NOT verify file existence (PromptFile, WorkingDir) — that is the
// supervisor's job and may legitimately fail at exec time. Validation here
// is pure envelope shape.
func (r *AgentRequestV1) Validate() error {
	if r == nil {
		return fmt.Errorf("%w: nil request", ErrInvalidRequest)
	}
	if r.Proto == "" {
		return fmt.Errorf("%w: missing proto", ErrInvalidRequest)
	}
	if r.Proto != AgentRequestProtoV1 {
		return fmt.Errorf("%w: wrong proto %q (want %q)", ErrInvalidRequest, r.Proto, AgentRequestProtoV1)
	}
	if r.Label == "" {
		return fmt.Errorf("%w: missing label", ErrInvalidRequest)
	}
	if r.Model == "" {
		return fmt.Errorf("%w: missing model", ErrInvalidRequest)
	}
	if r.PromptFile == "" {
		return fmt.Errorf("%w: missing prompt_file", ErrInvalidRequest)
	}
	if r.MaxTurns < 0 {
		return fmt.Errorf("%w: max_turns must be >= 0, got %d", ErrInvalidRequest, r.MaxTurns)
	}
	if r.TimeoutSecs < 0 {
		return fmt.Errorf("%w: timeout_secs must be >= 0, got %d", ErrInvalidRequest, r.TimeoutSecs)
	}
	if r.ActivityTimeoutSecs < 0 {
		return fmt.Errorf("%w: activity_timeout_secs must be >= 0, got %d", ErrInvalidRequest, r.ActivityTimeoutSecs)
	}
	return nil
}

// EnsureProto sets the envelope tag if the caller built a request field by
// field and forgot it. Mirrors the helper on StateSnapshotV1.
func (r *AgentRequestV1) EnsureProto() {
	if r.Proto == "" {
		r.Proto = AgentRequestProtoV1
	}
}

// EnsureProto on results parallels the request side. The supervisor stamps
// this on every Run() return so callers building responses don't have to.
func (r *AgentResultV1) EnsureProto() {
	if r.Proto == "" {
		r.Proto = AgentResultProtoV1
	}
}

// MarshalIndented produces a stable, human-readable JSON encoding. The CLI
// uses this for stdout so a human stepping through `tekhton supervise` by
// hand sees a diffable response.
func (r *AgentResultV1) MarshalIndented() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}

// MarshalIndented on the request side is symmetric — used by the parity tests
// to seed golden fixtures and by callers that want to log the request shape.
func (r *AgentRequestV1) MarshalIndented() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}

// TrimStdoutTail enforces StdoutTailMaxLines on a response. The supervisor
// calls this before returning so the cap is enforced at the seam regardless
// of how the tail was filled.
func (r *AgentResultV1) TrimStdoutTail() {
	if len(r.StdoutTail) > StdoutTailMaxLines {
		r.StdoutTail = r.StdoutTail[len(r.StdoutTail)-StdoutTailMaxLines:]
	}
}
