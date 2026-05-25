package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
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

// TestTUIDeadSidecarEmitsWarnAndClearsEnv covers the end-to-end CLI path for
// sidecar death detection. The gap identified by the m23 reviewer: the Go unit
// test TestCheckSidecarLivenessDeadEmitsWarn covers the logic layer, but no
// test drove the CLI handler (saveWithLiveness → os.Unsetenv) and verified that
// TEKHTON_TUI_PID is unset in the calling process afterward.
//
// Because the cobra commands execute in-process (not as a real subprocess here),
// os.Unsetenv inside saveWithLiveness is visible to the test. The test also
// verifies the no-op path: once the env var is cleared, subsequent CLI calls
// skip the probe and do not emit a duplicate warn event.
func TestTUIDeadSidecarEmitsWarnAndClearsEnv(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX-only: kill(2) probe not supported on Windows")
	}
	// Obtain a definitely-dead PID by spawning a process that exits
	// immediately, then reaping it via Run().
	c := exec.Command("true")
	if err := c.Run(); err != nil {
		t.Skipf("'true' not available: %v", err)
	}
	deadPID := c.ProcessState.Pid()

	tmp := t.TempDir()
	statusFile := filepath.Join(tmp, "tui_status.json")

	// Pre-populate state with liveness_count one write away from firing the
	// probe (interval - 1 so the very next write increments to interval and
	// triggers the kill-0 check).
	st := tui.NewState()
	st.LivenessCount = tui.DefaultLivenessInterval - 1
	if err := st.SaveAtomic(statusFile); err != nil {
		t.Fatalf("seed state: %v", err)
	}

	// Point TEKHTON_TUI_PID at the dead process.
	t.Setenv("TEKHTON_TUI_PID", fmt.Sprintf("%d", deadPID))

	// Run update-agent: saveWithLiveness reads the PID, fires the probe on
	// write N=20, detects death, appends a warn event, and calls
	// os.Unsetenv("TEKHTON_TUI_PID").
	root := newRootCmd()
	root.SetArgs([]string{
		"tui", "update-agent",
		"--status-file", statusFile,
		"--turns-used", "5",
		"--turns-max", "100",
	})
	if err := root.Execute(); err != nil {
		t.Fatalf("update-agent: %v", err)
	}

	// The warn event must be present in the persisted status file.
	loaded, err := tui.Load(statusFile)
	if err != nil {
		t.Fatalf("load after dead probe: %v", err)
	}
	var foundWarn bool
	for _, ev := range loaded.Payload.RecentEvents {
		if ev.Level == "warn" && strings.Contains(ev.Msg, "sidecar") {
			foundWarn = true
			break
		}
	}
	if !foundWarn {
		t.Errorf("expected sidecar death warn event in status file; events: %+v", loaded.Payload.RecentEvents)
	}

	// TEKHTON_TUI_PID must be unset in the current process (saveWithLiveness
	// called os.Unsetenv; in-process Execute propagates the change here).
	if v := os.Getenv("TEKHTON_TUI_PID"); v != "" {
		t.Errorf("TEKHTON_TUI_PID should be unset after dead-sidecar detection; got %q", v)
	}

	// No-op path: PID is gone from env, so the next call skips the probe
	// entirely. The sidecar death warn must NOT be duplicated.
	root2 := newRootCmd()
	root2.SetArgs([]string{
		"tui", "update-agent",
		"--status-file", statusFile,
		"--turns-used", "6",
		"--turns-max", "100",
	})
	if err := root2.Execute(); err != nil {
		t.Fatalf("second update-agent: %v", err)
	}
	loaded2, err := tui.Load(statusFile)
	if err != nil {
		t.Fatalf("load after second call: %v", err)
	}
	warnCount := 0
	for _, ev := range loaded2.Payload.RecentEvents {
		if ev.Level == "warn" && strings.Contains(ev.Msg, "sidecar") {
			warnCount++
		}
	}
	if warnCount != 1 {
		t.Errorf("expected exactly 1 sidecar death warn after env cleared (no-op path), got %d", warnCount)
	}
}
