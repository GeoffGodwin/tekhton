package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/runner"
)

func TestBuildRunRequestExactlyOne(t *testing.T) {
	tests := []struct {
		name      string
		task      string
		resume    bool
		human     bool
		milestone string
		wantMode  string
		wantErr   bool
	}{
		{"task_only", "echo hi", false, false, "", proto.RunModeTask, false},
		{"resume_only", "", true, false, "", proto.RunModeResume, false},
		{"human_only", "", false, true, "", proto.RunModeHuman, false},
		{"milestone_only", "", false, false, "m1", proto.RunModeMilestone, false},
		{"none", "", false, false, "", "", true},
		{"task_and_resume", "x", true, false, "", "", true},
		{"task_and_human", "x", false, true, "", "", true},
		{"milestone_and_human", "", false, true, "m1", "", true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req, err := buildRunRequest(
				tc.task, false, tc.resume, tc.human, "",
				tc.milestone, false, 0, false, true,
				t.TempDir(), t.TempDir(),
			)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("want error for %s; got %+v", tc.name, req)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected err: %v", err)
			}
			if req.Mode != tc.wantMode {
				t.Fatalf("want mode=%q; got %q", tc.wantMode, req.Mode)
			}
		})
	}
}

func TestBuildRunRequestRequiresTekhtonHome(t *testing.T) {
	t.Setenv("TEKHTON_HOME", "")
	_, err := buildRunRequest(
		"task", false, false, false, "", "", false, 0, false, true,
		t.TempDir(), "",
	)
	if err == nil {
		t.Fatalf("expected error for missing tekhton-home")
	}
	if !strings.Contains(err.Error(), "TEKHTON_HOME") {
		t.Fatalf("error %q missing TEKHTON_HOME hint", err.Error())
	}
}

func TestBuildRunRequestAutoAdvanceWithoutMilestone(t *testing.T) {
	_, err := buildRunRequest(
		"task", false, false, false, "", "", true, 0, false, true,
		t.TempDir(), t.TempDir(),
	)
	if err == nil {
		t.Fatalf("expected validation error: auto-advance requires milestone mode")
	}
}

func TestBuildRunRequestPropagatesFlags(t *testing.T) {
	req, err := buildRunRequest(
		"", true, false, false, "", "m9", true, 7, true, true,
		t.TempDir(), t.TempDir(),
	)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !req.Complete || !req.AutoAdvance || req.AutoAdvanceLimit != 7 || !req.DryRun || !req.NoTUI {
		t.Fatalf("flag propagation: %+v", req)
	}
}

func TestRunCommandHasFlags(t *testing.T) {
	c := newRunCmd()
	for _, name := range []string{"task", "complete", "resume", "human", "human-tag", "milestone", "auto-advance", "auto-advance-limit", "dry-run", "no-tui"} {
		if c.Flags().Lookup(name) == nil {
			t.Fatalf("flag --%s missing", name)
		}
	}
}

func TestSuggestionsFromArgs(t *testing.T) {
	cases := []struct {
		name        string
		args        []string
		autoAdvance bool
		want        []string
	}{
		{
			name:        "v3_auto_advance_syntax",
			args:        []string{"3", "M23"},
			autoAdvance: true,
			want: []string{
				"did you mean `--auto-advance-limit 3`?",
				"did you mean `--milestone M23`?",
			},
		},
		{
			name:        "bare_int_without_auto_advance_is_task",
			args:        []string{"3"},
			autoAdvance: false,
			want:        []string{"did you mean `--task \"3\"`?"},
		},
		{
			name:        "lowercase_milestone_id",
			args:        []string{"m9"},
			autoAdvance: false,
			want:        []string{"did you mean `--milestone m9`?"},
		},
		{
			name:        "free_form_task",
			args:        []string{"Add OAuth login"},
			autoAdvance: false,
			want:        []string{"did you mean `--task \"Add OAuth login\"`?"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := suggestionsFromArgs(tc.args, tc.autoAdvance)
			if len(got) != len(tc.want) {
				t.Fatalf("len got=%d want=%d (%v)", len(got), len(tc.want), got)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Errorf("[%d] got=%q want=%q", i, got[i], tc.want[i])
				}
			}
		})
	}
}

