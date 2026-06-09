package review

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fakeProvider is a recording provider.Provider that consumes a queue of
// Behaviors, one per RunAgent() call. Once exhausted RunAgent() returns a
// default success result with TurnsUsed=5.
type fakeProvider struct {
	Calls     []*provider.Request
	Behaviors []func(*provider.Request) (*provider.Result, error)
	idx       int
}

func (f *fakeProvider) Name() string { return "fake-review" }
func (f *fakeProvider) Tier() string { return provider.TierUnknown }

func (f *fakeProvider) RunAgent(_ context.Context, req *provider.Request) (*provider.Result, error) {
	cp := *req
	f.Calls = append(f.Calls, &cp)
	if f.idx < len(f.Behaviors) {
		b := f.Behaviors[f.idx]
		f.idx++
		return b(req)
	}
	return &provider.Result{
		Outcome:   provider.OutcomeSuccess,
		ExitCode:  0,
		TurnsUsed: 5,
	}, nil
}

// fakeBuildGate is a recording BuildGateRunner. Behaviors is consumed by
// index; once exhausted Run() returns nil (pass).
type fakeBuildGate struct {
	Calls     []string
	Behaviors []error
	idx       int
}

func (f *fakeBuildGate) Run(_ context.Context, _, stageLabel string) error {
	f.Calls = append(f.Calls, stageLabel)
	if f.idx < len(f.Behaviors) {
		err := f.Behaviors[f.idx]
		f.idx++
		return err
	}
	return nil
}

// fakeReplan returns the canned decision on every Run().
type fakeReplan struct {
	Decision replanDecision
	Err      error
	Calls    int
}

func (f *fakeReplan) Run(_ context.Context, _, _ string) (replanDecision, error) {
	f.Calls++
	return f.Decision, f.Err
}

// fakeSpecialist returns the canned blockers string on every Run().
type fakeSpecialist struct {
	Blockers string
	Err      error
	Calls    int
}

func (f *fakeSpecialist) Run(_ context.Context, _ string) (string, error) {
	f.Calls++
	return f.Blockers, f.Err
}

// installSeams wires fakes for the four package seams and returns a restore
// closure. Tests may pass nil for seams they don't need; the default is left
// in place.
func installSeams(t *testing.T, ag provider.Provider, gate BuildGateRunner,
	replan ReplanRunner, spec SpecialistRunner,
) func() {
	t.Helper()
	var (
		prevA provider.Provider
		prevG BuildGateRunner
		prevR ReplanRunner
		prevS SpecialistRunner
	)
	if ag != nil {
		prevA = SetProvider(ag)
	}
	if gate != nil {
		prevG = SetBuildGateRunner(gate)
	}
	if replan != nil {
		prevR = SetReplanRunner(replan)
	}
	if spec != nil {
		prevS = SetSpecialistRunner(spec)
	}
	return func() {
		if ag != nil {
			SetProvider(prevA)
		}
		if gate != nil {
			SetBuildGateRunner(prevG)
		}
		if replan != nil {
			SetReplanRunner(prevR)
		}
		if spec != nil {
			SetSpecialistRunner(prevS)
		}
	}
}

// repoRoot walks up to the tekhton repo root (the directory containing
// go.mod) so the prompt loader can resolve prompts/*.prompt.md.
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

// setupProject creates a temp project dir with a default env and returns the
// project dir + a stage request scoped to it.
func setupProject(t *testing.T) (string, *proto.StageRequestV1) {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".tekhton"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	t.Setenv("TEKHTON_DIR", ".tekhton")
	t.Setenv("REVIEW_SKIP_THRESHOLD", "0")
	t.Setenv("MILESTONE_MODE", "false")
	t.Setenv("MAX_REVIEW_CYCLES", "3")
	t.Setenv("REVIEWER_MAX_TURNS", "20")
	t.Setenv("REVIEWER_MAX_TURNS_CAP", "60")
	t.Setenv("ADJUSTED_REVIEWER_TURNS", "")
	t.Setenv("CODER_MAX_TURNS", "80")
	t.Setenv("JR_CODER_MAX_TURNS", "40")
	t.Setenv("EFFECTIVE_CODER_MAX_TURNS", "")
	t.Setenv("EFFECTIVE_JR_CODER_MAX_TURNS", "")
	// Use a relative REVIEWER_REPORT_FILE so the synthesized body embeds the
	// short bash-style path string (byte-parity with bash semantics).
	t.Setenv("REVIEWER_REPORT_FILE", ".tekhton/REVIEWER_REPORT.md")

	req := &proto.StageRequestV1{
		Proto: proto.StageRequestProtoV1,
		Stage: proto.StageReview,
		Task:  "test task",
		EnvOverrides: map[string]string{
			"PROJECT_DIR":          dir,
			"TEKHTON_HOME":         repoRoot(t),
			"PIPELINE_STAGE_POS":   "3",
			"PIPELINE_STAGE_COUNT": "4",
		},
		ResultFile: filepath.Join(dir, "result.json"),
	}
	return dir, req
}

// writeReport drops content at .tekhton/REVIEWER_REPORT.md.
func writeReport(t *testing.T, dir, content string) {
	t.Helper()
	p := filepath.Join(dir, ".tekhton", "REVIEWER_REPORT.md")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatalf("write REVIEWER_REPORT.md: %v", err)
	}
}

// readReviewerReport returns the post-run REVIEWER_REPORT.md contents.
func readReviewerReport(t *testing.T, dir string) string {
	t.Helper()
	p := filepath.Join(dir, ".tekhton", "REVIEWER_REPORT.md")
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read REVIEWER_REPORT.md: %v", err)
	}
	return string(data)
}
