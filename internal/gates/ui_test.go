package gates

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// uiFakeRunner is the deterministic UICommandRunner used in tests. The
// outs / exits slices are consumed in order; calls past the end return the
// last value (so multi-retry tests don't need to over-specify).
type uiFakeRunner struct {
	outs       []string
	exits      []int
	envSeen    [][]string
	calls      int
	preCallErr error
}

func (r *uiFakeRunner) Run(_ context.Context, _ string, env []string, _ time.Duration) ([]byte, int, error) {
	if r.preCallErr != nil {
		return nil, 0, r.preCallErr
	}
	envCopy := append([]string(nil), env...)
	r.envSeen = append(r.envSeen, envCopy)
	idx := r.calls
	r.calls++
	if len(r.outs) == 0 {
		return nil, 0, nil
	}
	if idx >= len(r.outs) {
		idx = len(r.outs) - 1
	}
	out := r.outs[idx]
	exit := 0
	if idx < len(r.exits) {
		exit = r.exits[idx]
	}
	return []byte(out), exit, nil
}

func alwaysAvailable(string) bool { return true }

// TestUIPhase_SkipWhenCmdEmpty asserts the m31.2 default: no UI_TEST_CMD
// means skip.
func TestUIPhase_SkipWhenCmdEmpty(t *testing.T) {
	p := &UIPhase{Enabled: true}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusSkip {
		t.Errorf("Status = %v, want StatusSkip", r.Status)
	}
}

// TestUIPhase_SkipWhenDisabled — UI_VALIDATION_ENABLED=false short-circuits.
func TestUIPhase_SkipWhenDisabled(t *testing.T) {
	p := &UIPhase{Cmd: "playwright test", Enabled: false, CmdAvailable: alwaysAvailable}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusSkip {
		t.Errorf("Status = %v, want StatusSkip", r.Status)
	}
}

