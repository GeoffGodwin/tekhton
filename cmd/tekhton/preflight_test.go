package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPreflightCmd_HelpExitsZero verifies `tekhton preflight --help`
// (acceptance criterion: subcommand registered, Hidden, runnable).
func TestPreflightCmd_HelpExitsZero(t *testing.T) {
	cmd := newRootCmd()
	cmd.SetArgs([]string{"preflight", "--help"})
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("expected exit 0 for --help; got %v", err)
	}
	got := out.String()
	if !strings.Contains(got, "preflight") {
		t.Errorf("help output missing 'preflight'; got %q", got)
	}
}

// TestPreflightCmd_EmptyProjectExitsZero verifies the empty-project path
// — no applicable checks → no report → exit 0.
func TestPreflightCmd_EmptyProjectExitsZero(t *testing.T) {
	// Clear pipeline-config envs to avoid leakage from the dev shell.
	for _, k := range []string{"ANALYZE_CMD", "BUILD_CHECK_CMD", "TEST_CMD", "UI_TEST_CMD"} {
		t.Setenv(k, "")
	}
	tmp := t.TempDir()
	cmd := newRootCmd()
	cmd.SetArgs([]string{"preflight", "--project-dir", tmp, "--home", t.TempDir()})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("expected exit 0 for empty project; got %v", err)
	}
	report := filepath.Join(tmp, ".tekhton", "PREFLIGHT_REPORT.md")
	if _, err := os.Stat(report); !os.IsNotExist(err) {
		t.Errorf("expected no report for empty project; got stat=%v", err)
	}
}
