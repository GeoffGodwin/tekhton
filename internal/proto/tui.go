package proto

import (
	"encoding/json"
	"errors"
	"fmt"
)

// TUI status envelopes (m23). The Python sidecar (tools/tui.py) polls a JSON
// file emitted by the supervisor on every state mutation. Before m23 the
// status file was a bare payload (root keys: milestone, task, stage_label, …)
// emitted by lib/tui_helpers.sh::_tui_json_build_status. m23 introduces an
// outer envelope (proto + run_id + payload) so the Python sidecar can detect
// proto skew and reject unknown majors per DESIGN_v4.md Risk §7. Strategy A
// (in tools/tui.py): the Python side tolerates both the legacy bare shape
// and the new envelope shape during the transition window.

// TUIStatusV1 is the proto envelope tag for tui_status.json. Stamp it on
// every status snapshot written by the Go side; the Python reader will
// accept missing/empty values as implicit v1 for backward compatibility.
const TUIStatusV1 = "tekhton.tui.status.v1"

// TUIStatusV1Envelope wraps a status snapshot with a proto tag and a run id.
// The Python sidecar's _read_status promotes payload to the top level so the
// existing renderer code path is unchanged.
type TUIStatusV1Envelope struct {
	Proto   string             `json:"proto"`
	RunID   string             `json:"run_id"`
	Payload TUIStatusV1Payload `json:"payload"`
}

// TUIStatusV1Payload is the status snapshot itself. Field set mirrors the
// pre-m23 bash _tui_json_build_status output line-for-line so the Python
// renderer accepts it without changes.
//
// IMPORTANT: new fields must be additive. Removing or re-typing an existing
// field is a proto break and requires bumping the version constant.
type TUIStatusV1Payload struct {
	Version              int                  `json:"version"`
	RunID                string               `json:"run_id"`
	Milestone            string               `json:"milestone"`
	MilestoneTitle       string               `json:"milestone_title"`
	Task                 string               `json:"task"`
	Attempt              int                  `json:"attempt"`
	MaxAttempts          int                  `json:"max_attempts"`
	StageNum             int                  `json:"stage_num"`
	StageTotal           int                  `json:"stage_total"`
	StageLabel           string               `json:"stage_label"`
	CurrentLifecycleID   string               `json:"current_lifecycle_id"`
	CurrentSubstageLabel string               `json:"current_substage_label"`
	CurrentSubstageStart int64                `json:"current_substage_start_ts"`
	AgentTurnsUsed       int                  `json:"agent_turns_used"`
	AgentTurnsMax        int                  `json:"agent_turns_max"`
	AgentElapsedSecs     int                  `json:"agent_elapsed_secs"`
	StageStartTS         int64                `json:"stage_start_ts"`
	AgentModel           string               `json:"agent_model"`
	PipelineElapsedSecs  int                  `json:"pipeline_elapsed_secs"`
	StagesComplete       []TUIStageEntry      `json:"stages_complete"`
	CurrentAgentStatus   string               `json:"current_agent_status"`
	RunMode              string               `json:"run_mode"`
	CLIFlags             string               `json:"cli_flags"`
	ProjectDir           string               `json:"project_dir"`
	StageOrder           []string             `json:"stage_order"`
	LastEvent            string               `json:"last_event"`
	RecentEvents         []TUIEventEntry      `json:"recent_events"`
	ActionItems          []TUIActionItem      `json:"action_items"`
	Verdict              *string              `json:"verdict"`
	PauseReason          string               `json:"pause_reason"`
	PauseRetryInterval   int                  `json:"pause_retry_interval"`
	PauseMaxDuration     int                  `json:"pause_max_duration"`
	PauseStartedAt       int64                `json:"pause_started_at"`
	PauseNextProbeAt     int64                `json:"pause_next_probe_at"`
	Complete             bool                 `json:"complete"`
}

// TUIStageEntry is one completed stage's record (appended to stages_complete
// by tui_finish_stage). Mirrors the bash _tui_json_stage output.
type TUIStageEntry struct {
	Label       string  `json:"label"`
	LifecycleID string  `json:"lifecycle_id"`
	Model       string  `json:"model"`
	Turns       string  `json:"turns"`
	Time        string  `json:"time"`
	Verdict     *string `json:"verdict"`
}

// TUIEventEntry is one entry in the recent-events ring buffer.
type TUIEventEntry struct {
	TS     string `json:"ts"`
	Level  string `json:"level"`
	Type   string `json:"type"`
	Source string `json:"source,omitempty"`
	Msg    string `json:"msg"`
}

// TUIActionItem mirrors the action_items array elements produced by
// _OUT_CTX[action_items]. The Go side preserves the raw shape (string-keyed
// JSON object) without prescribing its inner fields — those are owned by the
// Output Bus / dashboard subsystem and remain bash-emitted until m26.
type TUIActionItem = map[string]any

// ErrInvalidTUIStatus is returned by Validate when the envelope or payload is
// malformed.
var ErrInvalidTUIStatus = errors.New("tui status: invalid")

// EnsureProto stamps the envelope tag on a status built field-by-field.
func (e *TUIStatusV1Envelope) EnsureProto() {
	if e.Proto == "" {
		e.Proto = TUIStatusV1
	}
}

// Validate enforces the envelope contract.
func (e *TUIStatusV1Envelope) Validate() error {
	if e == nil {
		return fmt.Errorf("%w: nil envelope", ErrInvalidTUIStatus)
	}
	if e.Proto == "" {
		return fmt.Errorf("%w: missing proto", ErrInvalidTUIStatus)
	}
	if e.Proto != TUIStatusV1 {
		return fmt.Errorf("%w: wrong proto %q (want %q)", ErrInvalidTUIStatus, e.Proto, TUIStatusV1)
	}
	return nil
}

// MarshalIndented produces a stable JSON encoding for fixtures.
func (e *TUIStatusV1Envelope) MarshalIndented() ([]byte, error) {
	return json.MarshalIndent(e, "", "  ")
}
