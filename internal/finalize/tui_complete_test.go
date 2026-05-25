package finalize

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/tui"
)

func TestTUICompleteEmitsPassEvent(t *testing.T) {
	tmp := t.TempDir()
	statusFile := filepath.Join(tmp, "tui_status.json")

	// Seed a state file so the hook has something to load.
	st := tui.NewState()
	if err := st.SaveAtomic(statusFile); err != nil {
		t.Fatalf("seed: %v", err)
	}

	h := &TUIComplete{StatusFile: statusFile}
	if name := h.Name(); name != "_hook_tui_complete" {
		t.Errorf("name: got %q", name)
	}
	if err := h.Run(context.Background(), &Input{ExitCode: 0}); err != nil {
		t.Fatalf("run success: %v", err)
	}

	loaded, err := tui.Load(statusFile)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	found := false
	for _, ev := range loaded.Payload.RecentEvents {
		if ev.Level == "success" && ev.Msg == "Pass complete: SUCCESS" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected pass-complete success event, got: %+v", loaded.Payload.RecentEvents)
	}
	if len(loaded.Payload.StagesComplete) != 1 || loaded.Payload.StagesComplete[0].Label != "wrap-up" {
		t.Errorf("expected wrap-up entry, got: %+v", loaded.Payload.StagesComplete)
	}
}

func TestTUICompleteEmitsFailEvent(t *testing.T) {
	tmp := t.TempDir()
	statusFile := filepath.Join(tmp, "tui_status.json")
	st := tui.NewState()
	_ = st.SaveAtomic(statusFile)

	h := &TUIComplete{StatusFile: statusFile}
	if err := h.Run(context.Background(), &Input{ExitCode: 1}); err != nil {
		t.Fatalf("run failure: %v", err)
	}
	loaded, _ := tui.Load(statusFile)
	for _, ev := range loaded.Payload.RecentEvents {
		if ev.Level == "error" && ev.Msg == "Pass complete: FAIL" {
			return
		}
	}
	t.Errorf("expected fail event, got: %+v", loaded.Payload.RecentEvents)
}

func TestTUICompleteSilentOnMissingFile(t *testing.T) {
	tmp := t.TempDir()
	statusFile := filepath.Join(tmp, "missing.json")

	h := &TUIComplete{StatusFile: statusFile}
	if err := h.Run(context.Background(), &Input{ExitCode: 0}); err != nil {
		t.Errorf("missing-file path should be silent, got: %v", err)
	}
}
