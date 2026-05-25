package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

func runCommitBookkeepingCmd(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	cmd := newCommitBookkeepingCmd()
	var stdout, stderr bytes.Buffer
	cmd.SetOut(&stdout)
	cmd.SetErr(&stderr)
	cmd.SetArgs(args)
	err := cmd.Execute()
	return stdout.String(), stderr.String(), err
}

// TestCommitBookkeeping_RunsAllThreeHooks is the load-bearing test: when
// invoked with a milestone that's still "todo" and a body file present, the
// subcommand must (a) flip the manifest entry to "done", (b) delete the body
// file, (c) remove MILESTONE_STATE.md. These are the three mutations that
// MUST land in the working tree BEFORE `git add -A` so the commit captures
// them — the user-visible reason this subcommand exists.
func TestCommitBookkeeping_RunsAllThreeHooks(t *testing.T) {
	dir := t.TempDir()
	milestonesDir := filepath.Join(dir, ".claude", "milestones")
	if err := os.MkdirAll(milestonesDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(milestonesDir, "MANIFEST.cfg")
	manifestBody := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m23|TUI Ops Port|todo||m23-body.md|\n"
	if err := os.WriteFile(manifestPath, []byte(manifestBody), 0o644); err != nil {
		t.Fatal(err)
	}
	bodyPath := filepath.Join(milestonesDir, "m23-body.md")
	if err := os.WriteFile(bodyPath, []byte("# m23 body\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(dir, ".claude", "MILESTONE_STATE.md")
	if err := os.WriteFile(statePath, []byte("in_progress\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	_, _, err := runCommitBookkeepingCmd(t,
		"--project-dir", dir,
		"--home", dir,
		"--milestone", "m23",
		"--milestone-mode", "true",
		"--milestone-disposition", "COMPLETE_AND_CONTINUE",
		"--exit-code", "0",
	)
	if err != nil {
		t.Fatalf("commit-bookkeeping: %v", err)
	}

	// mark_done effect: manifest entry flipped to "done".
	m, err := manifest.Load(manifestPath)
	if err != nil {
		t.Fatalf("manifest.Load: %v", err)
	}
	entry, ok := m.Get("m23")
	if !ok {
		t.Fatalf("m23 missing from manifest")
	}
	if entry.Status != "done" {
		t.Errorf("manifest status: got %q, want done", entry.Status)
	}

	// cleanup_milestone effect: body file gone.
	if _, err := os.Stat(bodyPath); !os.IsNotExist(err) {
		t.Errorf("milestone body should be deleted; stat err=%v", err)
	}

	// clear_state effect: MILESTONE_STATE.md gone.
	if _, err := os.Stat(statePath); !os.IsNotExist(err) {
		t.Errorf("MILESTONE_STATE.md should be deleted; stat err=%v", err)
	}

	// Sentinel side-effect: the subcommand writes .commit_decision so
	// the hooks' gate (shouldRunOnCompletion -> commitWasApproved) sees
	// "committed". The bash caller also writes this; the Go-side write
	// is a defensive duplicate for standalone invocations.
	sentinel := filepath.Join(dir, ".tekhton", ".commit_decision")
	got, err := os.ReadFile(sentinel)
	if err != nil {
		t.Fatalf("sentinel not written: %v", err)
	}
	if string(got) != "committed\n" {
		t.Errorf("sentinel content: got %q, want %q", string(got), "committed\n")
	}
}

// TestCommitBookkeeping_Idempotent: running twice must be a clean no-op.
// The post-fix flow expects the same hooks to also fire via the Go finalize
// chain after _hook_commit returns; if the second invocation errored,
// every successful commit would log warnings about manifest/file ops on
// already-done state.
func TestCommitBookkeeping_Idempotent(t *testing.T) {
	dir := t.TempDir()
	milestonesDir := filepath.Join(dir, ".claude", "milestones")
	if err := os.MkdirAll(milestonesDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(milestonesDir, "MANIFEST.cfg")
	manifestBody := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m23|TUI Ops Port|todo||m23-body.md|\n"
	if err := os.WriteFile(manifestPath, []byte(manifestBody), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(milestonesDir, "m23-body.md"), []byte("body"), 0o644); err != nil {
		t.Fatal(err)
	}

	args := []string{
		"--project-dir", dir,
		"--home", dir,
		"--milestone", "m23",
		"--milestone-mode", "true",
		"--milestone-disposition", "COMPLETE_AND_CONTINUE",
		"--exit-code", "0",
	}
	if _, _, err := runCommitBookkeepingCmd(t, args...); err != nil {
		t.Fatalf("first invocation: %v", err)
	}
	if _, stderr, err := runCommitBookkeepingCmd(t, args...); err != nil {
		t.Fatalf("second invocation: %v (stderr=%s)", err, stderr)
	}
}

// TestCommitBookkeeping_NonMilestoneMode: when --milestone-mode is false
// (e.g. --task or --human run), the completion gate inside each hook
// short-circuits, so the manifest is untouched.
func TestCommitBookkeeping_NonMilestoneMode(t *testing.T) {
	dir := t.TempDir()
	milestonesDir := filepath.Join(dir, ".claude", "milestones")
	if err := os.MkdirAll(milestonesDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(milestonesDir, "MANIFEST.cfg")
	manifestBody := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m23|TUI Ops Port|todo||m23-body.md|\n"
	if err := os.WriteFile(manifestPath, []byte(manifestBody), 0o644); err != nil {
		t.Fatal(err)
	}

	_, _, err := runCommitBookkeepingCmd(t,
		"--project-dir", dir,
		"--home", dir,
		"--milestone", "m23",
		"--milestone-mode", "false",
		"--exit-code", "0",
	)
	if err != nil {
		t.Fatalf("commit-bookkeeping: %v", err)
	}

	m, _ := manifest.Load(manifestPath)
	entry, _ := m.Get("m23")
	if entry.Status != "todo" {
		t.Errorf("manifest should not be mutated in non-milestone mode; got status=%q", entry.Status)
	}
}