// TestUIPhase_SkipWhenBinaryMissing — checkUITestCmdAvailable returns false
// → phase skips with a warning instead of failing.
func TestUIPhase_SkipWhenBinaryMissing(t *testing.T) {
	p := &UIPhase{
		Cmd:          "some-nonexistent-binary test",
		Enabled:      true,
		CmdAvailable: func(string) bool { return false },
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusSkip {
		t.Errorf("Status = %v, want StatusSkip", r.Status)
	}
}

// TestUIPhase_PassFirstRun — exit 0 on the normal run → StatusPass and
// no remediation/retry attempted.
func TestUIPhase_PassFirstRun(t *testing.T) {
	runner := &uiFakeRunner{outs: []string{"ok"}, exits: []int{0}}
	p := &UIPhase{
		Cmd:          "playwright test",
		Enabled:      true,
		Framework:    FrameworkPlaywright,
		Runner:       runner,
		CmdAvailable: alwaysAvailable,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusPass {
		t.Fatalf("Status = %v, want StatusPass", r.Status)
	}
	if runner.calls != 1 {
		t.Errorf("runner.calls = %d, want 1", runner.calls)
	}
	if len(runner.envSeen) != 1 || !envContains(runner.envSeen[0], "PLAYWRIGHT_HTML_OPEN=never") {
		t.Errorf("first run env missing PLAYWRIGHT_HTML_OPEN=never: %v", runner.envSeen)
	}
	if envContains(runner.envSeen[0], "CI=1") {
		t.Errorf("first run env should NOT carry CI=1: %v", runner.envSeen[0])
	}
}

// TestUIPhase_AssertionFailWritesFailure — exit 1 with no timeout marker
// triggers one remediation try (we don't pass a Remediator) and one generic
// retry (which still fails), then writes the failure-path artifacts.
func TestUIPhase_AssertionFailWritesFailure(t *testing.T) {
	runner := &uiFakeRunner{
		outs:  []string{"AssertionError: foo", "AssertionError: foo"},
		exits: []int{1, 1},
	}
	w := &captureWriter{}
	p := &UIPhase{
		Cmd:          "playwright test",
		Enabled:      true,
		Framework:    FrameworkPlaywright,
		Runner:       runner,
		Errors:       w,
		CmdAvailable: alwaysAvailable,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "post-coder", Now: time.Now})
	if r.Status != StatusFail {
		t.Fatalf("Status = %v, want StatusFail", r.Status)
	}
	if !errors.Is(r.Err, ErrUITestFailed) {
		t.Errorf("Err = %v, want ErrUITestFailed", r.Err)
	}
	// With no Remediator and a non-timeout signature, the path is:
	//   run1 (fail) -> generic retry (fail) -> write failure.
	if runner.calls != 2 {
		t.Errorf("runner.calls = %d, want 2 (run + generic retry)", runner.calls)
	}
	if w.uiFailureExit != 1 {
		t.Errorf("captured exit = %d, want 1", w.uiFailureExit)
	}
	if w.uiFailureCmd != "playwright test" {
		t.Errorf("captured cmd = %q, want %q", w.uiFailureCmd, "playwright test")
	}
	if !strings.Contains(w.uiFailureOutput, "AssertionError") {
		t.Errorf("captured output missing 'AssertionError': %q", w.uiFailureOutput)
	}
	// Diagnosis block: signature is "none", normal applied yes, hardened no.
	if !strings.Contains(w.uiDiagnosisBlock, "Timeout class: none") {
		t.Errorf("diagnosis missing 'Timeout class: none': %q", w.uiDiagnosisBlock)
	}
	if !strings.Contains(w.uiDiagnosisBlock, "Hardened rerun attempted: no") {
		t.Errorf("diagnosis missing 'Hardened rerun attempted: no': %q", w.uiDiagnosisBlock)
	}
}

// TestUIPhase_InteractiveTimeoutTriggersHardened — exit 124 with HTML-report
// marker skips M54 remediation AND generic retry; runs hardened rerun once.
// In this test the hardened rerun also fails → terminal failure.
func TestUIPhase_InteractiveTimeoutTriggersHardened(t *testing.T) {
	const interactiveOut = "Serving HTML report at http://localhost:9323. Press Ctrl+C to quit."
	runner := &uiFakeRunner{
		outs:  []string{interactiveOut, interactiveOut},
		exits: []int{124, 124},
	}
	w := &captureWriter{}
	p := &UIPhase{
		Cmd:                  "playwright test",
		Enabled:              true,
		HardenedRetryEnabled: true,
		HardenedRetryFactor:  0.5,
		Framework:            FrameworkPlaywright,
		Timeout:              60 * time.Second,
		Runner:               runner,
		Errors:               w,
		CmdAvailable:         alwaysAvailable,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusFail {
		t.Fatalf("Status = %v, want StatusFail", r.Status)
	}
	// Exactly 2 calls: normal run + hardened rerun. No M54, no generic.
	if runner.calls != 2 {
		t.Errorf("runner.calls = %d, want 2 (run + hardened rerun only)", runner.calls)
	}
	// Hardened run env must carry CI=1.
	if !envContains(runner.envSeen[1], "CI=1") {
		t.Errorf("hardened run env missing CI=1: %v", runner.envSeen[1])
	}
	// Diagnosis block must report interactive_report + hardened attempted.
	if !strings.Contains(w.uiDiagnosisBlock, "Timeout class: interactive_report") {
		t.Errorf("diagnosis missing 'Timeout class: interactive_report': %q", w.uiDiagnosisBlock)
	}
	if !strings.Contains(w.uiDiagnosisBlock, "Hardened rerun attempted: yes") {
		t.Errorf("diagnosis missing 'Hardened rerun attempted: yes': %q", w.uiDiagnosisBlock)
	}
	if !strings.Contains(w.uiDiagnosisBlock, "Deterministic env applied: yes (hardened)") {
		t.Errorf("diagnosis missing hardened env label: %q", w.uiDiagnosisBlock)
	}
}

// TestUIPhase_HardenedRetryDisabledSkipsRerun — UI_GATE_ENV_RETRY_ENABLED=false
// makes the gate fail immediately on interactive_report signature.
func TestUIPhase_HardenedRetryDisabledSkipsRerun(t *testing.T) {
	const interactiveOut = "Serving HTML report at http://localhost:9323"
	runner := &uiFakeRunner{
		outs:  []string{interactiveOut},
		exits: []int{124},
	}
	w := &captureWriter{}
	p := &UIPhase{
		Cmd:                  "playwright test",
		Enabled:              true,
		HardenedRetryEnabled: false,
		Framework:            FrameworkPlaywright,
		Runner:               runner,
		Errors:               w,
		CmdAvailable:         alwaysAvailable,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusFail {
		t.Fatalf("Status = %v, want StatusFail", r.Status)
	}
	if runner.calls != 1 {
		t.Errorf("runner.calls = %d, want 1 (hardened retry disabled)", runner.calls)
	}
	if !strings.Contains(w.uiDiagnosisBlock, "Hardened rerun attempted: no") {
		t.Errorf("diagnosis missing 'Hardened rerun attempted: no': %q", w.uiDiagnosisBlock)
	}
}

// TestUIPhase_GenericTimeoutDiagnosis — exit 124 without HTML-report marker
// uses the generic_timeout branch (M54 + generic retry both fire, both fail).
func TestUIPhase_GenericTimeoutDiagnosis(t *testing.T) {
	runner := &uiFakeRunner{
		outs:  []string{"timeout", "timeout"},
		exits: []int{124, 124},
	}
	w := &captureWriter{}
	p := &UIPhase{
		Cmd:          "playwright test",
		Enabled:      true,
		Framework:    FrameworkPlaywright,
		Runner:       runner,
		Errors:       w,
		CmdAvailable: alwaysAvailable,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusFail {
		t.Fatalf("Status = %v, want StatusFail", r.Status)
	}
	if !strings.Contains(w.uiDiagnosisBlock, "Timeout class: generic_timeout") {
		t.Errorf("diagnosis missing 'Timeout class: generic_timeout': %q", w.uiDiagnosisBlock)
	}
}

// TestUIPhase_RemediationRetry — Remediator returns true on first fail; the
// retry then passes. No generic retry should fire.
func TestUIPhase_RemediationRetry(t *testing.T) {
	runner := &uiFakeRunner{
		outs:  []string{"some env_setup error", "ok"},
		exits: []int{1, 0},
	}
	rem := remediatorFunc(func(_ context.Context, _, _ string) bool { return true })
	p := &UIPhase{
		Cmd:          "playwright test",
		Enabled:      true,
		Framework:    FrameworkPlaywright,
		Runner:       runner,
		Remediator:   rem,
		CmdAvailable: alwaysAvailable,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusPass {
		t.Fatalf("Status = %v, want StatusPass", r.Status)
	}
	if runner.calls != 2 {
		t.Errorf("runner.calls = %d, want 2 (run + remediation retry, no generic)", runner.calls)
	}
}

// TestUIPhase_RemediationRetryAllFail — the 3-run scenario: M54 remediation
// fires AND its rerun fails AND the generic flakiness retry also fails.
// Regression pin for the full non-interactive failure path:
//   run #1 (exit 1) → Remediator returns true → run #2 (exit 1) →
//   generic retry → run #3 (exit 1) → terminal failure.
//
// Distinct from TestUIPhase_RemediationRetry (which only covers the 2-run
// pass path) and TestUIPhase_AssertionFailWritesFailure (which covers the
// 2-run no-Remediator path).
func TestUIPhase_RemediationRetryAllFail(t *testing.T) {
	runner := &uiFakeRunner{
		outs:  []string{"some env_setup error", "env_setup error again", "env_setup error final"},
		exits: []int{1, 1, 1},
	}
	rem := remediatorFunc(func(_ context.Context, _, _ string) bool { return true })
	w := &captureWriter{}
	p := &UIPhase{
		Cmd:          "playwright test",
		Enabled:      true,
		Framework:    FrameworkPlaywright,
		Runner:       runner,
		Remediator:   rem,
		Errors:       w,
		CmdAvailable: alwaysAvailable,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "post-coder", Now: time.Now})
	if r.Status != StatusFail {
		t.Fatalf("Status = %v, want StatusFail", r.Status)
	}
	if !errors.Is(r.Err, ErrUITestFailed) {
		t.Errorf("Err = %v, want ErrUITestFailed", r.Err)
	}
	// All three runs must fire: run #1, remediation rerun, generic retry.
	if runner.calls != 3 {
		t.Errorf("runner.calls = %d, want 3 (run + remediation rerun + generic retry)", runner.calls)
	}
	// Failure artifacts must be written.
	if w.uiFailureExit != 1 {
		t.Errorf("uiFailureExit = %d, want 1", w.uiFailureExit)
	}
	if w.uiFailureCmd != "playwright test" {
		t.Errorf("uiFailureCmd = %q, want %q", w.uiFailureCmd, "playwright test")
	}
	if !strings.Contains(w.uiFailureOutput, "env_setup error") {
		t.Errorf("uiFailureOutput missing expected text: %q", w.uiFailureOutput)
	}
	// Diagnosis block: signature is "none", hardened rerun not attempted.
	if !strings.Contains(w.uiDiagnosisBlock, "Timeout class: none") {
		t.Errorf("diagnosis missing 'Timeout class: none': %q", w.uiDiagnosisBlock)
	}
	if !strings.Contains(w.uiDiagnosisBlock, "Hardened rerun attempted: no") {
		t.Errorf("diagnosis missing 'Hardened rerun attempted: no': %q", w.uiDiagnosisBlock)
	}
}

// TestUIPhase_NonPlaywrightFrameworkSkipsEnv — when Framework == None the
// runner receives no env injection (the bash side short-circuited to no
// KEY=VALUE lines).
func TestUIPhase_NonPlaywrightFrameworkSkipsEnv(t *testing.T) {
	runner := &uiFakeRunner{outs: []string{"ok"}, exits: []int{0}}
	p := &UIPhase{
		Cmd:          "some other test",
		Enabled:      true,
		Framework:    FrameworkNone,
		Runner:       runner,
		CmdAvailable: alwaysAvailable,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusPass {
		t.Fatalf("Status = %v, want StatusPass", r.Status)
	}
	if envContains(runner.envSeen[0], "PLAYWRIGHT_HTML_OPEN=never") {
		t.Errorf("non-playwright framework should not inject PLAYWRIGHT_HTML_OPEN; got %v", runner.envSeen[0])
	}
}

// TestUIPhase_RunnerErrorBecomesFailure — a runner that returns a non-nil
// error becomes a Fail without writing the failure-path artifacts (no clear
// stage label / cmd context inside the error path).
func TestUIPhase_RunnerErrorBecomesFailure(t *testing.T) {
	runner := &uiFakeRunner{preCallErr: errors.New("subprocess died")}
	p := &UIPhase{
		Cmd:          "playwright test",
		Enabled:      true,
		Framework:    FrameworkPlaywright,
		Runner:       runner,
		CmdAvailable: alwaysAvailable,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusFail {
		t.Fatalf("Status = %v, want StatusFail", r.Status)
	}
	if !strings.Contains(r.Err.Error(), "subprocess died") {
		t.Errorf("Err = %v, want to contain 'subprocess died'", r.Err)
	}
}

// TestUIPhase_NameIsUITest covers the Phase.Name() accessor.
func TestUIPhase_NameIsUITest(t *testing.T) {
	p := &UIPhase{}
	if got := p.Name(); got != "ui_test" {
		t.Errorf("Name() = %q, want %q", got, "ui_test")
	}
}

// TestUIPhase_NilReceiverSkips covers the defensive nil guard.
func TestUIPhase_NilReceiverSkips(t *testing.T) {
	var p *UIPhase
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusSkip {
		t.Errorf("Status = %v, want StatusSkip", r.Status)
	}
}

// TestCheckUITestCmdAvailable covers the npx/npm/PATH guard.
func TestCheckUITestCmdAvailable(t *testing.T) {
	if !checkUITestCmdAvailable("npx playwright test") {
		t.Error("npx should always be considered available")
	}
	if !checkUITestCmdAvailable("npm test") {
		t.Error("npm should always be considered available")
	}
	if checkUITestCmdAvailable("") {
		t.Error("empty cmd should NOT be considered available")
	}
	// bash should be on PATH in CI.
	if !checkUITestCmdAvailable("bash") {
		t.Error("bash should resolve via PATH in CI")
	}
	if checkUITestCmdAvailable("nonexistent-test-binary-xyzzy") {
		t.Error("nonexistent binary should NOT be available")
	}
}

// envContains reports whether env carries kv as one of its entries.
func envContains(env []string, kv string) bool {
	for _, e := range env {
		if e == kv {
			return true
		}
	}
	return false
}
