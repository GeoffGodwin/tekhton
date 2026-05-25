package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/tui"
)

// TestTUIHelpLists13Subcommands verifies that the milestone-required
// subcommand set is wired. m23 acceptance criterion #5 requires all 13
// (now 15 including reset + set-context) be present and reachable.
func TestTUIHelpListsExpectedSubcommands(t *testing.T) {
	root := newRootCmd()
	cmd, _, err := root.Find([]string{"tui"})
	if err != nil {
		t.Fatalf("find tui: %v", err)
	}
	want := []string{
		"start", "stop", "complete",
		"stage-begin", "stage-end", "update-stage", "update-agent", "append-event",
		"substage-begin", "substage-end",
		"pause-enter", "pause-update", "pause-exit",
	}
	got := map[string]bool{}
	for _, sub := range cmd.Commands() {
		got[sub.Name()] = true
	}
	for _, name := range want {
		if !got[name] {
			t.Errorf("missing subcommand %q", name)
		}
	}
}

// TestTUIStageBeginRoundTrip drives stage-begin through the CLI handler and
// asserts the state file holds the expected payload after the command runs.
func TestTUIStageBeginRoundTrip(t *testing.T) {
	tmp := t.TempDir()
	statusFile := filepath.Join(tmp, "tui_status.json")

	root := newRootCmd()
	root.SetArgs([]string{
		"tui", "stage-begin",
		"--status-file", statusFile,
		"--label", "Coder",
		"--model", "claude-opus",
	})
	if err := root.Execute(); err != nil {
		t.Fatalf("execute: %v", err)
	}

	st, err := tui.Load(statusFile)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if st.Payload.StageLabel != "Coder" {
		t.Errorf("stage_label: got %q", st.Payload.StageLabel)
	}
	if st.Payload.CurrentLifecycleID != "Coder#1" {
		t.Errorf("lifecycle id: got %q", st.Payload.CurrentLifecycleID)
	}
}

// TestTUIStartEmitsEnvelopeShape verifies the proto envelope shape lands
// on disk.
func TestTUIStartEmitsEnvelopeShape(t *testing.T) {
	tmp := t.TempDir()
	statusFile := filepath.Join(tmp, "tui_status.json")

	root := newRootCmd()
	root.SetArgs([]string{
		"tui", "start",
		"--status-file", statusFile,
		"--run-mode", "milestone",
	})
	if err := root.Execute(); err != nil {
		t.Fatalf("execute: %v", err)
	}
	data, err := os.ReadFile(statusFile)
	if err != nil {
		t.Fatalf("readback: %v", err)
	}
	if !strings.Contains(string(data), `"proto":"tekhton.tui.status.v1"`) {
		t.Errorf("expected proto envelope in output, got: %s", string(data))
	}
}
