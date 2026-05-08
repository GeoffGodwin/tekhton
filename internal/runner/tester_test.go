package runner

// tester_test.go — coverage gaps closed by the m19 tester pass.
// Each test targets a specific uncovered branch identified via go tool cover.

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
)

// TestRunSinglePipelineError verifies that when Pipeline.RunAttempt returns a
// non-nil error RunSingle propagates it to the caller and records
// disposition=failure in the result (single.go:57-59 + return).
func TestRunSinglePipelineError(t *testing.T) {
	req := validReq(t)
	boom := errors.New("pipeline exploded")
	fp := &fakePipeline{errs: []error{boom}}
	fh := &fakeHooks{}
	r := New(fp)
	r.Hooks = fh

	res, err := r.RunSingle(context.Background(), req)
	if !errors.Is(err, boom) {
		t.Fatalf("want boom error propagated; got %v", err)
	}
	if res == nil {
		t.Fatalf("res should be non-nil even when pipeline errors")
	}
	if res.Disposition != proto.RunDispositionFailure {
		t.Fatalf("want failure disposition; got %q", res.Disposition)
	}
	if !strings.Contains(res.ErrorMessage, "pipeline exploded") {
		t.Fatalf("ErrorMessage %q missing pipeline error text", res.ErrorMessage)
	}
	// Finalize is still called on pipeline error (non-preflight exit).
	if fh.finalizeCalls == 0 {
		t.Fatalf("finalize should be called even when pipeline errors")
	}
}

// TestRunCompleteLoopContextCanceled verifies that a pre-canceled context
// causes RunCompleteLoop to exit immediately with the context error and
// disposition=failure (complete.go:69-73).
func TestRunCompleteLoopContextCanceled(t *testing.T) {
	req := validReq(t)
	fp := &fakePipeline{} // should never be called

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // pre-cancel

	r := New(fp)
	res, err := r.RunCompleteLoop(ctx, req)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want context.Canceled; got %v", err)
	}
	if res.Disposition != proto.RunDispositionFailure {
		t.Fatalf("want failure on context cancel; got %q", res.Disposition)
	}
	if !strings.Contains(res.ErrorMessage, "context canceled") {
		t.Fatalf("ErrorMessage %q missing context-canceled text", res.ErrorMessage)
	}
	// Pipeline must not be invoked when context is already done.
	if fp.calls != 0 {
		t.Fatalf("pipeline called %d times despite canceled context", fp.calls)
	}
}

// TestRunCompleteLoopNilResultNilError verifies the nil-result-nil-error path
// in the loop (complete.go:120-125): when Pipeline.RunAttempt returns (nil,nil)
// the loop terminates with failure and a descriptive error.
func TestRunCompleteLoopNilResultNilError(t *testing.T) {
	req := validReq(t)
	// fakePipeline with no entries returns (nil, nil) on every call.
	fp := &fakePipeline{}
	r := New(fp)

	res, err := r.RunCompleteLoop(context.Background(), req)
	if err == nil {
		t.Fatalf("want non-nil error for nil pipeline result")
	}
	if res.Disposition != proto.RunDispositionFailure {
		t.Fatalf("want failure; got %q", res.Disposition)
	}
	if !strings.Contains(res.ErrorMessage, "no result") {
		t.Fatalf("ErrorMessage %q missing 'no result'", res.ErrorMessage)
	}
}

// TestResumeLegacyFormatError verifies that Resume surfaces a meaningful error
// when the state file is in the pre-m03 V3 markdown format (resume.go:32-33).
func TestResumeLegacyFormatError(t *testing.T) {
	tmp := t.TempDir()
	stateFile := filepath.Join(tmp, "PIPELINE_STATE.json")
	// A file starting with "## " triggers ErrLegacyFormat in state.Store.Read.
	if err := os.WriteFile(stateFile, []byte("## Pipeline State\n\nstage: coder\n"), 0o644); err != nil {
		t.Fatalf("write legacy state: %v", err)
	}
	store := state.New(stateFile)
	r := New(&fakePipeline{})
	r.State = store
	r.ProjectDir = tmp
	r.TekhtonHome = t.TempDir()

	_, err := r.Resume(context.Background())
	if err == nil {
		t.Fatalf("want error for legacy state file")
	}
	if !strings.Contains(err.Error(), "legacy") {
		t.Fatalf("error %q should mention 'legacy'", err.Error())
	}
	if !strings.Contains(err.Error(), "migrate") {
		t.Fatalf("error %q should suggest migration", err.Error())
	}
}

// TestBashHookRunnerFinalizeSkipWhenNoHome verifies that Finalize is a no-op
// when TekhtonHome is empty (runner.go:235-237), matching Preflight behavior.
func TestBashHookRunnerFinalizeSkipWhenNoHome(t *testing.T) {
	h := &BashHookRunner{} // empty TekhtonHome
	req := &proto.RunRequestV1{ProjectDir: t.TempDir()}
	res := &proto.RunResultV1{Disposition: proto.RunDispositionSuccess}
	if err := h.Finalize(context.Background(), req, res); err != nil {
		t.Fatalf("want nil for empty TekhtonHome; got %v", err)
	}
}

// TestApplyEnvDefaultsNilRequest verifies that ApplyEnvDefaults is a no-op
// when req is nil, preventing nil-pointer panics in callers (resume.go:84).
func TestApplyEnvDefaultsNilRequest(t *testing.T) {
	// Must not panic.
	ApplyEnvDefaults(nil, "/project", "/home")
}