// TestNormalizeMilestoneID guards the CLI ↔ bash milestone-id form bridge.
// The bash side (lib/milestone_dag.sh:63 dag_number_to_id) keys files off
// the canonical lowercase "m<NN>" shape; without this normalization,
// `tekhton --milestone "M27"` silently passes intake because the lookup
// can't match an uppercase prefix and finds no content.
func TestNormalizeMilestoneID(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"M27", "27"},
		{"m27", "27"},
		{"27", "27"},
		{"M27.1", "27.1"},
		{"27.1", "27.1"},
		{"", ""},
		// Unknown shapes pass through (lowercased) so a future ID format
		// doesn't silently get corrupted.
		{"BAD", "bad"},
	}
	for _, tc := range cases {
		got := normalizeMilestoneID(tc.in)
		if got != tc.want {
			t.Errorf("normalizeMilestoneID(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// TestBuildRunner_EnvBuilderWired is the m26 smoke test specified in the
// milestone Files Modified table: every Runner constructed via the CLI
// path must carry a non-nil EnvBuilder so stage subprocesses and the
// finalize chain see the m26 composed env. Pre-m26 this field was
// unpopulated and the runner relied on the per-stage curation in
// buildStageEnv (commit 85b00ac); a regression that nil's out
// r.Env here would silently re-create the unbound-variable cascade.
func TestBuildRunner_EnvBuilderWired(t *testing.T) {
	projectDir := t.TempDir()
	tekhtonHome := t.TempDir()
	req := &proto.RunRequestV1{
		Proto:       proto.RunRequestProtoV1,
		Mode:        proto.RunModeMilestone,
		Milestone:   "m26",
		ProjectDir:  projectDir,
		TekhtonHome: tekhtonHome,
		NoTUI:       true,
	}
	r, cleanup, err := buildRunner(req, "", "", "")
	if err != nil {
		t.Fatalf("buildRunner: %v", err)
	}
	defer cleanup()
	if r.Env == nil {
		t.Fatal("buildRunner: r.Env is nil; m26 contract requires a non-nil EnvBuilder")
	}
	hooks, ok := r.Hooks.(*runner.BashHookRunner)
	if !ok {
		t.Fatalf("buildRunner: r.Hooks is %T, want *runner.BashHookRunner", r.Hooks)
	}
	if hooks.Env == nil {
		t.Fatal("buildRunner: BashHookRunner.Env is nil; finalize chain would fall back to legacy env")
	}
	if hooks.Env != r.Env {
		t.Error("buildRunner: BashHookRunner.Env and Runner.Env should share the same builder")
	}
}

// TestClearAutoAdvanceIterationState_RemovesSentinels is the m48 acceptance
// gate for the per-iteration sentinel reset. Plants the three commit-skip
// sentinels under .tekhton/ and asserts every one is removed.
func TestClearAutoAdvanceIterationState_RemovesSentinels(t *testing.T) {
	projectDir := t.TempDir()
	tekhtonDir := filepath.Join(projectDir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatalf("mkdir .tekhton: %v", err)
	}
	sentinels := []string{
		".final_check_result",
		".final_check_reason",
		".commit_decision",
	}
	for _, name := range sentinels {
		path := filepath.Join(tekhtonDir, name)
		if err := os.WriteFile(path, []byte("stale\n"), 0o644); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
	}

	if err := clearAutoAdvanceIterationState(projectDir); err != nil {
		t.Fatalf("clearAutoAdvanceIterationState: unexpected error: %v", err)
	}

	for _, name := range sentinels {
		path := filepath.Join(tekhtonDir, name)
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("sentinel %s still present (err=%v); reset failed", name, err)
		}
	}
}

// TestClearAutoAdvanceIterationState_GracefulOnMissing asserts the reset is
// idempotent — calling it against a directory with no sentinels must not
// error. Iteration 1 (and any iteration following a previous-iteration
// success that already cleared on its own) hits this path.
func TestClearAutoAdvanceIterationState_GracefulOnMissing(t *testing.T) {
	projectDir := t.TempDir()
	// Intentionally do not create .tekhton/ — covers the colder branch
	// where neither the directory nor the files exist.
	if err := clearAutoAdvanceIterationState(projectDir); err != nil {
		t.Fatalf("expected nil error for missing sentinels, got %v", err)
	}

	// And the warmer branch: .tekhton/ exists but contains none of the
	// sentinel files.
	tekhtonDir := filepath.Join(projectDir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatalf("mkdir .tekhton: %v", err)
	}
	if err := clearAutoAdvanceIterationState(projectDir); err != nil {
		t.Fatalf("expected nil error when .tekhton/ is empty, got %v", err)
	}

	// Empty projectDir short-circuits.
	if err := clearAutoAdvanceIterationState(""); err != nil {
		t.Fatalf("expected nil error for empty projectDir, got %v", err)
	}
}

// TestReadGitHead_ParsesHashAndSubject directly tests the readGitHead helper
// with a real git repo. Pins the hash-length invariant (40 hex chars for
// %H) and the full multi-word subject capture via SplitN(..., 2).
func TestReadGitHead_ParsesHashAndSubject(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	projectDir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		c := exec.Command("git", args...)
		c.Dir = projectDir
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	run("init", "-q")
	run("config", "user.email", "test@example.com")
	run("config", "user.name", "Test")
	run("config", "commit.gpgsign", "false")

	// Multi-word subject with a bracket token in the middle — verifies SplitN
	// captures everything after the first space as the subject.
	wantSubject := "port test_baseline subsystem [MILESTONE 38.5 ✓]"
	if err := os.WriteFile(filepath.Join(projectDir, "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatalf("write a.txt: %v", err)
	}
	run("add", "a.txt")
	run("commit", "-q", "-m", wantSubject)

	hash, subject, err := readGitHead(projectDir)
	if err != nil {
		t.Fatalf("readGitHead: unexpected error: %v", err)
	}
	if len(hash) != 40 {
		t.Errorf("hash length = %d, want 40; hash = %q", len(hash), hash)
	}
	if subject != wantSubject {
		t.Errorf("subject = %q, want %q", subject, wantSubject)
	}
}

// TestReadGitHead_ReturnsErrorNotGitRepo verifies readGitHead propagates the
// git error when the working directory is not inside any git repository.
// Works with or without git on PATH: no git → exec error; git present but
// no repo → git exits non-zero — both satisfy err != nil.
func TestReadGitHead_ReturnsErrorNotGitRepo(t *testing.T) {
	dir := t.TempDir() // /tmp/... — not a git repo
	hash, subject, err := readGitHead(dir)
	if err == nil {
		t.Fatalf("expected error for non-git directory; got hash=%q subject=%q", hash, subject)
	}
}

// TestEmitAutoAdvanceCommitBanner_HeadReadFails covers the third banner
// branch: when readGitHead fails (non-git directory), emitAutoAdvanceCommitBanner
// must emit the "HEAD read failed" line — not the success or skip banners.
// This branch is distinct from the skip branch (git succeeds, wrong prefix)
// tested by TestEmitAutoAdvanceCommitBanner_DetectsMilestoneCommit.
func TestEmitAutoAdvanceCommitBanner_HeadReadFails(t *testing.T) {
	dir := t.TempDir() // not a git repo — readGitHead will return an error
	var buf bytes.Buffer
	emitAutoAdvanceCommitBanner(&buf, dir, "m42")
	got := buf.String()
	if !strings.Contains(got, "finalize completed but HEAD read failed") {
		t.Errorf("expected HEAD-read-failed banner; got: %q", got)
	}
	if strings.Contains(got, "committed as") {
		t.Errorf("unexpected success banner in output: %q", got)
	}
	if strings.Contains(got, "finalize skipped commit") {
		t.Errorf("unexpected skip banner in output: %q", got)
	}
}

// TestClearAutoAdvanceIterationState_PartialSentinels asserts robustness when
// only some of the sentinel files exist. The two present ones must be removed;
// the absent third must not produce an error (idempotent ErrNotExist handling).
func TestClearAutoAdvanceIterationState_PartialSentinels(t *testing.T) {
	projectDir := t.TempDir()
	tekhtonDir := filepath.Join(projectDir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatalf("mkdir .tekhton: %v", err)
	}
	present := []string{".final_check_result", ".commit_decision"}
	for _, name := range present {
		if err := os.WriteFile(filepath.Join(tekhtonDir, name), []byte("stale"), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	// .final_check_reason intentionally absent — simulates a run where only
	// two of the three sentinels were written by the previous iteration.

	if err := clearAutoAdvanceIterationState(projectDir); err != nil {
		t.Fatalf("unexpected error with partial sentinels: %v", err)
	}
	for _, name := range present {
		path := filepath.Join(tekhtonDir, name)
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("sentinel %s still present after reset (err=%v)", name, err)
		}
	}
}

// TestEmitAutoAdvanceCommitBanner_DetectsMilestoneCommit drives a real git
// repo and asserts the banner correctly distinguishes a milestone commit
// (subject begins `[MILESTONE <id> ✓]`) from a generic commit. The expected
// prefix is set by lib/milestone_ops.sh::get_milestone_commit_prefix — if
// that prefix changes, this test fails red.
func TestEmitAutoAdvanceCommitBanner_DetectsMilestoneCommit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	projectDir := t.TempDir()

	gitInit := func(args ...string) {
		t.Helper()
		c := exec.Command("git", args...)
		c.Dir = projectDir
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	gitInit("init", "-q")
	gitInit("config", "user.email", "test@example.com")
	gitInit("config", "user.name", "Test")
	gitInit("config", "commit.gpgsign", "false")

	if err := os.WriteFile(filepath.Join(projectDir, "a.txt"), []byte("a\n"), 0o644); err != nil {
		t.Fatalf("write a.txt: %v", err)
	}
	gitInit("add", "a.txt")
	gitInit("commit", "-q", "-m", "[MILESTONE 38.5 ✓] port test_baseline subsystem")

	// Success-banner case: HEAD subject matches expected prefix.
	var buf bytes.Buffer
	emitAutoAdvanceCommitBanner(&buf, projectDir, "m38.5")
	got := buf.String()
	if !strings.Contains(got, "✓ m38.5 committed as") {
		t.Errorf("missing success banner in output: %q", got)
	}
	if strings.Contains(got, "finalize skipped commit") {
		t.Errorf("unexpected skip banner emitted on success path: %q", got)
	}

	// Follow-up commit with a generic subject — banner must flip to warn.
	if err := os.WriteFile(filepath.Join(projectDir, "b.txt"), []byte("b\n"), 0o644); err != nil {
		t.Fatalf("write b.txt: %v", err)
	}
	gitInit("add", "b.txt")
	gitInit("commit", "-q", "-m", "feat: changes in .tekhton/INTAKE_REPORT.md")

	buf.Reset()
	emitAutoAdvanceCommitBanner(&buf, projectDir, "m38.5")
	got = buf.String()
	if !strings.Contains(got, "⚠ m38.5 finalize skipped commit") {
		t.Errorf("missing skip banner in output: %q", got)
	}
	if strings.Contains(got, "✓ m38.5 committed as") {
		t.Errorf("unexpected success banner emitted on skip path: %q", got)
	}
}
