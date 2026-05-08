package runner

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestBashHookRunnerPreflightSkipWhenNoHome(t *testing.T) {
	h := &BashHookRunner{}
	req := &proto.RunRequestV1{ProjectDir: t.TempDir()}
	if err := h.Preflight(context.Background(), req); err != nil {
		t.Fatalf("want nil for empty TekhtonHome; got %v", err)
	}
}

func TestBashHookRunnerPreflightSkipsMissingScript(t *testing.T) {
	tmp := t.TempDir() // no lib/preflight.sh present
	h := &BashHookRunner{TekhtonHome: tmp}
	req := &proto.RunRequestV1{ProjectDir: t.TempDir()}
	if err := h.Preflight(context.Background(), req); err != nil {
		t.Fatalf("want nil when script absent; got %v", err)
	}
}

func TestBashHookRunnerFinalizeSkipsMissingScript(t *testing.T) {
	tmp := t.TempDir()
	h := &BashHookRunner{TekhtonHome: tmp}
	req := &proto.RunRequestV1{ProjectDir: t.TempDir()}
	res := &proto.RunResultV1{Disposition: proto.RunDispositionSuccess}
	if err := h.Finalize(context.Background(), req, res); err != nil {
		t.Fatalf("want nil when script absent; got %v", err)
	}
}

func TestBashHookRunnerPreflightInvokesScript(t *testing.T) {
	home := t.TempDir()
	libDir := filepath.Join(home, "lib")
	if err := os.MkdirAll(libDir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(libDir, "preflight.sh")
	// Write a script that creates a marker file in the project dir.
	body := "#!/usr/bin/env bash\ntouch \"$PROJECT_DIR/preflight.marker\"\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	proj := t.TempDir()
	h := &BashHookRunner{TekhtonHome: home}
	req := &proto.RunRequestV1{ProjectDir: proj}
	if err := h.Preflight(context.Background(), req); err != nil {
		t.Fatalf("preflight: %v", err)
	}
	if _, err := os.Stat(filepath.Join(proj, "preflight.marker")); err != nil {
		t.Fatalf("preflight script did not run: %v", err)
	}
}

func TestBashHookRunnerFinalizeSetsDispositionEnv(t *testing.T) {
	home := t.TempDir()
	libDir := filepath.Join(home, "lib")
	if err := os.MkdirAll(libDir, 0o755); err != nil {
		t.Fatal(err)
	}
	proj := t.TempDir()
	// Script writes the disposition env var to a marker file.
	body := `#!/usr/bin/env bash
echo "$TEKHTON_RUN_DISPOSITION" > "$PROJECT_DIR/disposition.txt"
`
	if err := os.WriteFile(filepath.Join(libDir, "finalize.sh"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	h := &BashHookRunner{TekhtonHome: home}
	req := &proto.RunRequestV1{ProjectDir: proj}
	res := &proto.RunResultV1{Disposition: proto.RunDispositionStuck}
	if err := h.Finalize(context.Background(), req, res); err != nil {
		t.Fatalf("finalize: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(proj, "disposition.txt"))
	if string(got) != "stuck\n" {
		t.Fatalf("disposition env var: got %q want stuck", string(got))
	}
}

func TestStdoutOrStderrOrFallsBack(t *testing.T) {
	if stdoutOr(nil) != os.Stdout {
		t.Fatalf("stdoutOr(nil) should return os.Stdout")
	}
	if stderrOr(nil) != os.Stderr {
		t.Fatalf("stderrOr(nil) should return os.Stderr")
	}
}

func TestRunSingleNilPipelineResult(t *testing.T) {
	req := validReq(t)
	fp := &fakePipeline{} // no results queued → returns nil, nil
	r := New(fp)
	res, err := r.RunSingle(context.Background(), req)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if res.Disposition != proto.RunDispositionFailure {
		t.Fatalf("want failure when no result; got %q", res.Disposition)
	}
}

func TestRunCompleteLoopReturnsErrorOnPipelineError(t *testing.T) {
	req := validReq(t)
	bang := errors.New("explode")
	fp := &fakePipeline{
		results: []*proto.PipelineAttemptResultV1{nil},
		errs:    []error{bang},
	}
	r := New(fp)
	_, err := r.RunCompleteLoop(context.Background(), req)
	if err == nil {
		t.Fatalf("want error from pipeline; got nil")
	}
}

func TestRunSingleResumeFails(t *testing.T) {
	r := New(&fakePipeline{})
	_, err := r.Resume(context.Background())
	if err == nil {
		t.Fatalf("Resume without state store should fail")
	}
}
