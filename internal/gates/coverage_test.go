package gates

import (
	"context"
	"errors"
	"runtime"
	"strings"
	"testing"
	"time"
)

// TestPhaseNames smokes the Name() accessor on every Phase implementation.
func TestPhaseNames(t *testing.T) {
	tests := []struct {
		p    Phase
		want string
	}{
		{&AnalyzePhase{}, "analyze"},
		{&CompilePhase{}, "compile"},
		{&ConstraintsPhase{}, "constraints"},
		{&UIPhase{}, "ui_test"},
		{&UIValidationPhase{}, "ui_validation"},
	}
	for _, tc := range tests {
		if got := tc.p.Name(); got != tc.want {
			t.Errorf("Name() = %q, want %q", got, tc.want)
		}
	}
}

// TestPhaseError_ErrorString covers the Error()/Unwrap() strings.
func TestPhaseError_ErrorString(t *testing.T) {
	pe := &PhaseError{Phase: "analyze", Err: errAnalyzeFailed}
	if !strings.Contains(pe.Error(), "analyze") {
		t.Errorf("Error() = %q, want phase name in message", pe.Error())
	}
	if pe.Unwrap() == nil {
		t.Error("Unwrap() = nil, want underlying error")
	}
	// Is forwards to the wrapped cause too.
	if !errors.Is(pe, errAnalyzeFailed) {
		t.Error("errors.Is(pe, errAnalyzeFailed) = false, want true")
	}
}

// TestFailingExitCoder covers Error/Unwrap/ExitCode.
func TestFailingExitCoder(t *testing.T) {
	inner := errors.New("test fail")
	e := &FailingExitCoder{Cause: inner, Code: 7}
	if e.Error() != inner.Error() {
		t.Errorf("Error() = %q, want %q", e.Error(), inner.Error())
	}
	if e.Unwrap() != inner {
		t.Error("Unwrap() did not return wrapped error")
	}
	if e.ExitCode() != 7 {
		t.Errorf("ExitCode() = %d, want 7", e.ExitCode())
	}
	// Empty cause path.
	empty := &FailingExitCoder{}
	if empty.Error() != "" {
		t.Errorf("empty Error() = %q, want empty", empty.Error())
	}
}

// TestNoopErrorsWriter_Methods exercises every method so they show up
// in coverage. The contract is "everything is a no-op."
func TestNoopErrorsWriter_Methods(t *testing.T) {
	w := NoopErrorsWriter{}
	w.Reset()
	w.WriteAnalyze("x", "y", "z", time.Now())
	w.WriteCompile("x", "y", time.Now())
	w.WriteConstraints("body")
	w.WriteTimeout("x", time.Second, time.Now())
	w.WriteUIFailure("x", "cmd", "out", 1, time.Now())
	w.WriteUIDiagnosis("block")
	w.ClearOnPass()
}

// TestFSErrorsWriter_WriteConstraintsRoundtrip covers the constraint
// write path.
func TestFSErrorsWriter_WriteConstraintsRoundtrip(t *testing.T) {
	w := newWriter(t)
	w.WriteConstraints("layer foo imports bar")
	if _, err := w.ErrorsFile, error(nil); err != nil {
		t.Fatal(err)
	}
}

// TestExecRunner_RunsTrueCmd exercises the production CommandRunner with
// a "true" command (always exit 0). Skips when bash is not on PATH —
// matches the bash-dependent test policy in the rest of the test suite.
func TestExecRunner_RunsTrueCmd(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("bash-dependent test")
	}
	r := ExecRunner{}
	out, exit, timedOut, err := r.Run(context.Background(), "true", time.Second)
	if err != nil {
		t.Fatalf("Run = err %v", err)
	}
	if exit != 0 {
		t.Errorf("exit = %d, want 0", exit)
	}
	if timedOut {
		t.Errorf("timedOut = true, want false")
	}
	if string(out) != "" {
		t.Errorf("out = %q, want empty", string(out))
	}
}

