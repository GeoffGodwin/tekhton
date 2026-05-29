package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDashboardCmd_HelpListsSubcommands(t *testing.T) {
	cmd := newRootCmd()
	cmd.SetArgs([]string{"dashboard", "--help"})
	var buf bytes.Buffer
	cmd.SetOut(&buf)
	cmd.SetErr(&buf)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("dashboard --help: %v\n%s", err, buf.String())
	}
	for _, want := range []string{"init", "sync", "cleanup", "emit"} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("dashboard --help missing %q sub-command\nfull output:\n%s", want, buf.String())
		}
	}
}

func TestDashboardEmit_HelpListsKinds(t *testing.T) {
	cmd := newRootCmd()
	cmd.SetArgs([]string{"dashboard", "emit", "--help"})
	var buf bytes.Buffer
	cmd.SetOut(&buf)
	cmd.SetErr(&buf)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("dashboard emit --help: %v\n%s", err, buf.String())
	}
	for _, want := range []string{"run-state", "timeline", "milestones", "security", "reports", "metrics", "health", "diagnosis", "init", "inbox", "notes"} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("dashboard emit --help missing %q kind\nfull output:\n%s", want, buf.String())
		}
	}
}

func TestDashboardInit_CreatesDataDir(t *testing.T) {
	tmp := t.TempDir()
	cmd := newRootCmd()
	cmd.SetArgs([]string{"dashboard", "init", "--project-dir", tmp})
	var buf bytes.Buffer
	cmd.SetOut(&buf)
	cmd.SetErr(&buf)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("dashboard init: %v\n%s", err, buf.String())
	}
	dataDir := filepath.Join(tmp, ".claude", "dashboard", "data")
	if _, err := os.Stat(dataDir); err != nil {
		t.Fatalf("dashboard init did not create data dir: %v", err)
	}
	// Verify the 10 seed files were planted.
	for _, name := range []string{
		"run_state.js", "timeline.js", "milestones.js", "security.js",
		"reports.js", "metrics.js", "health.js", "diagnosis.js",
		"inbox.js", "notes.js",
	} {
		path := filepath.Join(dataDir, name)
		if _, err := os.Stat(path); err != nil {
			t.Errorf("dashboard init: missing seed file %s: %v", name, err)
		}
	}
}

func TestDashboardEmitRunState_WritesValidJSON(t *testing.T) {
	tmp := t.TempDir()
	cmd := newRootCmd()
	cmd.SetArgs([]string{"dashboard", "init", "--project-dir", tmp})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("init: %v", err)
	}

	cmd = newRootCmd()
	cmd.SetArgs([]string{"dashboard", "emit", "run-state", "--project-dir", tmp})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("emit run-state: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(tmp, ".claude", "dashboard", "data", "run_state.js"))
	if err != nil {
		t.Fatalf("read run_state.js: %v", err)
	}
	if !strings.Contains(string(body), "window.TK_RUN_STATE = ") {
		t.Fatalf("run_state.js missing TK_RUN_STATE assignment: %s", body)
	}
	if !strings.Contains(string(body), `"pipeline_status":"running"`) {
		t.Fatalf("run_state.js missing pipeline_status field: %s", body)
	}
}
