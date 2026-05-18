package runner

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/manifest"
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

// TestBashHookRunnerFinalizeSkipsMissingScript verifies the contract that
// Finalize never returns an error to its caller even when the bash shim
// dispatcher is absent. Post-m21 each bash-shim hook fails individually
// inside the Go orchestrator, but the chain is continue-on-error so the
// runner observes no error.
func TestBashHookRunnerFinalizeSkipsMissingScript(t *testing.T) {
	tmp := t.TempDir()
	h := &BashHookRunner{TekhtonHome: tmp}
	req := &proto.RunRequestV1{ProjectDir: t.TempDir()}
	res := &proto.RunResultV1{Disposition: proto.RunDispositionSuccess}
	if err := h.Finalize(context.Background(), req, res); err != nil {
		t.Fatalf("want nil when shim absent; got %v", err)
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

// TestBashHookRunnerFinalizeSetsDispositionEnv verifies the disposition
// flows through to bash-shim hooks via TEKHTON_RUN_DISPOSITION. Post-m21
// the Go orchestrator dispatches each bash hook through lib/finalize_shim.sh
// rather than a monolithic lib/finalize.sh, so the test substitutes a stub
// shim that captures the env var on its first invocation.
func TestBashHookRunnerFinalizeSetsDispositionEnv(t *testing.T) {
	home := t.TempDir()
	libDir := filepath.Join(home, "lib")
	if err := os.MkdirAll(libDir, 0o755); err != nil {
		t.Fatal(err)
	}
	proj := t.TempDir()
	// Stub shim: append disposition + hook name to a marker file on each call.
	body := `#!/usr/bin/env bash
echo "${TEKHTON_RUN_DISPOSITION}:$1" >> "$PROJECT_DIR/disposition.txt"
`
	if err := os.WriteFile(filepath.Join(libDir, "finalize_shim.sh"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	h := &BashHookRunner{TekhtonHome: home}
	req := &proto.RunRequestV1{ProjectDir: proj}
	res := &proto.RunResultV1{Disposition: proto.RunDispositionStuck}
	if err := h.Finalize(context.Background(), req, res); err != nil {
		t.Fatalf("finalize: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(proj, "disposition.txt"))
	if len(got) == 0 {
		t.Fatalf("expected at least one bash-shim invocation; got empty marker file")
	}
	if string(got[:5]) != "stuck" {
		t.Fatalf("disposition env var: got %q (expected to start with 'stuck')", string(got))
	}
}

// TestBashHookRunnerFinalizeMilestoneSuccessRunsCompletionHooks verifies
// the milestone-disposition wiring fix: when Mode==milestone and the run
// succeeded, the runner must stamp MilestoneDisposition so the three
// Go-native completion hooks (clear_state / mark_done / archive_milestone)
// actually do their work. Without the fix, the bash shim hooks see
// _CACHED_DISPOSITION="" through the entire chain.
func TestBashHookRunnerFinalizeMilestoneSuccessRunsCompletionHooks(t *testing.T) {
	home := t.TempDir()
	libDir := filepath.Join(home, "lib")
	if err := os.MkdirAll(libDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `#!/usr/bin/env bash
echo "${_CACHED_DISPOSITION}" >> "$PROJECT_DIR/disposition.txt"
`
	if err := os.WriteFile(filepath.Join(libDir, "finalize_shim.sh"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	proj := t.TempDir()
	// Seed the milestone state file so clear_state has something to remove.
	if err := os.MkdirAll(filepath.Join(proj, ".claude"), 0o755); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(proj, ".claude", "MILESTONE_STATE.md")
	if err := os.WriteFile(statePath, []byte("pending"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &BashHookRunner{TekhtonHome: home}
	req := &proto.RunRequestV1{
		ProjectDir: proj,
		Mode:       proto.RunModeMilestone,
		Milestone:  "m21",
	}
	res := &proto.RunResultV1{Disposition: proto.RunDispositionSuccess}
	if err := h.Finalize(context.Background(), req, res); err != nil {
		t.Fatalf("finalize: %v", err)
	}
	// _CACHED_DISPOSITION must have been stamped to COMPLETE_AND_CONTINUE
	// for shim invocations (proves runner populated MilestoneDisposition).
	got, _ := os.ReadFile(filepath.Join(proj, "disposition.txt"))
	if !strings.Contains(string(got), "COMPLETE_AND_CONTINUE") {
		t.Fatalf("expected COMPLETE_AND_CONTINUE in shim env; got %q", got)
	}
	// _hook_clear_state is Go-native and runs first among the completion
	// gates — it should have removed MILESTONE_STATE.md.
	if _, err := os.Stat(statePath); !os.IsNotExist(err) {
		t.Errorf("expected MILESTONE_STATE.md removed by clear_state; got err=%v", err)
	}
}

// TestBashHookRunnerFinalizeFailureSkipsCompletionHooks verifies the
// inverse: a failed run must NOT trigger the milestone-completion hooks
// even when Mode==milestone. The disposition gate stays empty in that case.
func TestBashHookRunnerFinalizeFailureSkipsCompletionHooks(t *testing.T) {
	home := t.TempDir()
	libDir := filepath.Join(home, "lib")
	if err := os.MkdirAll(libDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `#!/usr/bin/env bash
echo "disposition=[${_CACHED_DISPOSITION}]" >> "$PROJECT_DIR/disposition.txt"
`
	if err := os.WriteFile(filepath.Join(libDir, "finalize_shim.sh"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	proj := t.TempDir()
	if err := os.MkdirAll(filepath.Join(proj, ".claude"), 0o755); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(proj, ".claude", "MILESTONE_STATE.md")
	if err := os.WriteFile(statePath, []byte("pending"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &BashHookRunner{TekhtonHome: home}
	req := &proto.RunRequestV1{
		ProjectDir: proj,
		Mode:       proto.RunModeMilestone,
		Milestone:  "m21",
	}
	res := &proto.RunResultV1{Disposition: proto.RunDispositionFailure}
	if err := h.Finalize(context.Background(), req, res); err != nil {
		t.Fatalf("finalize: %v", err)
	}
	// Failed run = empty MilestoneDisposition = state file untouched.
	if _, err := os.Stat(statePath); err != nil {
		t.Errorf("expected MILESTONE_STATE.md to remain on failure; got %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(proj, "disposition.txt"))
	if strings.Contains(string(got), "COMPLETE_AND_CONTINUE") {
		t.Errorf("failed run must not stamp COMPLETE_AND_CONTINUE; got %q", got)
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

// TestBashHookRunnerFinalizeNilResult verifies the nil-res guard:
// Finalize must return nil (not panic) when called with a nil result envelope.
// The guard is reachable when a pipeline attempt returns (nil, err) and the
// runner still calls Finalize to run cleanup hooks.
func TestBashHookRunnerFinalizeNilResult(t *testing.T) {
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, "lib"), 0o755); err != nil {
		t.Fatal(err)
	}
	h := &BashHookRunner{TekhtonHome: home}
	req := &proto.RunRequestV1{ProjectDir: t.TempDir()}
	if err := h.Finalize(context.Background(), req, nil); err != nil {
		t.Fatalf("Finalize with nil result: want nil, got %v", err)
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

// TestBashHookRunnerFinalizeMarkDoneFlipsManifestStatus is the integration
// test the cycle-1 reviewer flagged as missing: _hook_mark_done runs inside
// the full BashHookRunner.Finalize chain and must actually flip the
// MANIFEST.cfg status from "todo" to "done" when the milestone succeeds.
// Without this test the unit-level mark_done_test.go coverage is not
// sufficient to prove the chain wires up correctly end-to-end.
func TestBashHookRunnerFinalizeMarkDoneFlipsManifestStatus(t *testing.T) {
	home := t.TempDir()
	libDir := filepath.Join(home, "lib")
	if err := os.MkdirAll(libDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Stub shim so bash hooks do not emit "file not found" noise; the
	// chain is continue-on-error so absent bash hooks don't block Go hooks.
	shimBody := "#!/usr/bin/env bash\n"
	if err := os.WriteFile(filepath.Join(libDir, "finalize_shim.sh"), []byte(shimBody), 0o755); err != nil {
		t.Fatal(err)
	}

	proj := t.TempDir()
	// Seed MANIFEST.cfg with m21 in "todo" state.
	milestoneDir := filepath.Join(proj, ".claude", "milestones")
	if err := os.MkdirAll(milestoneDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(milestoneDir, "MANIFEST.cfg")
	manifestContent := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m21|Finalize Orchestrator Port|todo||m21-finalize-orchestrator-port.md|\n"
	if err := os.WriteFile(manifestPath, []byte(manifestContent), 0o644); err != nil {
		t.Fatal(err)
	}

	h := &BashHookRunner{TekhtonHome: home}
	req := &proto.RunRequestV1{
		ProjectDir: proj,
		Mode:       proto.RunModeMilestone,
		Milestone:  "m21",
	}
	res := &proto.RunResultV1{Disposition: proto.RunDispositionSuccess}
	if err := h.Finalize(context.Background(), req, res); err != nil {
		t.Fatalf("Finalize: %v", err)
	}

	// Load the manifest and assert the status field flipped to "done".
	m, err := manifest.Load(manifestPath)
	if err != nil {
		t.Fatalf("manifest.Load after Finalize: %v", err)
	}
	entry, ok := m.Get("m21")
	if !ok {
		t.Fatalf("m21 entry missing from manifest after Finalize")
	}
	if entry.Status != "done" {
		t.Errorf("MANIFEST.cfg entry status = %q, want %q", entry.Status, "done")
	}
}
