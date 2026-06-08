package review

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	reviewparse "github.com/geoffgodwin/tekhton/internal/review"
)

// TestRework_ComplexOnly_RoutesSeniorCoder — complex>0, simple=0 routes ONLY
// to the senior coder rework. Critically asserts the prompt template name is
// "coder_rework" (NOT "coder").
func TestRework_ComplexOnly_RoutesSeniorCoder(t *testing.T) {
	_, req := setupProject(t)
	ag := &fakeProvider{}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate, nil, nil)
	defer restore()
	cfg := loadConfig(req)

	report := &reviewparse.Report{
		ComplexBlockers: []string{"refactor auth"},
	}
	_, err := runRework(context.Background(), &cfg, report, reviewparse.CycleBudget{Current: 1, Max: 3}, &nullLogger{})
	if err != nil {
		t.Fatalf("runRework: %v", err)
	}
	if len(ag.Calls) != 1 {
		t.Fatalf("agent calls=%d want 1", len(ag.Calls))
	}
	call := ag.Calls[0]
	if !strings.HasPrefix(call.Label, "Coder (rework") {
		t.Errorf("wrong agent label: %q want 'Coder (rework ...)'", call.Label)
	}
	if call.Model != cfg.CoderModel {
		t.Errorf("model=%q want %q", call.Model, cfg.CoderModel)
	}
	if len(gate.Calls) != 1 || gate.Calls[0] != "post-fix-pass" {
		t.Errorf("gate calls=%v want [post-fix-pass]", gate.Calls)
	}
}

// TestRework_ComplexAndSimple_RoutesBoth — complex>0 AND simple>0 routes
// both senior coder rework AND jr coder follow-up. Asserts JR_AFTER_SENIOR
// is set to "yes" on the jr call.
func TestRework_ComplexAndSimple_RoutesBoth(t *testing.T) {
	_, req := setupProject(t)
	ag := &fakeProvider{}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate, nil, nil)
	defer restore()
	cfg := loadConfig(req)

	report := &reviewparse.Report{
		ComplexBlockers: []string{"refactor auth"},
		SimpleBlockers:  []string{"typo in README"},
	}
	_, err := runRework(context.Background(), &cfg, report, reviewparse.CycleBudget{Current: 1, Max: 3}, &nullLogger{})
	if err != nil {
		t.Fatalf("runRework: %v", err)
	}
	if len(ag.Calls) != 2 {
		t.Fatalf("agent calls=%d want 2 (senior + jr)", len(ag.Calls))
	}
	if !strings.HasPrefix(ag.Calls[0].Label, "Coder (rework") {
		t.Errorf("first call=%q want senior rework", ag.Calls[0].Label)
	}
	if !strings.HasPrefix(ag.Calls[1].Label, "Jr Coder (cycle") {
		t.Errorf("second call=%q want jr cycle", ag.Calls[1].Label)
	}
}

// TestRework_SimpleOnly_RoutesJrCoder — complex=0, simple>0 routes ONLY to
// jr coder, NOT to senior. JR_AFTER_SENIOR is empty.
func TestRework_SimpleOnly_RoutesJrCoder(t *testing.T) {
	_, req := setupProject(t)
	ag := &fakeProvider{}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate, nil, nil)
	defer restore()
	cfg := loadConfig(req)

	report := &reviewparse.Report{
		SimpleBlockers: []string{"typo in README"},
	}
	_, err := runRework(context.Background(), &cfg, report, reviewparse.CycleBudget{Current: 1, Max: 3}, &nullLogger{})
	if err != nil {
		t.Fatalf("runRework: %v", err)
	}
	if len(ag.Calls) != 1 {
		t.Fatalf("agent calls=%d want 1", len(ag.Calls))
	}
	if !strings.HasPrefix(ag.Calls[0].Label, "Jr Coder (cycle") {
		t.Errorf("agent label=%q want jr cycle", ag.Calls[0].Label)
	}
	if ag.Calls[0].Model != cfg.JrCoderModel {
		t.Errorf("model=%q want %q", ag.Calls[0].Model, cfg.JrCoderModel)
	}
}

