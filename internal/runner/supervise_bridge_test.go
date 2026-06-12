package runner

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
)

// makePromptFile writes content to a temp file and returns its path +
// a cleanup function. Tests call it to satisfy PromptFile requirements.
func makePromptFile(t *testing.T, content string) string {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "bridge-test-*.md")
	if err != nil {
		t.Fatalf("makePromptFile: %v", err)
	}
	if _, err := f.WriteString(content); err != nil {
		f.Close()
		t.Fatalf("makePromptFile write: %v", err)
	}
	f.Close()
	return f.Name()
}

func minimalRequest(t *testing.T, promptContent string) *proto.AgentRequestV1 {
	t.Helper()
	return &proto.AgentRequestV1{
		Proto:        proto.AgentRequestProtoV1,
		Label:        "TestAgent",
		Model:        "claude-sonnet-4-6",
		PromptFile:   makePromptFile(t, promptContent),
		MaxTurns:     3,
		WorkingDir:   t.TempDir(),
		AllowedTools: "Read Write",
	}
}

// --- sanitizeLabel -----------------------------------------------------------

func TestSanitizeLabel(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"Coder", "CODER"},
		{"Test Fix (attempt 2)", "TEST_FIX__ATTEMPT_2_"},
		{"tester-write-failing", "TESTER_WRITE_FAILING"},
		{"", ""},
		{"abc123", "ABC123"},
		{"A B C", "A_B_C"},
	}
	for _, tc := range cases {
		got := sanitizeLabel(tc.in)
		if got != tc.want {
			t.Errorf("sanitizeLabel(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// --- BridgeToProviderRequest -------------------------------------------------

func TestBridgeToProviderRequest_FieldMapping(t *testing.T) {
	prompt := "hello world"
	req := minimalRequest(t, prompt)
	req.TimeoutSecs = 30

	got, err := BridgeToProviderRequest(req)
	if err != nil {
		t.Fatalf("BridgeToProviderRequest: %v", err)
	}
	if got.Prompt != prompt {
		t.Errorf("Prompt: want %q, got %q", prompt, got.Prompt)
	}
	if got.Model != req.Model {
		t.Errorf("Model: want %q, got %q", req.Model, got.Model)
	}
	if got.MaxTurns != req.MaxTurns {
		t.Errorf("MaxTurns: want %d, got %d", req.MaxTurns, got.MaxTurns)
	}
	if got.Label != req.Label {
		t.Errorf("Label: want %q, got %q", req.Label, got.Label)
	}
	if got.WorkingDir != req.WorkingDir {
		t.Errorf("WorkingDir: want %q, got %q", req.WorkingDir, got.WorkingDir)
	}
	if got.AllowedTools != req.AllowedTools {
		t.Errorf("AllowedTools: want %q, got %q", req.AllowedTools, got.AllowedTools)
	}
	if got.Timeout.Seconds() != 30 {
		t.Errorf("Timeout: want 30s, got %v", got.Timeout)
	}
}

func TestBridgeToProviderRequest_MissingFile(t *testing.T) {
	req := minimalRequest(t, "")
	req.PromptFile = filepath.Join(t.TempDir(), "nonexistent.md")

	_, err := BridgeToProviderRequest(req)
	if err == nil {
		t.Fatal("expected error for missing prompt file")
	}
}

// --- BridgeFromProviderResult ------------------------------------------------

func TestBridgeFromProviderResult_NilResult(t *testing.T) {
	req := minimalRequest(t, "")
	res := BridgeFromProviderResult(nil, req)
	if res.ExitCode != 1 {
		t.Errorf("ExitCode: want 1, got %d", res.ExitCode)
	}
	if res.Outcome != proto.OutcomeFatalError {
		t.Errorf("Outcome: want %q, got %q", proto.OutcomeFatalError, res.Outcome)
	}
	if res.Label != req.Label {
		t.Errorf("Label: want %q, got %q", req.Label, res.Label)
	}
}

func TestBridgeFromProviderResult_SynthesisPath(t *testing.T) {
	req := &proto.AgentRequestV1{Label: "Tester", RunID: "run1"}
	provRes := &provider.Result{
		Outcome:          provider.OutcomeSuccess,
		TurnsUsed:        5,
		ExitCode:         0,
		ErrorCategory:    "",
		ErrorSubcategory: "",
		ErrorMessage:     "",
	}
	res := BridgeFromProviderResult(provRes, req)
	if res.Outcome != proto.OutcomeSuccess {
		t.Errorf("Outcome: want %q, got %q", proto.OutcomeSuccess, res.Outcome)
	}
	if res.TurnsUsed != 5 {
		t.Errorf("TurnsUsed: want 5, got %d", res.TurnsUsed)
	}
	if res.Label != "Tester" {
		t.Errorf("Label: want Tester, got %q", res.Label)
	}
	if res.RunID != "run1" {
		t.Errorf("RunID: want run1, got %q", res.RunID)
	}
}

// --- ProviderFromRequest -----------------------------------------------------

func TestProviderFromRequest_EmptyProviderFallsToEnv(t *testing.T) {
	req := minimalRequest(t, "")
	req.Provider = ""
	t.Setenv("PROVIDER", "claude")
	t.Setenv("PROVIDER_TESTAGENT", "")

	p, err := ProviderFromRequest(req)
	if err != nil {
		t.Fatalf("ProviderFromRequest: %v", err)
	}
	if p.Name() != "claude" {
		t.Errorf("Name: want claude, got %q", p.Name())
	}
}

func TestProviderFromRequest_ExplicitProviderField(t *testing.T) {
	req := minimalRequest(t, "")
	req.Provider = "codex"
	t.Setenv("CODEX_API_KEY", "test-key")

	p, err := ProviderFromRequest(req)
	if err != nil {
		t.Fatalf("ProviderFromRequest with codex: %v", err)
	}
	if p.Name() != "codex" {
		t.Errorf("Name: want codex, got %q", p.Name())
	}
}

func TestProviderFromRequest_UnknownProviderReturnsErrInvalidRequest(t *testing.T) {
	req := minimalRequest(t, "")
	req.Provider = "unknown-provider-xyz"

	_, err := ProviderFromRequest(req)
	if err == nil {
		t.Fatal("expected error for unknown provider name")
	}
	if !errors.Is(err, proto.ErrInvalidRequest) {
		t.Errorf("want ErrInvalidRequest, got %v", err)
	}
}

// --- ProtoAgentRunner --------------------------------------------------------

// fakeProvider implements provider.Provider for bridge tests.
type fakeProvider struct {
	name    string
	result  *provider.Result
	err     error
	lastReq *provider.Request
}

func (f *fakeProvider) Name() string { return f.name }
func (f *fakeProvider) Tier() string { return provider.TierUnknown }
func (f *fakeProvider) RunAgent(_ context.Context, req *provider.Request) (*provider.Result, error) {
	f.lastReq = req
	return f.result, f.err
}

func TestProtoAgentRunner_EmptyProviderFallsBackToResolveProvider(t *testing.T) {
	// ProtoAgentRunner.Run converts proto request → provider request → result.
	fake := &fakeProvider{
		name:   "fake",
		result: &provider.Result{Outcome: provider.OutcomeSuccess, ExitCode: 0},
	}
	ar := &ProtoAgentRunner{P: fake}
	req := minimalRequest(t, "prompt content")

	res, err := ar.Run(context.Background(), req)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Errorf("Outcome: want %q, got %q", proto.OutcomeSuccess, res.Outcome)
	}
	if fake.lastReq == nil {
		t.Fatal("provider.RunAgent was not called")
	}
	if fake.lastReq.Prompt != "prompt content" {
		t.Errorf("Prompt passed to provider: want 'prompt content', got %q", fake.lastReq.Prompt)
	}
}

func TestProtoAgentRunner_PropagatesError(t *testing.T) {
	want := fmt.Errorf("upstream failure")
	fake := &fakeProvider{name: "fake", result: nil, err: want}
	ar := &ProtoAgentRunner{P: fake}
	req := minimalRequest(t, "test")

	_, err := ar.Run(context.Background(), req)
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, want) {
		t.Errorf("want %v, got %v", want, err)
	}
}
