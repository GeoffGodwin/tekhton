package architect

import (
	"context"
	"errors"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// fakeProvider records every RunAgent() invocation. Useful for asserting
// model / turns / tools routing under each remediation kind.
type fakeProvider struct {
	calls []*provider.Request
	err   error
}

func (f *fakeProvider) Name() string { return "fake-architect" }
func (f *fakeProvider) Tier() string { return provider.TierUnknown }

func (f *fakeProvider) RunAgent(_ context.Context, req *provider.Request) (*provider.Result, error) {
	f.calls = append(f.calls, req)
	if f.err != nil {
		return nil, f.err
	}
	return &provider.Result{
		Outcome: provider.OutcomeSuccess,
	}, nil
}

// withFakeAgent swaps in a recording provider for the duration of the test.
// Returns the fake so the test body can read its `calls` slice.
func withFakeAgent(t *testing.T) *fakeProvider {
	t.Helper()
	fp := &fakeProvider{}
	prev := SetProvider(fp)
	t.Cleanup(func() { SetProvider(prev) })
	return fp
}

func TestRunRework_SrUsesCoderModelAndTurns(t *testing.T) {
	fa := withFakeAgent(t)
	cfg := config{
		PromptsDir:      "../../../prompts",
		CoderModel:      "claude-coder-pinned",
		CoderMaxTurns:   80,
		CoderTools:      "Read Write Edit",
		JrCoderModel:    "claude-jr-pinned", // must NOT appear
		JrCoderMaxTurns: 40,
		Provider:        fa,
	}
	if err := runRework(context.Background(), remediationSr, cfg); err != nil {
		t.Fatalf("runRework sr: %v", err)
	}
	if len(fa.calls) != 1 {
		t.Fatalf("want 1 call, got %d", len(fa.calls))
	}
	c := fa.calls[0]
	if c.Model != "claude-coder-pinned" {
		t.Errorf("Model: want coder-pinned, got %q", c.Model)
	}
	if c.MaxTurns != 80 {
		t.Errorf("MaxTurns: want 80, got %d", c.MaxTurns)
	}
	if c.AllowedTools != "Read Write Edit" {
		t.Errorf("AllowedTools: want coder tools, got %q", c.AllowedTools)
	}
	if c.Label != "Coder (architect remediation)" {
		t.Errorf("Label: want 'Coder (architect remediation)', got %q", c.Label)
	}
}

func TestRunRework_JrUsesJrModelAndTurns(t *testing.T) {
	fa := withFakeAgent(t)
	cfg := config{
		PromptsDir:      "../../../prompts",
		CoderModel:      "claude-coder-pinned", // must NOT appear
		CoderMaxTurns:   80,
		JrCoderModel:    "claude-jr-pinned",
		JrCoderMaxTurns: 40,
		JrCoderTools:    "Read Edit",
		Provider:        fa,
	}
	if err := runRework(context.Background(), remediationJr, cfg); err != nil {
		t.Fatalf("runRework jr: %v", err)
	}
	if len(fa.calls) != 1 {
		t.Fatalf("want 1 call, got %d", len(fa.calls))
	}
	c := fa.calls[0]
	if c.Model != "claude-jr-pinned" {
		t.Errorf("Model: want jr-pinned, got %q", c.Model)
	}
	if c.MaxTurns != 40 {
		t.Errorf("MaxTurns: want 40, got %d", c.MaxTurns)
	}
	if c.AllowedTools != "Read Edit" {
		t.Errorf("AllowedTools: want jr tools, got %q", c.AllowedTools)
	}
	if c.Label != "Jr Coder (architect remediation)" {
		t.Errorf("Label: want 'Jr Coder (architect remediation)', got %q", c.Label)
	}
}

func TestRunRework_UnknownKindReturnsError(t *testing.T) {
	fa := withFakeAgent(t)
	err := runRework(context.Background(), "nonsense", config{PromptsDir: "../../../prompts", Provider: fa})
	if err == nil {
		t.Fatalf("want error for unknown kind, got nil")
	}
}

func TestRunBuildFix_UsesCoderMaxTurnsDivThree(t *testing.T) {
	fa := withFakeAgent(t)
	cfg := config{
		PromptsDir:    "../../../prompts",
		CoderModel:    "claude-coder-pinned",
		CoderMaxTurns: 80,
		BuildFixTools: "Read Write Edit Bash",
		Provider:      fa,
	}
	if err := runBuildFix(context.Background(), cfg); err != nil {
		t.Fatalf("runBuildFix: %v", err)
	}
	if len(fa.calls) != 1 {
		t.Fatalf("want 1 call, got %d", len(fa.calls))
	}
	c := fa.calls[0]
	if c.MaxTurns != 80/3 {
		t.Errorf("MaxTurns: want %d (80/3 integer div), got %d", 80/3, c.MaxTurns)
	}
	if c.AllowedTools != "Read Write Edit Bash" {
		t.Errorf("AllowedTools: want build-fix tools, got %q", c.AllowedTools)
	}
}

func TestRunBuildFix_MinTurnsClampedToOne(t *testing.T) {
	fa := withFakeAgent(t)
	cfg := config{
		PromptsDir:    "../../../prompts",
		CoderModel:    "x",
		CoderMaxTurns: 2, // 2/3 = 0 integer div
		Provider:      fa,
	}
	if err := runBuildFix(context.Background(), cfg); err != nil {
		t.Fatalf("runBuildFix: %v", err)
	}
	if fa.calls[0].MaxTurns != 1 {
		t.Errorf("MaxTurns: want clamped-to-1, got %d", fa.calls[0].MaxTurns)
	}
}

func TestRunExpeditedReview_UsesStandardModelAndReviewerTurns(t *testing.T) {
	fa := withFakeAgent(t)
	cfg := config{
		PromptsDir:       "../../../prompts",
		StandardModel:    "claude-standard-pinned",
		ReviewerMaxTurns: 20,
		ReviewerTools:    "Read",
		Provider:         fa,
	}
	if err := runExpeditedReview(context.Background(), cfg); err != nil {
		t.Fatalf("runExpeditedReview: %v", err)
	}
	if len(fa.calls) != 1 {
		t.Fatalf("want 1 call, got %d", len(fa.calls))
	}
	c := fa.calls[0]
	if c.Model != "claude-standard-pinned" {
		t.Errorf("Model: want standard-pinned, got %q", c.Model)
	}
	if c.MaxTurns != 20 {
		t.Errorf("MaxTurns: want 20, got %d", c.MaxTurns)
	}
	if c.Label != "Reviewer (architect expedited)" {
		t.Errorf("Label: want 'Reviewer (architect expedited)', got %q", c.Label)
	}
}

func TestInvokeAgent_PropagatesAgentError(t *testing.T) {
	fa := withFakeAgent(t)
	fa.err = errors.New("forced failure")
	cfg := config{
		PromptsDir:    "../../../prompts",
		CoderModel:    "x",
		CoderMaxTurns: 9,
		CoderTools:    "Read",
		Provider:      fa,
	}
	err := runRework(context.Background(), remediationSr, cfg)
	if err == nil {
		t.Fatalf("want propagated error, got nil")
	}
}
