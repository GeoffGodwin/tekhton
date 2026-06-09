package cleanup

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fakeProvider is a recording provider.Provider fake. Behavior is configurable
// per-test via the OnRun function field.
type fakeProvider struct {
	OnRun func(ctx context.Context, req *provider.Request) (*provider.Result, error)
}

func (f *fakeProvider) Name() string { return "fake-cleanup" }
func (f *fakeProvider) Tier() string { return provider.TierUnknown }

func (f *fakeProvider) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
	if f.OnRun != nil {
		return f.OnRun(ctx, req)
	}
	return &provider.Result{
		Outcome:   provider.OutcomeSuccess,
		ExitCode:  0,
		TurnsUsed: 5,
	}, nil
}

// fakeBuildGate is a recording BuildGateRunner fake. By default returns
// nil (gate passes); tests override Err to drive the failure path.
type fakeBuildGate struct {
	Err   error
	Calls int
}

func (f *fakeBuildGate) Run(ctx context.Context, projectDir, stageLabel string) error {
	f.Calls++
	return f.Err
}

// installSeams wires fakes for both seams and returns a restore func.
// Every test should defer the restore so package state doesn't leak.
func installSeams(t *testing.T, ag *fakeProvider, gate BuildGateRunner) func() {
	t.Helper()
	prevA := SetProvider(ag)
	prevG := SetBuildGateRunner(gate)
	return func() {
		SetProvider(prevA)
		SetBuildGateRunner(prevG)
	}
}

// setupProject creates a temp project dir with a NON_BLOCKING_LOG.md
// containing `count` pending notes. Returns the dir + the prepared
// StageRequest. Honors test-scoped env overrides so the cleanup stage
// resolves the right paths without process-global leakage.
func setupProject(t *testing.T, count int) (string, *proto.StageRequestV1) {
	t.Helper()
	dir := t.TempDir()
	// Initialize a git repo so `git diff` works.
	if out, err := runIn(dir, "git", "init", "-q"); err != nil {
		t.Fatalf("git init: %v: %s", err, out)
	}
	if out, err := runIn(dir, "git", "config", "user.email", "test@example.com"); err != nil {
		t.Fatalf("git config: %v: %s", err, out)
	}
	if out, err := runIn(dir, "git", "config", "user.name", "test"); err != nil {
		t.Fatalf("git config: %v: %s", err, out)
	}

	nb := []string{"## Open"}
	for i := 0; i < count; i++ {
		nb = append(nb, "- [ ] [BUG] cleanup item "+itoa(i+1))
	}
	nb = append(nb, "")
	// Honors the default NON_BLOCKING_LOG_FILE = .tekhton/NON_BLOCKING_LOG.md
	// (internal/config/defaults.go), so the stage's path resolution finds it.
	if err := os.MkdirAll(filepath.Join(dir, ".tekhton"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	nbPath := filepath.Join(dir, ".tekhton", "NON_BLOCKING_LOG.md")
	if err := os.WriteFile(nbPath, []byte(strings.Join(nb, "\n")), 0o644); err != nil {
		t.Fatalf("write NB: %v", err)
	}
	// Commit so subsequent diff calls have a clean baseline.
	if out, err := runIn(dir, "git", "add", "."); err != nil {
		t.Fatalf("git add: %v: %s", err, out)
	}
	if out, err := runIn(dir, "git", "commit", "-q", "-m", "init"); err != nil {
		t.Fatalf("git commit: %v: %s", err, out)
	}

	// Set NON_BLOCKING_LOG_FILE so the stage resolves the path under .tekhton/
	// (matches where setupProject writes the file). Without this, the default
	// "NON_BLOCKING_LOG.md" would resolve at the project root instead.
	t.Setenv("NON_BLOCKING_LOG_FILE", ".tekhton/NON_BLOCKING_LOG.md")

	req := &proto.StageRequestV1{
		Proto: proto.StageRequestProtoV1,
		Stage: proto.StageCleanup,
		EnvOverrides: map[string]string{
			"PROJECT_DIR":          dir,
			"TEKHTON_HOME":         repoRoot(t),
			"PIPELINE_STAGE_POS":   "1",
			"PIPELINE_STAGE_COUNT": "1",
		},
		ResultFile: filepath.Join(dir, "result.json"),
	}
	return dir, req
}

func runIn(dir, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// repoRoot locates the tekhton repo root by walking up from the test's
// working directory looking for go.mod. Tests use it to populate
// TEKHTON_HOME so the prompt loader can find prompts/cleanup.prompt.md.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("repo root not found")
		}
		dir = parent
	}
}

func TestRunStage_NoTrigger(t *testing.T) {
	t.Setenv("CLEANUP_ENABLED", "false")
	dir, req := setupProject(t, 10)
	_ = dir
	restore := installSeams(t, &fakeProvider{}, &fakeBuildGate{})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictSkip {
		t.Errorf("verdict = %q, want skip", res.Verdict)
	}
	if res.ExitReason != "no-trigger" {
		t.Errorf("exit_reason = %q, want no-trigger", res.ExitReason)
	}
}

func TestRunStage_BelowThreshold(t *testing.T) {
	t.Setenv("CLEANUP_ENABLED", "true")
	t.Setenv("CLEANUP_TRIGGER_THRESHOLD", "10")
	_, req := setupProject(t, 5)
	restore := installSeams(t, &fakeProvider{}, &fakeBuildGate{})
	defer restore()
	res, _ := RunStage(context.Background(), req)
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "no-trigger" {
		t.Errorf("got %+v, want skip/no-trigger", res)
	}
}

