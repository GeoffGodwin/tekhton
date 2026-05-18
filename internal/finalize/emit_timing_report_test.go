package finalize

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestEmitTimingReport_NoSidecarSkipsEmission(t *testing.T) {
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	h := &EmitTimingReport{}
	in := &Input{
		ProjectDir: dir,
		LogDir:     logDir,
		Result:     &proto.RunResultV1{ElapsedSecs: 42, AgentCalls: 3},
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("Run: %v", err)
	}
	// No sidecar means no report — matches bash empty-array short-circuit.
	if _, err := os.Stat(filepath.Join(logDir, "TIMING_REPORT.md")); !os.IsNotExist(err) {
		t.Errorf("expected no TIMING_REPORT.md; got err=%v", err)
	}
}

func TestEmitTimingReport_WritesReportFromSidecar(t *testing.T) {
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		t.Fatal(err)
	}
	sidecar := phaseTimingsSidecar{
		Phases: map[string]int{
			"coder_agent":    100,
			"reviewer_agent": 40,
			"build_gate":     10,
		},
		Total:      150,
		AgentCalls: 8,
		MaxCalls:   20,
		Timestamp:  "20260518_120000",
	}
	data, err := json.Marshal(&sidecar)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(logDir, "PHASE_TIMINGS.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
	h := &EmitTimingReport{}
	in := &Input{
		ProjectDir: dir,
		LogDir:     logDir,
		Result:     &proto.RunResultV1{},
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("Run: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(logDir, "TIMING_REPORT.md"))
	if err != nil {
		t.Fatalf("read report: %v", err)
	}
	got := string(body)
	want := []string{
		"## Timing Report — run_20260518_120000",
		"| Phase | Duration | % of Total |",
		"Coder (agent)",
		"Reviewer (agent)",
		"Build gate",
		"Total wall time:",
		"Agent calls: 8 (of 20 max)",
	}
	for _, s := range want {
		if !strings.Contains(got, s) {
			t.Errorf("expected report to contain %q; got:\n%s", s, got)
		}
	}
	// Coder agent (100/150 = 66%) should sort first in descending order.
	coderIdx := strings.Index(got, "Coder (agent)")
	reviewerIdx := strings.Index(got, "Reviewer (agent)")
	if coderIdx > reviewerIdx {
		t.Errorf("expected phases sorted descending by duration")
	}
}

func TestEmitTimingReport_EmptyPhasesSkips(t *testing.T) {
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(&phaseTimingsSidecar{Phases: map[string]int{}})
	if err := os.WriteFile(filepath.Join(logDir, "PHASE_TIMINGS.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
	h := &EmitTimingReport{}
	in := &Input{ProjectDir: dir, LogDir: logDir, Result: &proto.RunResultV1{}}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, err := os.Stat(filepath.Join(logDir, "TIMING_REPORT.md")); !os.IsNotExist(err) {
		t.Errorf("expected no TIMING_REPORT.md for empty phases; got err=%v", err)
	}
}

func TestFormatDurationHuman(t *testing.T) {
	cases := map[int]string{
		0:    "0s",
		45:   "45s",
		60:   "1m",
		90:   "1m 30s",
		3600: "1h",
		3700: "1h 1m",
	}
	for in, want := range cases {
		if got := formatDurationHuman(in); got != want {
			t.Errorf("formatDurationHuman(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestPhaseDisplayName(t *testing.T) {
	cases := map[string]string{
		"coder_agent":    "Coder (agent)",
		"build_gate":     "Build gate",
		"unknown_phase":  "unknown_phase",
		"finalization":   "Finalization",
	}
	for in, want := range cases {
		if got := phaseDisplayName(in); got != want {
			t.Errorf("phaseDisplayName(%q) = %q, want %q", in, got, want)
		}
	}
}
