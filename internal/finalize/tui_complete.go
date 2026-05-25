package finalize

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/geoffgodwin/tekhton/internal/tui"
)

// TUIComplete is the Go body of _hook_tui_complete. The bash hook
// (lib/finalize_dashboard_hooks.sh::_hook_tui_complete) closed the wrap-up
// pill and emitted a summary event. Pure Go because the TUI status writer
// is Go-owned post-m23.
//
// The hook does NOT tear down the sidecar process — that's the parent
// shell's EXIT trap's job. This hook only signals the status file so the
// sidecar's renderer can transition to its hold-on-complete state.
type TUIComplete struct {
	// StatusFile overrides the default tui_status.json location. Defaults
	// to $TEKHTON_SESSION_DIR/tui_status.json, then /tmp/tui_status.json.
	StatusFile string
}

// Name implements Hook.
func (h *TUIComplete) Name() string { return "_hook_tui_complete" }

// Run records the wrap-up stage end and appends a summary event reporting
// the run verdict. Tolerant of a missing status file (sidecar may not have
// been activated for this run).
func (h *TUIComplete) Run(_ context.Context, in *Input) error {
	path := h.StatusFile
	if path == "" {
		if v := os.Getenv("TEKHTON_SESSION_DIR"); v != "" {
			path = v + "/tui_status.json"
		} else {
			path = "/tmp/tui_status.json"
		}
	}
	st, err := tui.Load(path)
	if err != nil {
		if errors.Is(err, tui.ErrNotFound) {
			return nil // sidecar inactive — nothing to signal
		}
		return fmt.Errorf("tui_complete: load: %w", err)
	}
	verdict := "SUCCESS"
	if in.ExitCode != 0 {
		verdict = "FAIL"
	}
	now := time.Now()
	// Close wrap-up pill (matches bash _hook_tui_complete:tui_stage_end).
	st.StageEnd(tui.StageEndInput{Label: "wrap-up", Verdict: verdict}, now)

	level := "success"
	if verdict != "SUCCESS" {
		level = "error"
	}
	st.AppendEvent(level, "Pass complete: "+verdict, "summary", "", now, 0)
	return st.SaveAtomic(path)
}
