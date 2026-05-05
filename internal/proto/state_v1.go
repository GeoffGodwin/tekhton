package proto

import "encoding/json"

// StateProtoV1 is the proto envelope tag written into every snapshot file.
const StateProtoV1 = "tekhton.state.v1"

// StateSnapshotV1 mirrors the fields the pre-m03 bash heredoc wrote into
// PIPELINE_STATE.md, expressed as a JSON object so the writer can be atomic
// (tmpfile + os.Rename) and the reader can be a single Unmarshal call.
//
// Field additions are allowed within v1 — additive only, never rename, never
// remove, never re-type. Forward-compatible string-shaped state belongs in
// Extra so a future v1.x reader still understands a v1.0 file. A field gets
// promoted to first-class only on a v2 bump.
type StateSnapshotV1 struct {
	Proto           string            `json:"proto"`
	RunID           string            `json:"run_id,omitempty"`
	StartedAt       string            `json:"started_at,omitempty"`
	UpdatedAt       string            `json:"updated_at"`
	Mode            string            `json:"mode,omitempty"`
	ResumeTask      string            `json:"resume_task,omitempty"`
	ResumeFlag      string            `json:"resume_flag,omitempty"`
	ExitStage       string            `json:"exit_stage,omitempty"`
	ExitReason      string            `json:"exit_reason,omitempty"`
	Notes           string            `json:"notes,omitempty"`
	LastEventID     string            `json:"last_event_id,omitempty"`
	MilestoneID     string            `json:"milestone_id,omitempty"`
	ReviewCycle     int               `json:"review_cycle,omitempty"`
	PipelineAttempt int               `json:"pipeline_attempt,omitempty"`
	AgentCallsTotal int               `json:"agent_calls_total,omitempty"`
	Errors          []ErrorRecordV1   `json:"errors,omitempty"`
	Extra           map[string]string `json:"extra,omitempty"`
}

// ErrorRecordV1 captures the AGENT_ERROR_* classification block the bash
// heredoc wrote under "## Error Classification". One record is emitted per
// classified failure; multiple records support future multi-error runs
// without a v2 bump.
type ErrorRecordV1 struct {
	Category    string `json:"category"`
	Subcategory string `json:"subcategory,omitempty"`
	Transient   bool   `json:"transient,omitempty"`
	Recovery    string `json:"recovery,omitempty"`
	LastOutput  string `json:"last_output,omitempty"`
	Stage       string `json:"stage,omitempty"`
	Timestamp   string `json:"timestamp,omitempty"`
}

// MarshalIndented produces a stable, human-readable JSON encoding suitable
// for `tekhton state read`'s default output. Round-trip parity (AC #1)
// depends only on the unmarshalled value being equal — not on byte-level
// formatting — so we use json.MarshalIndent for diffability.
func (s *StateSnapshotV1) MarshalIndented() ([]byte, error) {
	return json.MarshalIndent(s, "", "  ")
}

// EnsureProto sets the envelope tag if missing. Used by writers that build
// snapshots field-by-field (e.g. the `state update` CLI) so the on-disk file
// is always tagged regardless of caller discipline.
func (s *StateSnapshotV1) EnsureProto() {
	if s.Proto == "" {
		s.Proto = StateProtoV1
	}
}
