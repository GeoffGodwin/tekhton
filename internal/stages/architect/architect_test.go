package architect

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fakeBuildGate records each call and returns the next error from a queue.
type fakeBuildGate struct {
	calls []string
	errs  []error
}

func (f *fakeBuildGate) Run(_ context.Context, _, label string) error {
	f.calls = append(f.calls, label)
	if len(f.errs) == 0 {
		return nil
	}
	err := f.errs[0]
	f.errs = f.errs[1:]
	return err
}

type fakeTUI struct {
	calls [][]string
}

func (f *fakeTUI) Call(_ context.Context, sub string, args ...string) {
	row := append([]string{sub}, args...)
	f.calls = append(f.calls, row)
}

// withStubs swaps in the provider + build-gate + tui seams and returns the
// recorders. The cleanup hook restores the previous seams.
func withStubs(t *testing.T) (*fakeProvider, *fakeBuildGate, *fakeTUI) {
	t.Helper()
	a := &fakeProvider{}
	g := &fakeBuildGate{}
	tu := &fakeTUI{}
	prevA := SetProvider(a)
	prevG := SetBuildGateRunner(g)
	prevT := SetTUICaller(tu)
	t.Cleanup(func() {
		SetProvider(prevA)
		SetBuildGateRunner(prevG)
		SetTUICaller(prevT)
	})
	return a, g, tu
}

// setupFixture writes a baseline drift log + ARCHITECT_PLAN.md fixture
// content into a temp PROJECT_DIR, returning the project dir + cleanup
// closure. The fixture is the canonical "simplification + jr work + OOS +
// design-doc obs" plan.
func setupFixture(t *testing.T, plan string, driftEntries int) string {
	t.Helper()
	dir := t.TempDir()
	// Write drift log header + N unresolved entries.
	driftFile := filepath.Join(dir, "DRIFT_LOG.md")
	var sb strings.Builder
	sb.WriteString("# Drift Log\n\n## Unresolved Observations\n\n")
	for i := 0; i < driftEntries; i++ {
		sb.WriteString("- [ ] [2026-06-04 | \"review-cycle\"] drift item ")
		sb.WriteString(string(rune('A' + i)))
		sb.WriteString("\n")
	}
	sb.WriteString("\n## Resolved\n\n## Audit Counter\n\nruns_since_audit: 6\nlast_audit: never\n")
	if err := os.WriteFile(driftFile, []byte(sb.String()), 0o644); err != nil {
		t.Fatalf("write drift log: %v", err)
	}
	// Write the plan.
	tekhtonDir := filepath.Join(dir, ".tekhton")
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		t.Fatalf("mkdir .tekhton: %v", err)
	}
	if err := os.WriteFile(filepath.Join(tekhtonDir, "ARCHITECT_PLAN.md"), []byte(plan), 0o644); err != nil {
		t.Fatalf("write plan: %v", err)
	}
	return dir
}

// makeReq returns a minimal StageRequestV1 with EnvOverrides pointing the
// stage at the test fixture's PROJECT_DIR and TEKHTON_HOME.
func makeReq(projectDir string) *proto.StageRequestV1 {
	home, _ := filepath.Abs(filepath.Join("..", "..", ".."))
	return &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageArchitect,
		Task:       "architect-test",
		ResultFile: filepath.Join(projectDir, ".tekhton", "stage.result.json"),
		EnvOverrides: map[string]string{
			"PROJECT_DIR":  projectDir,
			"TEKHTON_HOME": home,
		},
	}
}

func TestRunStage_AuditWithSimplification(t *testing.T) {
	planBytes, err := os.ReadFile(filepath.Join("testdata", "plan_baseline.md"))
	if err != nil {
		t.Fatalf("read baseline plan: %v", err)
	}
	dir := setupFixture(t, string(planBytes), 5)
	a, g, _ := withStubs(t)

	t.Setenv("PROJECT_DIR", dir)
	t.Setenv("DRIFT_LOG_FILE", filepath.Join(dir, "DRIFT_LOG.md"))
	t.Setenv("HUMAN_ACTION_FILE", filepath.Join(dir, ".tekhton", "HUMAN_ACTION_REQUIRED.md"))
	t.Setenv("ARCHITECT_PLAN_FILE", filepath.Join(dir, ".tekhton", "ARCHITECT_PLAN.md"))
	t.Setenv("TEKHTON_HOME", filepath.Join("..", "..", ".."))

	req := makeReq(dir)
	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("Verdict: want pass, got %s", res.Verdict)
	}
	if res.ExitReason != "audit_complete" {
		t.Errorf("ExitReason: want audit_complete, got %s", res.ExitReason)
	}
	// 1 architect + 1 sr + 1 jr + 1 reviewer = 4
	if len(a.calls) != 4 {
		t.Errorf("agent calls: want 4 (arch+sr+jr+review), got %d (%v)", len(a.calls), labels(a.calls))
	}
	// Build gate ran once (no fail → no retry)
	if len(g.calls) != 1 || g.calls[0] != "post-architect-remediation" {
		t.Errorf("build gate calls: want 1 [post-architect-remediation], got %v", g.calls)
	}
	// Human action file received the design-doc observations.
	haContent, _ := os.ReadFile(filepath.Join(dir, ".tekhton", "HUMAN_ACTION_REQUIRED.md"))
	if !strings.Contains(string(haContent), "DESIGN.md") {
		t.Errorf("HUMAN_ACTION_REQUIRED.md missing design-doc observations:\n%s", haContent)
	}
}

