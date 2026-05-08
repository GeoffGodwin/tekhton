package tui

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// initialStatus is the minimal JSON envelope written by the Go side at
// startup so the Python sidecar has something to render before any bash mid-
// run writer has fired. The shape matches what lib/tui_helpers.sh's
// _tui_json_build_status emits — additive only, never rename, never re-type.
type initialStatus struct {
	Schema          string   `json:"schema"`
	UpdatedAt       string   `json:"updated_at"`
	PipelineStartTS int64    `json:"pipeline_start_ts"`
	RunMode         string   `json:"run_mode"`
	CLIFlags        string   `json:"cli_flags,omitempty"`
	StageOrder      []string `json:"stage_order,omitempty"`
	StagesComplete  []any    `json:"stages_complete"`
	RecentEvents    []string `json:"recent_events"`
	AgentStatus     string   `json:"agent_status"`
	AgentTurnsUsed  int      `json:"agent_turns_used"`
	AgentTurnsMax   int      `json:"agent_turns_max"`
	Complete        bool     `json:"complete"`
	Verdict         string   `json:"verdict,omitempty"`
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
	st := initialStatus{
		Schema:          "tekhton.tui.status.v1",
		UpdatedAt:       time.Now().UTC().Format(time.RFC3339),
		PipelineStartTS: time.Now().Unix(),
		RunMode:         runMode,
		StageOrder:      stageOrder,
		StagesComplete:  []any{},
		RecentEvents:    []string{},
		AgentStatus:     "idle",
	}
	return atomicWriteJSON(statusFile, st)
}

// WriteFinal flips the complete flag so the sidecar transitions to its
// hold-on-complete state. Called from the runner before Stop(holdEnter=true).
func WriteFinal(statusFile, verdict string) error {
	if statusFile == "" {
		return nil
	}
	st := initialStatus{
		Schema:         "tekhton.tui.status.v1",
		UpdatedAt:      time.Now().UTC().Format(time.RFC3339),
		StagesComplete: []any{},
		RecentEvents:   []string{},
		AgentStatus:    "complete",
		Complete:       true,
		Verdict:        verdict,
	}
	return atomicWriteJSON(statusFile, st)
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
