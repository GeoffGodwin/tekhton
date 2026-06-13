package diagnose

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// TestGitkeepInert_ReadContextNoState verifies that a project directory
// containing only .claude/logs/.gitkeep (no PIPELINE_STATE.md, no
// CAUSAL_LOG.jsonl, no RUN_SUMMARY.json, no LAST_FAILURE_CONTEXT.json)
// still returns nil from ReadContext — i.e. .gitkeep does not trigger the
// hasState=true path and no spurious diagnosis is emitted.
//
// This is the behavioral-inertness claim from the m25 milestone spec
// (Design §Goal 1, Watch For): the diagnose engine decides no-state from
// PIPELINE_STATE.md absence, never from directory emptiness.
func TestGitkeepInert_ReadContextNoState(t *testing.T) {
	// No t.Parallel: t.Setenv requires sequential execution.
	dir := t.TempDir()

	// Create only the .gitkeep file — no pipeline state files.
	logsDir := filepath.Join(dir, ".claude", "logs")
	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", logsDir, err)
	}
	if err := os.WriteFile(filepath.Join(logsDir, ".gitkeep"), []byte{}, 0o644); err != nil {
		t.Fatalf("write .gitkeep: %v", err)
	}

	// Clear any env overrides so the engine resolves paths from the temp dir.
	t.Setenv("PIPELINE_STATE_FILE", "")
	t.Setenv("CAUSAL_LOG_FILE", "")
	t.Setenv("MIGRATION_BACKUP_DIR", "")

	eng := NewEngine(nil)
	c, err := eng.ReadContext(context.Background(), &Input{ProjectDir: dir})
	if err != nil {
		t.Fatalf("ReadContext returned error: %v", err)
	}
	if c != nil {
		t.Errorf("ReadContext: want nil (no-state), got non-nil context (stage=%q)", c.Stage)
	}
}

// TestGitkeepInert_CollectAgentLogTails verifies that .gitkeep in
// .claude/logs/ is skipped by CollectAgentLogTails: the \.log$ basename
// filter excludes it, so the returned map is empty and no read error occurs.
//
// This guards the "behaviorally inert" claim: a .gitkeep file copied from
// agent_logs/ via mapFixturePath lands in .claude/logs/ and must not cause
// CollectAgentLogTails to fail or return garbage entries.
func TestGitkeepInert_CollectAgentLogTails(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()

	logsDir := filepath.Join(dir, ".claude", "logs")
	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", logsDir, err)
	}
	// Place only a .gitkeep — no .log files.
	if err := os.WriteFile(filepath.Join(logsDir, ".gitkeep"), []byte{}, 0o644); err != nil {
		t.Fatalf("write .gitkeep: %v", err)
	}

	h := &Helpers{}
	c := &Context{ProjectDir: dir}
	tails := h.CollectAgentLogTails(c)

	if len(tails) != 0 {
		t.Errorf("CollectAgentLogTails: want empty map (no .log files), got %v", tails)
	}
}

// TestGitkeepInert_CollectAgentLogTailsMixed verifies that when both a
// .gitkeep and real .log files are present, CollectAgentLogTails returns
// only the .log files and ignores .gitkeep.
func TestGitkeepInert_CollectAgentLogTailsMixed(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()

	logsDir := filepath.Join(dir, ".claude", "logs")
	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", logsDir, err)
	}

	// A real log file and a .gitkeep.
	logContent := "line1\nline2\n"
	if err := os.WriteFile(filepath.Join(logsDir, "agent_20240101.log"), []byte(logContent), 0o644); err != nil {
		t.Fatalf("write log: %v", err)
	}
	if err := os.WriteFile(filepath.Join(logsDir, ".gitkeep"), []byte{}, 0o644); err != nil {
		t.Fatalf("write .gitkeep: %v", err)
	}

	h := &Helpers{}
	c := &Context{ProjectDir: dir}
	tails := h.CollectAgentLogTails(c)

	if _, ok := tails[".gitkeep"]; ok {
		t.Error("CollectAgentLogTails: .gitkeep must not appear in result map")
	}
	if _, ok := tails["agent_20240101.log"]; !ok {
		t.Errorf("CollectAgentLogTails: real log file absent from result, got keys: %v", tails)
	}
}
