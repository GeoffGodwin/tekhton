package scout

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// scoutFake captures the calls Run makes through the Deps seam.
type scoutFake struct {
	runAgentCalls    int
	runAgentLabel    string
	parseCalls       int
	parseReturn      *Estimate
	wasNullRunReturn bool
}

func (f *scoutFake) deps() *Deps {
	return &Deps{
		RenderPrompt: func(_ string, _ map[string]string) (string, error) { return "PROMPT", nil },
		RunAgent: func(_ context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
			f.runAgentCalls++
			f.runAgentLabel = req.Label
			return &proto.AgentResultV1{ExitCode: 0, TurnsUsed: 5}, nil
		},
		ParseEstimate: func(_ string) (*Estimate, error) {
			f.parseCalls++
			return f.parseReturn, nil
		},
		WasNullRun: func() bool { return f.wasNullRunReturn },
	}
}

// TestRun_LiveAgentHappyPath drives the canonical scout run: the agent
// produces a report, ParseEstimate returns a populated Estimate, Run
// reports success.
func TestRun_LiveAgentHappyPath(t *testing.T) {
	dir := t.TempDir()
	report := filepath.Join(dir, "SCOUT_REPORT.md")
	if err := os.WriteFile(report, []byte("(content)\n"), 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}

	f := &scoutFake{parseReturn: &Estimate{
		FilesToModify: 3, EstimatedLines: 50, Interconnected: "medium",
		RecommendedCoder: 40, RecommendedReviewer: 8, RecommendedTester: 30,
	}}
	cfg := &Config{ReportFile: report}

	result, err := Run(context.Background(), cfg, f.deps())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if f.runAgentCalls != 1 {
		t.Fatalf("RunAgent calls = %d, want 1", f.runAgentCalls)
	}
	if f.runAgentLabel != "Scout" {
		t.Fatalf("RunAgent label = %q, want %q", f.runAgentLabel, "Scout")
	}
	if result.Estimate == nil || result.Estimate.RecommendedCoder != 40 {
		t.Fatalf("Estimate = %+v, want RecommendedCoder=40", result.Estimate)
	}
	if result.WasNullRun {
		t.Fatalf("WasNullRun = true, want false")
	}
}

