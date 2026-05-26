package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDriftCmd_Hidden(t *testing.T) {
	c := newDriftCmd()
	if !c.Hidden {
		t.Error("drift command should be Hidden")
	}
	for _, sub := range []string{"observe", "resolve", "list", "prune", "audit-status"} {
		found := false
		for _, x := range c.Commands() {
			if x.Use == sub || strings.HasPrefix(x.Use, sub+" ") {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("drift subcommand %q missing", sub)
		}
	}
}

func TestDriftCmd_Help_AllSubcommands(t *testing.T) {
	// Acceptance criterion: each `tekhton drift <sub> --help` exits 0.
	c := newDriftCmd()
	for _, sub := range c.Commands() {
		sub := sub
		t.Run(sub.Use, func(t *testing.T) {
			sub.SetArgs([]string{"--help"})
			if err := sub.Execute(); err != nil {
				t.Errorf("%s --help: %v", sub.Use, err)
			}
		})
	}
}

func TestDriftObserve_AppendsToLog(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DRIFT_LOG_FILE", "")
	root := newRootCmd()
	root.SetArgs([]string{
		"drift", "observe",
		"--project-dir", dir,
		"--tag", "test-task",
		"--detail", "an observation body",
	})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join(dir, "DRIFT_LOG.md"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "an observation body") {
		t.Errorf("observation not appended:\n%s", body)
	}
}

func TestDriftList_OpenAndResolved(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DRIFT_LOG_FILE", "")
	// Seed two observations and resolve one.
	root := newRootCmd()
	root.SetArgs([]string{"drift", "observe", "--project-dir", dir, "--detail", "alpha"})
	_ = root.Execute()
	root = newRootCmd()
	root.SetArgs([]string{"drift", "observe", "--project-dir", dir, "--detail", "beta"})
	_ = root.Execute()
	root = newRootCmd()
	root.SetArgs([]string{"drift", "resolve", "--project-dir", dir, "alpha"})
	_ = root.Execute()

	// Open should list beta only.
	root = newRootCmd()
	out := &bytes.Buffer{}
	root.SetOut(out)
	root.SetArgs([]string{"drift", "list", "--project-dir", dir, "--state", "open"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "beta") {
		t.Errorf("open list missing beta:\n%s", out)
	}
	if strings.Contains(out.String(), "alpha") {
		t.Errorf("open list should not contain alpha:\n%s", out)
	}

	// Resolved should list alpha.
	root = newRootCmd()
	out = &bytes.Buffer{}
	root.SetOut(out)
	root.SetArgs([]string{"drift", "list", "--project-dir", dir, "--state", "resolved"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "alpha") {
		t.Errorf("resolved list missing alpha:\n%s", out)
	}
}

func TestDriftAuditStatus_JSONOutput(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DRIFT_LOG_FILE", "")
	// Seed the log so the counter has a known shape.
	root := newRootCmd()
	root.SetArgs([]string{"drift", "observe", "--project-dir", dir, "--detail", "x"})
	_ = root.Execute()

	root = newRootCmd()
	out := &bytes.Buffer{}
	root.SetOut(out)
	root.SetArgs([]string{"drift", "audit-status", "--project-dir", dir, "--obs-threshold", "1"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	body := out.String()
	if !strings.Contains(body, `"should_trigger_audit": true`) {
		t.Errorf("expected should_trigger_audit=true, got:\n%s", body)
	}
}
