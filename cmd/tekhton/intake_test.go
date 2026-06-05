package main

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestIntakeCmd_Hidden asserts the parent and every subcommand is Hidden —
// the m36.2 transition shim is not an operator-facing surface.
func TestIntakeCmd_Hidden(t *testing.T) {
	c := newIntakeCmd()
	if !c.Hidden {
		t.Errorf("tekhton intake parent should be Hidden")
	}
	for _, sub := range c.Commands() {
		if !sub.Hidden {
			t.Errorf("tekhton intake %s should be Hidden", sub.Use)
		}
		for _, leaf := range sub.Commands() {
			if !leaf.Hidden {
				t.Errorf("tekhton intake %s %s should be Hidden", sub.Use, leaf.Use)
			}
		}
	}
}

// TestIntakeCmd_ParseVerdict runs the built binary against each fixture and
// asserts the printed verdict matches.
func TestIntakeCmd_ParseVerdict(t *testing.T) {
	bin := buildTekhtonBinary(t)
	cases := map[string]string{
		filepath.Join("..", "..", "internal", "intake", "testdata", "report_pass.md"):          "PASS",
		filepath.Join("..", "..", "internal", "intake", "testdata", "report_tweaked.md"):       "TWEAKED",
		filepath.Join("..", "..", "internal", "intake", "testdata", "report_split.md"):         "SPLIT_RECOMMENDED",
		filepath.Join("..", "..", "internal", "intake", "testdata", "report_needs_clarity.md"): "NEEDS_CLARITY",
	}
	for fixture, want := range cases {
		out, err := exec.Command(bin, "intake", "helpers", "parse-verdict", "--report", fixture).Output()
		if err != nil {
			t.Errorf("parse-verdict %s: %v", fixture, err)
			continue
		}
		got := strings.TrimSpace(string(out))
		if got != want {
			t.Errorf("parse-verdict %s = %q, want %q", fixture, got, want)
		}
	}
}

// TestIntakeCmd_ContentHash drives `content-hash` via stdin.
func TestIntakeCmd_ContentHash(t *testing.T) {
	bin := buildTekhtonBinary(t)
	cmd := exec.Command(bin, "intake", "helpers", "content-hash")
	cmd.Stdin = strings.NewReader("hello world")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("content-hash: %v", err)
	}
	got := strings.TrimSpace(string(out))
	want := "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
	if got != want {
		t.Errorf("content-hash = %q, want %q", got, want)
	}
}

// TestIntakeCmd_ParseConfidence asserts numeric parsing.
func TestIntakeCmd_ParseConfidence(t *testing.T) {
	bin := buildTekhtonBinary(t)
	fixture := filepath.Join("..", "..", "internal", "intake", "testdata", "report_pass.md")
	out, err := exec.Command(bin, "intake", "helpers", "parse-confidence", "--report", fixture).Output()
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(out)); got != "95" {
		t.Errorf("parse-confidence = %q, want 95", got)
	}
}

// TestIntakeCmd_ShouldSkipExitCode asserts the bash-friendly exit code
// contract: 0 when hash matches, 1 otherwise.
func TestIntakeCmd_ShouldSkipExitCode(t *testing.T) {
	bin := buildTekhtonBinary(t)
	session := t.TempDir()
	// Save first.
	saveCmd := exec.Command(bin, "intake", "helpers", "save-hash", "--hash", "abc123")
	saveCmd.Env = append(saveCmd.Env, "TEKHTON_SESSION_DIR="+session)
	if out, err := saveCmd.CombinedOutput(); err != nil {
		t.Fatalf("save-hash: %v\n%s", err, out)
	}
	// Matching hash → exit 0.
	matchCmd := exec.Command(bin, "intake", "helpers", "should-skip", "--hash", "abc123")
	matchCmd.Env = append(matchCmd.Env, "TEKHTON_SESSION_DIR="+session)
	if err := matchCmd.Run(); err != nil {
		t.Errorf("should-skip on match: expected exit 0, got %v", err)
	}
	// Mismatched hash → exit 1.
	missCmd := exec.Command(bin, "intake", "helpers", "should-skip", "--hash", "different")
	missCmd.Env = append(missCmd.Env, "TEKHTON_SESSION_DIR="+session)
	err := missCmd.Run()
	if err == nil {
		t.Errorf("should-skip on mismatch: expected non-zero exit")
	}
}