// TestRun_PostSplitLabel verifies the post-split agent label is
// "Scout (post-split)" — operators grep this string in logs.
func TestRun_PostSplitLabel(t *testing.T) {
	dir := t.TempDir()
	report := filepath.Join(dir, "SCOUT_REPORT.md")
	if err := os.WriteFile(report, []byte("(content)\n"), 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}

	f := &scoutFake{parseReturn: &Estimate{RecommendedCoder: 20}}
	cfg := &Config{ReportFile: report, PostSplit: true}

	if _, err := Run(context.Background(), cfg, f.deps()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if f.runAgentLabel != "Scout (post-split)" {
		t.Fatalf("RunAgent label = %q, want %q", f.runAgentLabel, "Scout (post-split)")
	}
}

// TestRun_NullRunPath pins the null-run branch: WasNullRun=true → result
// reports it, no parse attempt is made, no error returned.
func TestRun_NullRunPath(t *testing.T) {
	f := &scoutFake{wasNullRunReturn: true}
	cfg := &Config{ReportFile: filepath.Join(t.TempDir(), "missing.md")}

	result, err := Run(context.Background(), cfg, f.deps())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !result.WasNullRun {
		t.Fatalf("WasNullRun = false, want true")
	}
	if f.parseCalls != 0 {
		t.Fatalf("ParseEstimate called %d times on null-run path, want 0", f.parseCalls)
	}
}

// TestRun_MissingReportPath pins the warn-and-proceed branch: agent
// returned without writing the report → result has nil Estimate, no
// error.
func TestRun_MissingReportPath(t *testing.T) {
	f := &scoutFake{}
	cfg := &Config{ReportFile: filepath.Join(t.TempDir(), "missing.md")}

	result, err := Run(context.Background(), cfg, f.deps())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Estimate != nil {
		t.Fatalf("Estimate = %+v, want nil (missing report)", result.Estimate)
	}
	if f.parseCalls != 0 {
		t.Fatalf("ParseEstimate called %d times when report missing, want 0", f.parseCalls)
	}
}

// TestRun_CachedSkipsAgent pins the SCOUT_CACHED=true branch: agent is
// not invoked, but ParseEstimate runs against the existing report.
func TestRun_CachedSkipsAgent(t *testing.T) {
	dir := t.TempDir()
	report := filepath.Join(dir, "SCOUT_REPORT.md")
	if err := os.WriteFile(report, []byte("(cached)\n"), 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}

	f := &scoutFake{parseReturn: &Estimate{RecommendedCoder: 25}}
	cfg := &Config{ReportFile: report, Cached: true}

	result, err := Run(context.Background(), cfg, f.deps())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if f.runAgentCalls != 0 {
		t.Fatalf("RunAgent called %d times on cached path, want 0", f.runAgentCalls)
	}
	if f.parseCalls != 1 {
		t.Fatalf("ParseEstimate called %d times on cached path, want 1", f.parseCalls)
	}
	if result.Estimate == nil || result.Estimate.RecommendedCoder != 25 {
		t.Fatalf("Estimate = %+v, want RecommendedCoder=25", result.Estimate)
	}
}

// TestRun_CachedWithMissingReportFallsBack pins the cached-but-missing
// edge case: cfg.Cached=true but the file is missing → warn, return
// nil Estimate, do not invoke the agent (the bash version handles this
// the same way: log a warning and fall through).
func TestRun_CachedWithMissingReportFallsBack(t *testing.T) {
	f := &scoutFake{}
	cfg := &Config{ReportFile: filepath.Join(t.TempDir(), "missing.md"), Cached: true}

	result, err := Run(context.Background(), cfg, f.deps())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Estimate != nil {
		t.Fatalf("Estimate = %+v, want nil", result.Estimate)
	}
	if f.runAgentCalls != 0 {
		t.Fatalf("RunAgent invoked %d times on cached-missing path, want 0", f.runAgentCalls)
	}
}

// TestParseEstimate_FromMarkdownReport drives the canonical bullet/bold
// formatted report and asserts byte-identical parse to the bash version
// — leading bullets stripped, bold markers stripped, range values
// decode to the first integer.
func TestParseEstimate_FromMarkdownReport(t *testing.T) {
	report := `# Scout Report

## Files Located
- foo.go
- bar.go

## Complexity Estimate

- **Files to modify:** 5
- **Estimated lines of change:** 25-30
- **Interconnected systems:** medium
- **Recommended coder turns:** 60
- **Recommended reviewer turns:** 12
- **Recommended tester turns:** 35

## Other Section
- (ignored)
`
	dir := t.TempDir()
	path := filepath.Join(dir, "SCOUT_REPORT.md")
	if err := os.WriteFile(path, []byte(report), 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}

	est, err := ParseEstimate(path)
	if err != nil {
		t.Fatalf("ParseEstimate: %v", err)
	}
	if est == nil {
		t.Fatalf("ParseEstimate returned nil")
	}
	if est.FilesToModify != 5 {
		t.Fatalf("FilesToModify = %d, want 5", est.FilesToModify)
	}
	if est.EstimatedLines != 25 {
		t.Fatalf("EstimatedLines = %d, want 25 (range start)", est.EstimatedLines)
	}
	if est.Interconnected != "medium" {
		t.Fatalf("Interconnected = %q, want medium", est.Interconnected)
	}
	if est.RecommendedCoder != 60 {
		t.Fatalf("RecommendedCoder = %d, want 60", est.RecommendedCoder)
	}
	if est.RecommendedReviewer != 12 {
		t.Fatalf("RecommendedReviewer = %d, want 12", est.RecommendedReviewer)
	}
	if est.RecommendedTester != 35 {
		t.Fatalf("RecommendedTester = %d, want 35", est.RecommendedTester)
	}
}

// TestParseEstimate_MissingFile pins the missing-file → nil semantic.
func TestParseEstimate_MissingFile(t *testing.T) {
	est, err := ParseEstimate(filepath.Join(t.TempDir(), "no-such.md"))
	if err != nil {
		t.Fatalf("ParseEstimate on missing file: err=%v, want nil", err)
	}
	if est != nil {
		t.Fatalf("ParseEstimate on missing file = %+v, want nil", est)
	}
}

// TestParseEstimate_NoComplexitySection pins the missing-section → nil
// semantic. The report exists but has no "## Complexity Estimate"
// header.
func TestParseEstimate_NoComplexitySection(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "SCOUT_REPORT.md")
	if err := os.WriteFile(path, []byte("# Scout\n\nNo estimate.\n"), 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	est, err := ParseEstimate(path)
	if err != nil {
		t.Fatalf("ParseEstimate: %v", err)
	}
	if est != nil {
		t.Fatalf("ParseEstimate without section = %+v, want nil", est)
	}
}

// TestParseEstimate_RecommendedCoderZeroFails pins the bash validation
// semantic: a section that parses but has RecommendedCoder=0 fails the
// parse_scout_complexity tail check and returns nil.
func TestParseEstimate_RecommendedCoderZeroFails(t *testing.T) {
	report := `## Complexity Estimate

- Files to modify: 1
- Estimated lines of change: 5
- Interconnected systems: low
- Recommended coder turns: 0
- Recommended reviewer turns: 5
- Recommended tester turns: 15
`
	dir := t.TempDir()
	path := filepath.Join(dir, "SCOUT_REPORT.md")
	if err := os.WriteFile(path, []byte(report), 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	est, err := ParseEstimate(path)
	if err != nil {
		t.Fatalf("ParseEstimate: %v", err)
	}
	if est != nil {
		t.Fatalf("ParseEstimate with RecommendedCoder=0 = %+v, want nil", est)
	}
}
