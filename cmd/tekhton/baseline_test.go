package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBaselineCmd_Hidden(t *testing.T) {
	c := newBaselineCmd()
	if !c.Hidden {
		t.Error("baseline parent must be Hidden (internal tooling)")
	}
}

func TestBaselineCmd_HasFiveSubcommands(t *testing.T) {
	c := newBaselineCmd()
	got := map[string]bool{}
	for _, sub := range c.Commands() {
		got[strings.SplitN(sub.Use, " ", 2)[0]] = true
	}
	want := []string{"capture", "has", "compare", "acceptance-stuck", "get-exit-code"}
	for _, w := range want {
		if !got[w] {
			t.Errorf("missing subcommand %q; got %v", w, got)
		}
	}
}

func TestBaselineCmd_HelpForAllSubs(t *testing.T) {
	c := newBaselineCmd()
	for _, sub := range c.Commands() {
		sub := sub
		t.Run(strings.SplitN(sub.Use, " ", 2)[0], func(t *testing.T) {
			sub.SetArgs([]string{"--help"})
			if err := sub.Execute(); err != nil {
				t.Errorf("%s --help: %v", sub.Use, err)
			}
		})
	}
}

// --- has -------------------------------------------------------------

func TestBaselineHas_ExitsOneWhenMissing(t *testing.T) {
	dir := t.TempDir()
	root := newRootCmd()
	root.SetArgs([]string{"baseline", "has", "m1", "--project-dir", dir})
	err := root.Execute()
	if err == nil {
		t.Fatal("expected non-nil error for missing baseline")
	}
	var ec exitCoder
	if !errors.As(err, &ec) {
		t.Fatalf("error does not carry exit code: %v", err)
	}
	if ec.ExitCode() != 1 {
		t.Errorf("exit code = %d, want 1", ec.ExitCode())
	}
}

func TestBaselineHas_ExitsZeroWhenPresent(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".claude"), 0o755); err != nil {
		t.Fatal(err)
	}
	body := `{"run_id":"r1","timestamp":"2026-01-01T00:00:00Z","milestone":"m1","exit_code":0,"output_hash":"","failure_hash":"","failure_count":0}`
	if err := os.WriteFile(filepath.Join(dir, ".claude", "TEST_BASELINE.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	root := newRootCmd()
	root.SetArgs([]string{"baseline", "has", "m1", "--project-dir", dir})
	if err := root.Execute(); err != nil {
		t.Errorf("expected exit 0, got %v", err)
	}
}

// --- get-exit-code ---------------------------------------------------

func TestBaselineGetExitCode_EmptyWhenMissing(t *testing.T) {
	dir := t.TempDir()
	root := newRootCmd()
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetArgs([]string{"baseline", "get-exit-code", "--project-dir", dir})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(buf.String()) != "" {
		t.Errorf("got %q, want empty", buf.String())
	}
}

func TestBaselineGetExitCode_ReturnsNumberFromBaseline(t *testing.T) {
	dir := t.TempDir()
	_ = os.MkdirAll(filepath.Join(dir, ".claude"), 0o755)
	body := `{"run_id":"r1","timestamp":"2026-01-01T00:00:00Z","milestone":"m1","exit_code":7,"output_hash":"","failure_hash":"","failure_count":1}`
	_ = os.WriteFile(filepath.Join(dir, ".claude", "TEST_BASELINE.json"), []byte(body), 0o644)
	root := newRootCmd()
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetArgs([]string{"baseline", "get-exit-code", "--project-dir", dir})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(buf.String()) != "7" {
		t.Errorf("got %q, want 7", buf.String())
	}
}

// --- capture ---------------------------------------------------------

func TestBaselineCapture_NoTestCmd_SkipsCleanly(t *testing.T) {
	t.Setenv("TEST_CMD", "")
	dir := t.TempDir()
	root := newRootCmd()
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetArgs([]string{"baseline", "capture", "m1", "--project-dir", dir, "--test-cmd", ""})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), "skipped") {
		t.Errorf("output = %q, want contains 'skipped'", buf.String())
	}
}

func TestBaselineCapture_PassingCmd_WritesBaseline(t *testing.T) {
	dir := t.TempDir()
	_ = os.MkdirAll(filepath.Join(dir, ".claude"), 0o755)
	root := newRootCmd()
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetArgs([]string{
		"baseline", "capture", "m1",
		"--project-dir", dir,
		"--test-cmd", "echo ok",
		"--run-id", "r1",
	})
	if err := root.Execute(); err != nil {
		t.Fatalf("execute: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(dir, ".claude", "TEST_BASELINE.json"))
	if err != nil {
		t.Fatalf("baseline json missing: %v", err)
	}
	var raw map[string]any
	if err := json.Unmarshal(body, &raw); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if raw["milestone"] != "m1" {
		t.Errorf("milestone = %v, want m1", raw["milestone"])
	}
	if raw["run_id"] != "r1" {
		t.Errorf("run_id = %v, want r1", raw["run_id"])
	}
}

// --- compare ---------------------------------------------------------

func TestBaselineCompare_NoBaseline_PrintsInconclusive(t *testing.T) {
	dir := t.TempDir()
	tmp, err := os.CreateTemp("", "tek-current-*.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(tmp.Name())
	_, _ = tmp.WriteString("FAIL t\n")
	tmp.Close()

	root := newRootCmd()
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetArgs([]string{
		"baseline", "compare",
		"--project-dir", dir,
		"--output", tmp.Name(),
		"--exit", "1",
	})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(buf.String()) != "inconclusive" {
		t.Errorf("got %q, want inconclusive", buf.String())
	}
}

// --- acceptance-stuck (diagnostic hash output) -----------------------

func TestBaselineAcceptanceStuck_NoOutput_PrintsEmpty(t *testing.T) {
	dir := t.TempDir()
	root := newRootCmd()
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetArgs([]string{"baseline", "acceptance-stuck", "--project-dir", dir})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(buf.String()) != "" {
		t.Errorf("got %q, want empty (no saved output)", buf.String())
	}
}