func TestRunStage_AuditWithJrWorkOnly(t *testing.T) {
	plan := `# Architect Plan

## Simplification

- None

## Staleness Fixes

- ` + "`lib/foo.sh:55` references _old_fn renamed in m23." + `

## Dead Code Removal

- None

## Naming Normalization

- None

## Out of Scope

- None

## Design Doc Observations

- None
`
	dir := setupFixture(t, plan, 3)
	a, _, _ := withStubs(t)

	t.Setenv("PROJECT_DIR", dir)
	t.Setenv("DRIFT_LOG_FILE", filepath.Join(dir, "DRIFT_LOG.md"))
	t.Setenv("ARCHITECT_PLAN_FILE", filepath.Join(dir, ".tekhton", "ARCHITECT_PLAN.md"))
	t.Setenv("HUMAN_ACTION_FILE", filepath.Join(dir, ".tekhton", "HUMAN_ACTION_REQUIRED.md"))

	req := makeReq(dir)
	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("Verdict: want pass, got %s", res.Verdict)
	}
	// Confirm sr NOT dispatched, jr IS dispatched.
	srLabel := "Coder (architect remediation)"
	jrLabel := "Jr Coder (architect remediation)"
	for _, c := range a.calls {
		if c.Label == srLabel {
			t.Errorf("Sr coder MUST NOT run when Simplification empty (got call: %v)", c.Label)
		}
	}
	jrCount := 0
	for _, c := range a.calls {
		if c.Label == jrLabel {
			jrCount++
		}
	}
	if jrCount != 1 {
		t.Errorf("Jr coder: want exactly 1 call, got %d", jrCount)
	}
}

func TestRunStage_AuditWithDesignDocObservationsOnly(t *testing.T) {
	planBytes, err := os.ReadFile(filepath.Join("testdata", "plan_design_doc_only.md"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	dir := setupFixture(t, string(planBytes), 2)
	a, g, _ := withStubs(t)

	haPath := filepath.Join(dir, ".tekhton", "HUMAN_ACTION_REQUIRED.md")
	t.Setenv("PROJECT_DIR", dir)
	t.Setenv("DRIFT_LOG_FILE", filepath.Join(dir, "DRIFT_LOG.md"))
	t.Setenv("ARCHITECT_PLAN_FILE", filepath.Join(dir, ".tekhton", "ARCHITECT_PLAN.md"))
	t.Setenv("HUMAN_ACTION_FILE", haPath)

	req := makeReq(dir)
	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("Verdict: want pass, got %s", res.Verdict)
	}
	// Only architect agent ran — no sr/jr/reviewer.
	if len(a.calls) != 1 {
		t.Errorf("agent calls: want 1 (architect-only), got %d (%v)", len(a.calls), labels(a.calls))
	}
	// No build gate (no remediation).
	if len(g.calls) != 0 {
		t.Errorf("build gate calls: want 0, got %v", g.calls)
	}
	// Human action file gained exactly 2 entries (boilerplate filtered).
	haContent, _ := os.ReadFile(haPath)
	itemCount := strings.Count(string(haContent), "- [ ]")
	if itemCount != 2 {
		t.Errorf("HUMAN_ACTION_REQUIRED.md: want 2 actionable entries, got %d:\n%s", itemCount, haContent)
	}
}

func TestRunStage_NoPlanReturnsPass(t *testing.T) {
	dir := setupFixture(t, "", 0) // plan is written but we'll delete it
	planPath := filepath.Join(dir, ".tekhton", "ARCHITECT_PLAN.md")
	_ = os.Remove(planPath)

	_, _, _ = withStubs(t)
	t.Setenv("PROJECT_DIR", dir)
	t.Setenv("ARCHITECT_PLAN_FILE", planPath)
	t.Setenv("DRIFT_LOG_FILE", filepath.Join(dir, "DRIFT_LOG.md"))

	req := makeReq(dir)
	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("Verdict: want pass, got %s", res.Verdict)
	}
	if res.ExitReason != "no_plan" {
		t.Errorf("ExitReason: want no_plan, got %s", res.ExitReason)
	}
}

