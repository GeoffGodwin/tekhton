package codex

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// newReqWithOut builds a minimal Request with a fixed output_last_message so
// tests don't produce tempfiles and can do deterministic argv assertions.
func newReqWithOut(t *testing.T, mutate func(*provider.Request)) *provider.Request {
	t.Helper()
	req := &provider.Request{
		Prompt: "test prompt",
		ProviderSpecific: map[string]string{
			"codex.output_last_message": t.TempDir() + "/last.md",
		},
	}
	if mutate != nil {
		mutate(req)
	}
	return req
}

func TestBuildExecArgs_DefaultsPresent(t *testing.T) {
	req := newReqWithOut(t, nil)
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	for _, flag := range []string{"--json", "--skip-git-repo-check"} {
		if !slices.Contains(args, flag) {
			t.Errorf("expected flag %q in argv %v", flag, args)
		}
	}

	// --sandbox workspace-write appears as two consecutive elements.
	sandboxIdx := slices.Index(args, "--sandbox")
	if sandboxIdx == -1 || sandboxIdx+1 >= len(args) || args[sandboxIdx+1] != "workspace-write" {
		t.Errorf("expected --sandbox workspace-write in argv %v", args)
	}
}

func TestBuildExecArgs_StdinMarker(t *testing.T) {
	req := newReqWithOut(t, nil)
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if args[len(args)-1] != "-" {
		t.Errorf("expected trailing \"-\" in argv, got %q", args[len(args)-1])
	}
}

func TestBuildExecArgs_ModelOverride(t *testing.T) {
	req := newReqWithOut(t, func(r *provider.Request) {
		r.Model = "gpt-4o"
	})
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	modelIdx := slices.Index(args, "--model")
	if modelIdx == -1 || modelIdx+1 >= len(args) || args[modelIdx+1] != "gpt-4o" {
		t.Errorf("expected --model gpt-4o in argv %v", args)
	}
}

func TestBuildExecArgs_ModelOmittedWhenEmpty(t *testing.T) {
	req := newReqWithOut(t, func(r *provider.Request) { r.Model = "" })
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if slices.Contains(args, "--model") {
		t.Errorf("unexpected --model flag in argv when Model is empty: %v", args)
	}
}

func TestBuildExecArgs_CwdOverride(t *testing.T) {
	req := newReqWithOut(t, func(r *provider.Request) {
		r.ProviderSpecific["codex.cwd"] = "/tmp/custom"
	})
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	cdIdx := slices.Index(args, "--cd")
	if cdIdx == -1 || cdIdx+1 >= len(args) || args[cdIdx+1] != "/tmp/custom" {
		t.Errorf("expected --cd /tmp/custom in argv %v", args)
	}
}

func TestBuildExecArgs_OutputLastMessage(t *testing.T) {
	outPath := t.TempDir() + "/custom.md"
	req := &provider.Request{
		Prompt: "prompt",
		ProviderSpecific: map[string]string{
			"codex.output_last_message": outPath,
		},
	}
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	olmIdx := slices.Index(args, "--output-last-message")
	if olmIdx == -1 || olmIdx+1 >= len(args) || args[olmIdx+1] != outPath {
		t.Errorf("expected --output-last-message %s in argv %v", outPath, args)
	}
}

func TestBuildExecArgs_InlineConfig(t *testing.T) {
	req := newReqWithOut(t, func(r *provider.Request) {
		r.ProviderSpecific["codex.config.model.provider"] = "openai"
	})
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Look for the exact -c model.provider=openai entry.
	found := false
	for i, a := range args {
		if a == "-c" && i+1 < len(args) && args[i+1] == "model.provider=openai" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected -c model.provider=openai in argv %v", args)
	}
}

func TestBuildExecArgs_EmptyPromptError(t *testing.T) {
	req := &provider.Request{
		Prompt:           "",
		ProviderSpecific: map[string]string{},
	}
	_, err := buildExecArgs(req)
	if err == nil {
		t.Fatal("expected error for empty prompt, got nil")
	}
}

func TestBuildExecArgs_FirstElementIsExec(t *testing.T) {
	req := newReqWithOut(t, nil)
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(args) == 0 || args[0] != "exec" {
		t.Errorf("expected first arg to be \"exec\", got %v", args)
	}
}

// TestMakeOutputLastMessagePath_ErrorWhenTmpUnavailable verifies that
// makeOutputLastMessagePath returns a non-nil error when os.CreateTemp
// cannot create the tempfile (e.g., TMPDIR points to a non-existent
// directory). This covers the error branch that was previously untested.
func TestMakeOutputLastMessagePath_ErrorWhenTmpUnavailable(t *testing.T) {
	// Point TMPDIR at a path that cannot exist, causing os.CreateTemp to fail.
	t.Setenv("TMPDIR", "/nonexistent-tekhton-test-dir-should-not-exist")

	req := &provider.Request{
		Prompt:           "test",
		ProviderSpecific: map[string]string{},
		// codex.output_last_message intentionally absent — forces os.CreateTemp path.
	}
	path, err := makeOutputLastMessagePath(req)
	if err == nil {
		t.Fatalf("expected error when TMPDIR is unavailable, got path %q", path)
	}
	if path != "" {
		t.Errorf("expected empty path on error, got %q", path)
	}
}

// TestMakeOutputLastMessagePath_CreatesTempfile verifies that when
// codex.output_last_message is absent from ProviderSpecific, a temp file is
// created on disk and its path is returned. This is the path that RunAgent
// propagates to Result.LastReportPath.
func TestMakeOutputLastMessagePath_CreatesTempfile(t *testing.T) {
	// Redirect os.CreateTemp("", ...) to a controlled directory.
	dir := t.TempDir()
	t.Setenv("TMPDIR", dir)

	req := &provider.Request{
		Prompt:           "test",
		ProviderSpecific: map[string]string{},
	}
	path, err := makeOutputLastMessagePath(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if path == "" {
		t.Fatal("makeOutputLastMessagePath returned empty path")
	}
	if _, statErr := os.Stat(path); statErr != nil {
		t.Errorf("tempfile %q was not created on disk: %v", path, statErr)
	}
	base := filepath.Base(path)
	if !strings.HasPrefix(base, "tekhton-codex-last-") {
		t.Errorf("tempfile name %q does not match expected prefix tekhton-codex-last-*", base)
	}
}