func TestRunStage_NoEligible(t *testing.T) {
	t.Setenv("CLEANUP_ENABLED", "true")
	t.Setenv("CLEANUP_TRIGGER_THRESHOLD", "0")
	t.Setenv("CLEANUP_BATCH_SIZE", "0") // batch size 0 → empty slice
	_, req := setupProject(t, 3)
	restore := installSeams(t, &fakeProvider{}, &fakeBuildGate{})
	defer restore()
	res, _ := RunStage(context.Background(), req)
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "no-eligible-notes" {
		t.Errorf("got %+v, want skip/no-eligible-notes", res)
	}
}

func TestRunStage_NullRun(t *testing.T) {
	t.Setenv("CLEANUP_ENABLED", "true")
	t.Setenv("CLEANUP_TRIGGER_THRESHOLD", "0")
	t.Setenv("CLEANUP_BATCH_SIZE", "3")
	_, req := setupProject(t, 5)
	ag := &fakeProvider{OnRun: func(ctx context.Context, r *provider.Request) (*provider.Result, error) {
		// Null run: NullRun=true.
		return &provider.Result{
			Outcome:   provider.OutcomeSuccess,
			ExitCode:  0,
			TurnsUsed: 0,
			NullRun:   true,
		}, nil
	}}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate)
	defer restore()

	res, _ := RunStage(context.Background(), req)
	if res.Verdict != proto.VerdictSkip || res.ExitReason != "null-run" {
		t.Errorf("got %+v, want skip/null-run", res)
	}
	if gate.Calls != 0 {
		t.Errorf("build gate called %d times, want 0 (null-run skips it)", gate.Calls)
	}
}

func TestRunStage_NeverFails(t *testing.T) {
	// Property: regardless of branch, verdict must never be `fail`.
	// Exercise every reachable termination path and assert the
	// invariant.
	cases := []struct {
		name  string
		setup func(*testing.T) (*proto.StageRequestV1, func())
	}{
		{"no-trigger", func(t *testing.T) (*proto.StageRequestV1, func()) {
			t.Setenv("CLEANUP_ENABLED", "false")
			_, req := setupProject(t, 1)
			return req, installSeams(t, &fakeProvider{}, &fakeBuildGate{})
		}},
		{"agent-error", func(t *testing.T) (*proto.StageRequestV1, func()) {
			t.Setenv("CLEANUP_ENABLED", "true")
			t.Setenv("CLEANUP_TRIGGER_THRESHOLD", "0")
			_, req := setupProject(t, 5)
			ag := &fakeProvider{OnRun: func(ctx context.Context, r *provider.Request) (*provider.Result, error) {
				return nil, errors.New("boom")
			}}
			return req, installSeams(t, ag, &fakeBuildGate{})
		}},
		{"build-gate-fail", func(t *testing.T) (*proto.StageRequestV1, func()) {
			t.Setenv("CLEANUP_ENABLED", "true")
			t.Setenv("CLEANUP_TRIGGER_THRESHOLD", "0")
			_, req := setupProject(t, 5)
			return req, installSeams(t, &fakeProvider{}, &fakeBuildGate{Err: errors.New("phase failed")})
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req, restore := tc.setup(t)
			defer restore()
			res, err := RunStage(context.Background(), req)
			if err != nil {
				t.Fatalf("RunStage: %v", err)
			}
			if res.Verdict == proto.VerdictFail {
				t.Errorf("verdict == fail, but cleanup stage must never fail")
			}
		})
	}
}

func TestRevertCleanupOnlyFiles_PreservesPriorChanges(t *testing.T) {
	dir := t.TempDir()
	// Initialize git repo with two committed files.
	if out, err := runIn(dir, "git", "init", "-q"); err != nil {
		t.Fatalf("git init: %v: %s", err, out)
	}
	if out, err := runIn(dir, "git", "config", "user.email", "test@example.com"); err != nil {
		t.Fatalf("git config: %v: %s", err, out)
	}
	if out, err := runIn(dir, "git", "config", "user.name", "test"); err != nil {
		t.Fatalf("git config: %v: %s", err, out)
	}
	priorPath := filepath.Join(dir, "prior.txt")
	cleanupPath := filepath.Join(dir, "cleanup.txt")
	if err := os.WriteFile(priorPath, []byte("v1\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := os.WriteFile(cleanupPath, []byte("v1\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if out, err := runIn(dir, "git", "add", "."); err != nil {
		t.Fatalf("git add: %v: %s", err, out)
	}
	if out, err := runIn(dir, "git", "commit", "-q", "-m", "init"); err != nil {
		t.Fatalf("git commit: %v: %s", err, out)
	}

	// Pretend the primary pipeline modified prior.txt before cleanup ran.
	if err := os.WriteFile(priorPath, []byte("v2-primary\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	preCleanup := []string{"prior.txt"}

	// Pretend the cleanup agent modified cleanup.txt during the sweep.
	if err := os.WriteFile(cleanupPath, []byte("v2-cleanup\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	// chdir into the temp project so the inner git diff inside
	// revertCleanupOnlyFiles sees the right tree.
	prevWD, _ := os.Getwd()
	defer os.Chdir(prevWD)
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("chdir: %v", err)
	}

	revertCleanupOnlyFiles(dir, preCleanup)

	priorAfter, _ := os.ReadFile(priorPath)
	if string(priorAfter) != "v2-primary\n" {
		t.Errorf("prior.txt = %q, want preserved (primary pipeline changes)", string(priorAfter))
	}
	cleanupAfter, _ := os.ReadFile(cleanupPath)
	if string(cleanupAfter) != "v1\n" {
		t.Errorf("cleanup.txt = %q, want reverted to v1", string(cleanupAfter))
	}
}
