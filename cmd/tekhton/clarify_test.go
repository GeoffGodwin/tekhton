package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClarifyCmd_Hidden(t *testing.T) {
	c := newClarifyCmd()
	if !c.Hidden {
		t.Error("clarify should be Hidden")
	}
}

func TestClarifyCmd_HelpSubcommandsExitZero(t *testing.T) {
	// Acceptance criterion: each `tekhton clarify <sub> --help` exits 0.
	c := newClarifyCmd()
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

func TestClarifyDetect_NoBlocking_ExitsZero(t *testing.T) {
	dir := t.TempDir()
	report := filepath.Join(dir, "REPORT.md")
	_ = os.WriteFile(report, []byte("# Report\nno clarifications here\n"), 0o644)
	root := newRootCmd()
	root.SetArgs([]string{"clarify", "detect", "--report", report})
	if err := root.Execute(); err != nil {
		t.Errorf("detect on empty report should exit 0, got %v", err)
	}
}

func TestClarifyDetect_BlockingPresent_ExitsOne(t *testing.T) {
	dir := t.TempDir()
	report := filepath.Join(dir, "REPORT.md")
	body := `## Clarification Required
- [BLOCKING] which library?
`
	_ = os.WriteFile(report, []byte(body), 0o644)
	root := newRootCmd()
	root.SetArgs([]string{"clarify", "detect", "--report", report})
	err := root.Execute()
	if err == nil {
		t.Fatal("expected non-zero exit when blocking items present")
	}
	var ec errExitCode
	if !errors.As(err, &ec) {
		t.Fatalf("expected errExitCode, got %T", err)
	}
	if ec.code != 1 {
		t.Errorf("exit code = %d, want 1", ec.code)
	}
}

func TestClarifyClear_RemovesAnsweredFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CLARIFICATIONS_FILE", "")
	path := filepath.Join(dir, "CLARIFICATIONS.md")
	_ = os.WriteFile(path, []byte("## Q: a\n**A:** done\n"), 0o644)
	root := newRootCmd()
	root.SetArgs([]string{"clarify", "clear", "--project-dir", dir})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("clarify clear should remove fully-answered file")
	}
}

func TestClarifyClear_KeepsPartiallyAnsweredFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CLARIFICATIONS_FILE", "")
	path := filepath.Join(dir, "CLARIFICATIONS.md")
	body := `## Q: a
**A:** done
## Q: b
**A:**
`
	_ = os.WriteFile(path, []byte(body), 0o644)
	root := newRootCmd()
	root.SetArgs([]string{"clarify", "clear", "--project-dir", dir})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	body2, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("partial file should not be removed")
	}
	if !strings.Contains(string(body2), "## Q: b") {
		t.Errorf("partial file lost content: %s", body2)
	}
}