// TestRework_BuildGateFailure_EscalatesAndRecovers — build gate fails, the
// escalation invokes build_fix_minimal, the retry passes.
func TestRework_BuildGateFailure_EscalatesAndRecovers(t *testing.T) {
	_, req := setupProject(t)
	ag := &fakeProvider{}
	gate := &fakeBuildGate{
		Behaviors: []error{errors.New("broken"), nil},
	}
	restore := installSeams(t, ag, gate, nil, nil)
	defer restore()
	cfg := loadConfig(req)

	report := &reviewparse.Report{
		ComplexBlockers: []string{"X"},
	}
	_, err := runRework(context.Background(), &cfg, report, reviewparse.CycleBudget{Current: 1, Max: 3}, &nullLogger{})
	if err != nil {
		t.Fatalf("runRework: %v", err)
	}
	if len(ag.Calls) != 2 {
		t.Fatalf("agent calls=%d want 2 (rework + build_fix_minimal)", len(ag.Calls))
	}
	if !strings.Contains(ag.Calls[1].Label, "build fix") {
		t.Errorf("escalation label=%q want build-fix variant", ag.Calls[1].Label)
	}
	if len(gate.Calls) != 2 || gate.Calls[1] != "post-fix-pass-retry" {
		t.Errorf("gate calls=%v want [post-fix-pass, post-fix-pass-retry]", gate.Calls)
	}
}

// TestRework_BuildGateRetryFails_PropagatesError — retry build gate also
// fails; runRework returns a non-nil error.
func TestRework_BuildGateRetryFails_PropagatesError(t *testing.T) {
	_, req := setupProject(t)
	ag := &fakeProvider{}
	gate := &fakeBuildGate{
		Behaviors: []error{errors.New("broken"), errors.New("still broken")},
	}
	restore := installSeams(t, ag, gate, nil, nil)
	defer restore()
	cfg := loadConfig(req)

	report := &reviewparse.Report{
		ComplexBlockers: []string{"X"},
	}
	_, err := runRework(context.Background(), &cfg, report, reviewparse.CycleBudget{Current: 1, Max: 3}, &nullLogger{})
	if err == nil {
		t.Fatal("expected non-nil err from build_failure_after_retry")
	}
	if !strings.Contains(err.Error(), "build_failure_after_retry") {
		t.Errorf("err=%v want build_failure_after_retry", err)
	}
}

// TestRework_AgentErrorPropagates — an agent runner error surfaces as a
// non-nil err from runRework.
func TestRework_AgentErrorPropagates(t *testing.T) {
	_, req := setupProject(t)
	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(*provider.Request) (*provider.Result, error) {
				return nil, errors.New("provider exploded")
			},
		},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate, nil, nil)
	defer restore()
	cfg := loadConfig(req)

	report := &reviewparse.Report{ComplexBlockers: []string{"X"}}
	_, err := runRework(context.Background(), &cfg, report, reviewparse.CycleBudget{Current: 1, Max: 3}, &nullLogger{})
	if err == nil {
		t.Fatal("expected err to propagate")
	}
	if !strings.Contains(err.Error(), "senior coder rework") {
		t.Errorf("err=%v want 'senior coder rework' context", err)
	}
}

// TestRework_CoderReworkPromptBody_ContainsReworkHeader reads the actual temp
// prompt file dispatched to the senior coder agent and asserts it contains the
// distinctive "## Rework Task" header from coder_rework.prompt.md — making the
// "NOT coder.prompt.md" requirement explicit and verifiable without reading the
// implementation. Also asserts the coder.prompt.md-exclusive "## Security
// Directive" header is absent.
func TestRework_CoderReworkPromptBody_ContainsReworkHeader(t *testing.T) {
	_, req := setupProject(t)
	var capturedBody string
	ag := &fakeProvider{
		Behaviors: []func(*provider.Request) (*provider.Result, error){
			func(r *provider.Request) (*provider.Result, error) {
				capturedBody = r.Prompt
				return &provider.Result{
					Outcome:   provider.OutcomeSuccess,
					ExitCode:  0,
					TurnsUsed: 5,
				}, nil
			},
		},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate, nil, nil)
	defer restore()
	cfg := loadConfig(req)

	report := &reviewparse.Report{
		ComplexBlockers: []string{"refactor auth"},
	}
	_, err := runRework(context.Background(), &cfg, report, reviewparse.CycleBudget{Current: 1, Max: 3}, &nullLogger{})
	if err != nil {
		t.Fatalf("runRework: %v", err)
	}
	if capturedBody == "" {
		t.Fatal("prompt body was not captured — behavior may not have fired or PromptFile was empty")
	}

	// coder_rework.prompt.md distinctive header — must be present.
	if !strings.Contains(capturedBody, "## Rework Task") {
		t.Errorf("prompt body missing '## Rework Task' header — coder_rework.prompt.md was not rendered")
	}
	// coder_rework.prompt.md distinctive instruction — must be present.
	if !strings.Contains(capturedBody, "Complex Blockers") {
		t.Errorf("prompt body missing 'Complex Blockers' reference — coder_rework.prompt.md was not rendered")
	}
	// coder.prompt.md exclusive header — must be absent.
	if strings.Contains(capturedBody, "## Security Directive") {
		t.Errorf("prompt body contains '## Security Directive' — coder.prompt.md was incorrectly rendered instead of coder_rework.prompt.md")
	}
}