func TestRunStage_UpstreamErrorReturnsPass(t *testing.T) {
	dir := t.TempDir()
	a, _, _ := withStubs(t)
	// Force the architect agent to return an UPSTREAM-classified result.
	a.err = nil
	prev := SetProvider(&upstreamProvider{})
	t.Cleanup(func() { SetProvider(prev) })

	t.Setenv("PROJECT_DIR", dir)
	t.Setenv("ARCHITECT_PLAN_FILE", filepath.Join(dir, ".tekhton", "ARCHITECT_PLAN.md"))
	t.Setenv("DRIFT_LOG_FILE", filepath.Join(dir, "DRIFT_LOG.md"))

	req := makeReq(dir)
	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("Verdict: want pass, got %s", res.Verdict)
	}
	if res.ExitReason != "upstream_error" {
		t.Errorf("ExitReason: want upstream_error, got %s", res.ExitReason)
	}
}

func TestRunStage_BuildBrokenAfterRemediation(t *testing.T) {
	// Plan has sr work; build gate fails on both attempts.
	plan := `# Architect Plan

## Simplification

- Inline a one-shot helper.

## Staleness Fixes

- None

## Dead Code Removal

- None

## Naming Normalization

- None

## Out of Scope

- None

## Design Doc Observations

- None
`
	dir := setupFixture(t, plan, 2)
	_, g, _ := withStubs(t)
	g.errs = []error{errors.New("compile failed"), errors.New("still broken")}

	t.Setenv("PROJECT_DIR", dir)
	t.Setenv("DRIFT_LOG_FILE", filepath.Join(dir, "DRIFT_LOG.md"))
	t.Setenv("ARCHITECT_PLAN_FILE", filepath.Join(dir, ".tekhton", "ARCHITECT_PLAN.md"))

	req := makeReq(dir)
	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("Verdict: want pass even on build_broken, got %s", res.Verdict)
	}
	if res.ExitReason != "build_broken" {
		t.Errorf("ExitReason: want build_broken, got %s", res.ExitReason)
	}
	// Build gate called twice.
	if len(g.calls) != 2 {
		t.Errorf("build gate calls: want 2 (first + retry), got %d (%v)", len(g.calls), g.calls)
	}
}

func TestStageEnd_VerdictPassesThroughToTUI(t *testing.T) {
	_, _, tu := withStubs(t)
	cfg := config{ArchitectModel: "x"}
	stageEnd(context.Background(), true, cfg, "BUILD_BROKEN")
	if len(tu.calls) != 1 {
		t.Fatalf("want 1 tui call, got %d", len(tu.calls))
	}
	row := tu.calls[0]
	if row[0] != "stage-end" {
		t.Errorf("sub: want stage-end, got %q", row[0])
	}
	if !contains(row, "--verdict") || !contains(row, "BUILD_BROKEN") {
		t.Errorf("expected verdict propagation in args: %v", row)
	}
}

func TestStageEnd_NoOpWhenStartedFalse(t *testing.T) {
	_, _, tu := withStubs(t)
	stageEnd(context.Background(), false, config{}, "X")
	if len(tu.calls) != 0 {
		t.Errorf("want zero tui calls when started=false, got %v", tu.calls)
	}
}

func TestOOSBulletLines_StripsBlanks(t *testing.T) {
	in := []string{"first", "", "  ", "second"}
	got := oosBulletLines(in)
	if len(got) != 2 {
		t.Fatalf("want 2 entries, got %d (%v)", len(got), got)
	}
	if got[0] != "first" || got[1] != "second" {
		t.Errorf("unexpected: %v", got)
	}
}

// --- helpers ---------------------------------------------------------------

func labels(calls []*provider.Request) []string {
	out := make([]string, 0, len(calls))
	for _, c := range calls {
		out = append(out, c.Label)
	}
	return out
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}

// upstreamProvider simulates the UPSTREAM-error branch.
type upstreamProvider struct{}

func (upstreamProvider) Name() string { return "fake-upstream" }
func (upstreamProvider) Tier() string { return provider.TierUnknown }

func (upstreamProvider) RunAgent(_ context.Context, _ *provider.Request) (*provider.Result, error) {
	return &provider.Result{
		Outcome:          provider.OutcomeUpstreamError,
		ErrorCategory:    "UPSTREAM",
		ErrorSubcategory: "rate_limit",
		ErrorMessage:     "test upstream error",
	}, nil
}
