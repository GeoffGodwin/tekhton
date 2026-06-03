package cleanup

// full_flow_test.go covers the two gaps the reviewer identified in m34.2:
//
//  1. Full agent-success path — agent runs, returns a non-null result,
//     CLEANUP_REPORT.md is parsed, notes are mutated to [x]/[DEFERRED],
//     the document is saved to disk, and the stage returns verdict=pass.
//     The hand-authored parity golden (cleanup-batch-resolved) used
//     BATCH_SIZE=0 to skip agent invocation, so this path was absent.
//
//  2. subprocessBuildGate.Run when a real binary is on disk — the
//     build-gate seam was exercised only through the fakeBuildGate stub.
//     These tests drive the default subprocess implementation directly
//     using a minimal shell-script stub, keeping the test self-contained
//     (no real tekhton binary required).

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// TestRunStage_FullSuccess_ReportParsedAndSaved is the primary behavior
// test for the cleanup stage. It exercises the path where:
//   - trigger conditions are met (CLEANUP_ENABLED, enough notes)
//   - the agent is invoked and returns a non-null-run result
//   - the build gate passes
//   - CLEANUP_REPORT.md contains resolved and deferred items
//   - the notes document is mutated in-memory and saved to disk
//   - the stage returns verdict=pass with resolved/deferred counts in ExitReason
func TestRunStage_FullSuccess_ReportParsedAndSaved(t *testing.T) {
	t.Setenv("CLEANUP_ENABLED", "true")
	t.Setenv("CLEANUP_TRIGGER_THRESHOLD", "0")
	t.Setenv("CLEANUP_BATCH_SIZE", "3")

	dir, req := setupProject(t, 5)

	// Pre-write CLEANUP_REPORT.md at the default path the stage resolves
	// to (PROJECT_DIR/.tekhton/CLEANUP_REPORT.md when TEKHTON_DIR and
	// CLEANUP_REPORT_FILE are both unset). This simulates what the cleanup
	// agent would produce after addressing debt items.
	reportPath := filepath.Join(dir, ".tekhton", "CLEANUP_REPORT.md")
	report := `# Cleanup Report

## Resolved
- cleanup item 1
- cleanup item 2

## Deferred
- cleanup item 3: out of scope for this sweep

## Not Attempted
- cleanup item 4
- cleanup item 5
`
	if err := os.WriteFile(reportPath, []byte(report), 0o644); err != nil {
		t.Fatalf("write CLEANUP_REPORT.md: %v", err)
	}

	var agentCallCount int
	ag := &fakeAgent{
		OnRun: func(ctx context.Context, r *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
			agentCallCount++
			// Non-null-run: TurnsUsed > 0, ExitCode = 0.
			return &proto.AgentResultV1{
				Proto:     proto.AgentRequestProtoV1,
				Outcome:   proto.OutcomeSuccess,
				ExitCode:  0,
				TurnsUsed: 5,
			}, nil
		},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate)
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}

	// Primary observable behavior: stage passes when agent succeeds.
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict = %q, want %q", res.Verdict, proto.VerdictPass)
	}

	// ExitReason encodes the resolved/deferred counts produced by parsing
	// the structured CLEANUP_REPORT.md.
	if !strings.Contains(res.ExitReason, "resolved=2") {
		t.Errorf("ExitReason = %q, want it to contain 'resolved=2'", res.ExitReason)
	}
	if !strings.Contains(res.ExitReason, "deferred=1") {
		t.Errorf("ExitReason = %q, want it to contain 'deferred=1'", res.ExitReason)
	}

	// Agent was called exactly once.
	if agentCallCount != 1 {
		t.Errorf("agent call count = %d, want 1", agentCallCount)
	}

	// Build gate was called exactly once (post-cleanup).
	if gate.Calls != 1 {
		t.Errorf("gate.Calls = %d, want 1", gate.Calls)
	}

	// NON_BLOCKING_LOG.md was mutated and saved to disk. Load the saved
	// file and verify the state transitions produced by parseReport.
	nbPath := filepath.Join(dir, ".tekhton", "NON_BLOCKING_LOG.md")
	savedBytes, readErr := os.ReadFile(nbPath)
	if readErr != nil {
		t.Fatalf("read saved NON_BLOCKING_LOG.md: %v", readErr)
	}
	saved := string(savedBytes)

	// Two notes should have been resolved — exactly two [x] markers.
	if got := strings.Count(saved, "[x]"); got != 2 {
		t.Errorf("saved file has %d [x] markers, want 2:\n%s", got, saved)
	}
	// One note should have been deferred — exactly one [DEFERRED] marker.
	if got := strings.Count(saved, "[DEFERRED]"); got != 1 {
		t.Errorf("saved file has %d [DEFERRED] markers, want 1:\n%s", got, saved)
	}
	// Remaining notes (items 4 and 5) must still be pending.
	if got := strings.Count(saved, "[ ]"); got != 2 {
		t.Errorf("saved file has %d [ ] markers, want 2 (items 4 and 5):\n%s", got, saved)
	}
}

// fakeBinScript writes a minimal shell script that exits with the given
// code, marks it executable, and returns its path. Used to exercise
// subprocessBuildGate.Run without the real tekhton binary.
func fakeBinScript(t *testing.T, exitCode int) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "tekhton")
	content := fmt.Sprintf("#!/bin/sh\nexit %d\n", exitCode)
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatalf("write fake bin: %v", err)
	}
	return path
}

// TestSubprocessBuildGate_BinaryNotFound_ReturnsNil verifies that when
// no tekhton binary is resolvable, subprocessBuildGate.Run returns nil
// (matching the bash shim's "missing binary → warn + skip" behaviour).
func TestSubprocessBuildGate_BinaryNotFound_ReturnsNil(t *testing.T) {
	t.Setenv("TEKHTON_BIN", "")
	t.Setenv("TEKHTON_HOME", "")
	t.Setenv("PATH", "")
	gate := subprocessBuildGate{}
	if err := gate.Run(context.Background(), "", "test-label"); err != nil {
		t.Errorf("Run(binary not found) = %v, want nil", err)
	}
}

// TestSubprocessBuildGate_BinaryFoundExitsZero verifies that when the
// resolved binary exits 0 (gate passes), Run returns nil.
func TestSubprocessBuildGate_BinaryFoundExitsZero(t *testing.T) {
	bin := fakeBinScript(t, 0)
	t.Setenv("TEKHTON_BIN", bin)
	gate := subprocessBuildGate{}
	if err := gate.Run(context.Background(), "", "test-label"); err != nil {
		t.Errorf("Run(exit 0) = %v, want nil", err)
	}
}

// TestSubprocessBuildGate_BinaryFoundExitsOne verifies that when the
// resolved binary exits non-zero (gate fails), Run returns a non-nil
// error so the stage knows to warn + revert.
func TestSubprocessBuildGate_BinaryFoundExitsOne(t *testing.T) {
	bin := fakeBinScript(t, 1)
	t.Setenv("TEKHTON_BIN", bin)
	gate := subprocessBuildGate{}
	if err := gate.Run(context.Background(), "", "test-label"); err == nil {
		t.Error("Run(exit 1) = nil, want non-nil error (gate failure)")
	}
}
