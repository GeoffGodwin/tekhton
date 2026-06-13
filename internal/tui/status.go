package tui

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// initialStatusEnvelope is the m23 envelope shape (proto/run_id/payload) that
// the Python sidecar's _read_status() promotes to the top level. Field names
// inside the payload must match TUIStatusV1Payload exactly so the renderer's
// .get("current_agent_status") / .get("recent_events") lookups succeed.
type initialStatusEnvelope struct {
	Proto           string                   `json:"proto"`
	RunID           string                   `json:"run_id"`
	UpdatedAt       string                   `json:"updated_at"`
	PipelineStartTS int64                    `json:"pipeline_start_ts"`
	Payload         proto.TUIStatusV1Payload `json:"payload"`
}

// WriteInitial seeds tui_status.json with a starting envelope so the sidecar
// renders immediately rather than blocking on first-write from a bash stage.
// Mid-run updates remain the bash side's job (lib/tui_ops.sh).
func WriteInitial(statusFile string, runMode string, stageOrder []string) error {
	if statusFile == "" {
		return nil
	}
	if dir := filepath.Dir(statusFile); dir != "" {
		_ = os.MkdirAll(dir, 0o755)
	}
	if stageOrder == nil {
		stageOrder = []string{}
	}
	env := initialStatusEnvelope{
		Proto:           proto.TUIStatusV1,
		UpdatedAt:       time.Now().UTC().Format(time.RFC3339),
		PipelineStartTS: time.Now().Unix(),
		Payload: proto.TUIStatusV1Payload{
			Version:            1,
			Attempt:            1,
			MaxAttempts:        1,
			RunMode:            runMode,
			StageOrder:         stageOrder,
			StagesComplete:     []proto.TUIStageEntry{},
			RecentEvents:       []proto.TUIEventEntry{},
			ActionItems:        []proto.TUIActionItem{},
			CurrentAgentStatus: "idle",
		},
	}
	return atomicWriteJSON(statusFile, env)
}

// WriteFinal flips the complete flag so the sidecar transitions to its
// hold-on-complete state. Called from the runner before Stop(holdEnter=true).
func WriteFinal(statusFile, verdict string) error {
	if statusFile == "" {
		return nil
	}
	verdictPtr := verdict
	env := initialStatusEnvelope{
		Proto:     proto.TUIStatusV1,
		UpdatedAt: time.Now().UTC().Format(time.RFC3339),
		Payload: proto.TUIStatusV1Payload{
			Version:            1,
			Attempt:            1,
			MaxAttempts:        1,
			StagesComplete:     []proto.TUIStageEntry{},
			RecentEvents:       []proto.TUIEventEntry{},
			ActionItems:        []proto.TUIActionItem{},
			StageOrder:         []string{},
			CurrentAgentStatus: "complete",
			Complete:           true,
			Verdict:            &verdictPtr,
		},
	}
	return atomicWriteJSON(statusFile, env)
}

// atomicWriteJSON marshals v and writes it via tmpfile + os.Rename so a
// half-written status file never reaches the sidecar reader. Mirrors the
// bash _tui_write_status atomic-write convention.
func atomicWriteJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