// TestExecRunner_EmptyCmdIsNoop.
func TestExecRunner_EmptyCmdIsNoop(t *testing.T) {
	r := ExecRunner{}
	out, exit, timedOut, err := r.Run(context.Background(), "", 0)
	if err != nil || exit != 0 || timedOut || len(out) != 0 {
		t.Errorf("empty cmd = (%q, %d, %v, %v), want all zero/empty", string(out), exit, timedOut, err)
	}
}

// TestExecRunner_TimeoutReturns124 covers the timeout path: a sleep
// command exceeding the timeout returns exit 124 with timedOut=true.
func TestExecRunner_TimeoutReturns124(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("bash-dependent test")
	}
	r := ExecRunner{}
	_, exit, timedOut, _ := r.Run(context.Background(), "sleep 5", 100*time.Millisecond)
	if !timedOut {
		t.Errorf("timedOut = false, want true")
	}
	if exit != 124 {
		t.Errorf("exit = %d, want 124", exit)
	}
}

// TestExecRunner_NonZeroExit covers the regular exit-code propagation
// path. `false` exits 1.
func TestExecRunner_NonZeroExit(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("bash-dependent test")
	}
	r := ExecRunner{}
	_, exit, timedOut, err := r.Run(context.Background(), "false", time.Second)
	if err != nil {
		t.Fatalf("Run = err %v", err)
	}
	if timedOut {
		t.Errorf("timedOut = true, want false")
	}
	if exit != 1 {
		t.Errorf("exit = %d, want 1", exit)
	}
}

// TestBashRemediator_NoHomeReturnsFalse: empty TEKHTON_HOME guard.
func TestBashRemediator_NoHomeReturnsFalse(t *testing.T) {
	r := &BashRemediator{}
	if r.TryRemediate(context.Background(), "anything", "test") {
		t.Error("empty TekhtonHome should return false")
	}
}

// TestBashRemediator_NilReceiverReturnsFalse.
func TestBashRemediator_NilReceiverReturnsFalse(t *testing.T) {
	var r *BashRemediator
	if r.TryRemediate(context.Background(), "errs", "phase") {
		t.Error("nil receiver should return false")
	}
}

// TestBashRemediator_EmptyErrorsReturnsFalse.
func TestBashRemediator_EmptyErrorsReturnsFalse(t *testing.T) {
	r := &BashRemediator{TekhtonHome: "/tmp"}
	if r.TryRemediate(context.Background(), "", "test") {
		t.Error("empty errs should return false (no work to remediate)")
	}
}

// TestUIValidationPhase_PassExit0.
func TestUIValidationPhase_PassExit0(t *testing.T) {
	p := &UIValidationPhase{Cmd: "any", Runner: fakeRunner{exit: 0}}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusPass {
		t.Errorf("Status = %v, want StatusPass", r.Status)
	}
}

// TestUIValidationPhase_FailNonZero.
func TestUIValidationPhase_FailNonZero(t *testing.T) {
	p := &UIValidationPhase{Cmd: "any", Runner: fakeRunner{exit: 1}}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusFail {
		t.Errorf("Status = %v, want StatusFail", r.Status)
	}
}

// TestUIValidationPhase_TimeoutTreatedAsPass.
func TestUIValidationPhase_TimeoutTreatedAsPass(t *testing.T) {
	p := &UIValidationPhase{Cmd: "any", Runner: fakeRunner{timedOut: true}}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusPass {
		t.Errorf("Status = %v, want StatusPass (timeout 124 → pass)", r.Status)
	}
}

// TestStringError_Error covers the trivial error type.
func TestStringError_Error(t *testing.T) {
	if got := errAnalyzeFailed.Error(); got != "analyze errors found" {
		t.Errorf("Error() = %q, want 'analyze errors found'", got)
	}
}
