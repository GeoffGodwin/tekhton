package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestCausalInitCmd_CreatesFile verifies that `tekhton causal init --path P`
// creates parent directories and touches the log file when it does not exist.
func TestCausalInitCmd_CreatesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".claude", "logs", "CAUSAL_LOG.jsonl")

	cmd := newCausalInitCmd()
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("causal init: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Errorf("log file not created after init: %v", err)
	}
}

// TestCausalInitCmd_NoTruncate verifies that re-running init on an existing
// log does not truncate its contents — the resume-friendly semantics required
// by the bash shim's init_causal_log no-op contract.
func TestCausalInitCmd_NoTruncate(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "CAUSAL_LOG.jsonl")

	prior := `{"proto":"tekhton.causal.v1","id":"coder.001","ts":"2026-01-01T00:00:00Z"}` + "\n"
	if err := os.WriteFile(path, []byte(prior), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	cmd := newCausalInitCmd()
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("causal init on existing log: %v", err)
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read after init: %v", err)
	}
	if string(got) != prior {
		t.Errorf("init truncated existing log:\n  got:  %q\n  want: %q", string(got), prior)
	}
}

// TestCausalInitCmd_MissingPath verifies that omitting --path returns a typed
// error rather than silently succeeding or panicking.
func TestCausalInitCmd_MissingPath(t *testing.T) {
	cmd := newCausalInitCmd()
	cmd.SetArgs([]string{})
	if err := cmd.Execute(); err == nil {
		t.Error("expected error when --path is omitted; got nil")
	}
}

// TestCausalInitCmd_CreatesRunsSubdir verifies that init also creates the
// runs/ archive directory alongside the log, matching Open()'s semantics so
// archive_causal_log never fails on a fresh install.
func TestCausalInitCmd_CreatesRunsSubdir(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "logs", "CAUSAL_LOG.jsonl")

	cmd := newCausalInitCmd()
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("causal init: %v", err)
	}

	runsDir := filepath.Join(dir, "logs", "runs")
	if _, err := os.Stat(runsDir); err != nil {
		t.Errorf("runs/ subdir not created by init: %v", err)
	}
}
