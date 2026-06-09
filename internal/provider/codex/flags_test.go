package codex

import (
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// baseRequest returns a minimal valid provider.Request with ProviderSpecific
// pinned so buildExecArgs doesn't rely on os.Getwd() or os.CreateTemp —
// making tests deterministic regardless of the working directory.
func baseRequest() *provider.Request {
	return &provider.Request{
		Prompt: "do the thing",
		ProviderSpecific: map[string]string{
			"codex.cwd":                 "/tmp/testproject",
			"codex.output_last_message": "/tmp/tekhton-codex-last-test.md",
		},
	}
}

// containsSeq returns true if argv contains the sub-sequence [...elems...] in
// order at adjacent positions.
func containsSeq(argv, seq []string) bool {
	if len(seq) == 0 {
		return true
	}
	for i := 0; i <= len(argv)-len(seq); i++ {
		match := true
		for j, s := range seq {
			if argv[i+j] != s {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

// containsFlag returns true if flag appears in argv as a standalone element.
func containsFlag(argv []string, flag string) bool {
	for _, a := range argv {
		if a == flag {
			return true
		}
	}
	return false
}

// TestBuildExecArgs_DefaultsPresent verifies that the three mandatory
// automation flags are always emitted regardless of request content.
// Codex must run with --json (NDJSON output), --sandbox workspace-write
// (file mutation allowed), and --skip-git-repo-check (non-git dirs OK).
func TestBuildExecArgs_DefaultsPresent(t *testing.T) {
	req := baseRequest()
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("buildExecArgs: %v", err)
	}
	for _, flag := range []string{"--json", "--sandbox", "--skip-git-repo-check"} {
		if !containsFlag(args, flag) {
			t.Errorf("missing mandatory flag %q in argv %v", flag, args)
		}
	}
	if !containsSeq(args, []string{"--sandbox", "workspace-write"}) {
		t.Errorf("--sandbox must be followed by workspace-write, got %v", args)
	}
}

// TestBuildExecArgs_StdinMarker asserts "-" is the final element of argv.
// The Codex CLI reads the prompt from stdin when "-" is the last positional arg.
func TestBuildExecArgs_StdinMarker(t *testing.T) {
	req := baseRequest()
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("buildExecArgs: %v", err)
	}
	if len(args) == 0 {
		t.Fatal("buildExecArgs returned empty argv")
	}
	if last := args[len(args)-1]; last != "-" {
		t.Errorf("last argv element must be \"-\" (stdin marker), got %q", last)
	}
}

// TestBuildExecArgs_ModelOverride verifies --model is included when req.Model
// is set, and omitted entirely when req.Model is empty.
func TestBuildExecArgs_ModelOverride(t *testing.T) {
	t.Run("model_set", func(t *testing.T) {
		req := baseRequest()
		req.Model = "o4-mini"
		args, err := buildExecArgs(req)
		if err != nil {
			t.Fatalf("buildExecArgs: %v", err)
		}
		if !containsSeq(args, []string{"--model", "o4-mini"}) {
			t.Errorf("--model o4-mini not found in argv %v", args)
		}
	})

	t.Run("model_empty", func(t *testing.T) {
		req := baseRequest()
		req.Model = ""
		args, err := buildExecArgs(req)
		if err != nil {
			t.Fatalf("buildExecArgs: %v", err)
		}
		if containsFlag(args, "--model") {
			t.Errorf("--model must be omitted when req.Model is empty, got %v", args)
		}
	})
}

// TestBuildExecArgs_CwdFromProviderSpecific verifies --cd uses the
// codex.cwd ProviderSpecific key when set.
func TestBuildExecArgs_CwdFromProviderSpecific(t *testing.T) {
	req := baseRequest()
	req.ProviderSpecific["codex.cwd"] = "/custom/workdir"
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("buildExecArgs: %v", err)
	}
	if !containsSeq(args, []string{"--cd", "/custom/workdir"}) {
		t.Errorf("--cd /custom/workdir not found in argv %v", args)
	}
}

// TestBuildExecArgs_OutputLastMessage verifies --output-last-message is
// present in argv, pointing at the pinned fixture path.
func TestBuildExecArgs_OutputLastMessage(t *testing.T) {
	req := baseRequest()
	const wantPath = "/tmp/tekhton-codex-last-test.md"
	req.ProviderSpecific["codex.output_last_message"] = wantPath
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("buildExecArgs: %v", err)
	}
	if !containsSeq(args, []string{"--output-last-message", wantPath}) {
		t.Errorf("--output-last-message %q not found in argv %v", wantPath, args)
	}
}

// TestBuildExecArgs_InlineConfig verifies that ProviderSpecific keys
// prefixed with "codex.config." are emitted as -c KEY=VALUE pairs.
func TestBuildExecArgs_InlineConfig(t *testing.T) {
	req := baseRequest()
	req.ProviderSpecific["codex.config.model.context_length"] = "8192"
	req.ProviderSpecific["codex.config.tools.shell.enabled"] = "true"
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("buildExecArgs: %v", err)
	}
	// Each inline config pair must appear as consecutive -c KEY=VAL entries.
	found8192 := containsSeq(args, []string{"-c", "model.context_length=8192"})
	foundShell := containsSeq(args, []string{"-c", "tools.shell.enabled=true"})
	if !found8192 {
		t.Errorf("-c model.context_length=8192 not found in argv %v", args)
	}
	if !foundShell {
		t.Errorf("-c tools.shell.enabled=true not found in argv %v", args)
	}
}

// TestBuildExecArgs_EmptyPromptError verifies buildExecArgs returns an
// error when req.Prompt is empty — an empty prompt is a caller bug.
func TestBuildExecArgs_EmptyPromptError(t *testing.T) {
	req := baseRequest()
	req.Prompt = ""
	_, err := buildExecArgs(req)
	if err == nil {
		t.Error("buildExecArgs with empty prompt: want error, got nil")
	}
	if err != nil && !strings.Contains(err.Error(), "empty prompt") {
		t.Errorf("error should mention 'empty prompt', got: %v", err)
	}
}

// TestBuildExecArgs_NoInlineConfigForOtherKeys asserts that non-config
// ProviderSpecific keys (codex.cwd, codex.output_last_message) do NOT
// appear as -c entries.
func TestBuildExecArgs_NoInlineConfigForOtherKeys(t *testing.T) {
	req := baseRequest()
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("buildExecArgs: %v", err)
	}
	for i, a := range args {
		if a == "-c" && i+1 < len(args) {
			val := args[i+1]
			if strings.HasPrefix(val, "codex.cwd=") ||
				strings.HasPrefix(val, "codex.output_last_message=") {
				t.Errorf("internal ProviderSpecific key leaked into -c argv: %q", val)
			}
		}
	}
}

// TestBuildExecArgs_FirstArgIsExec asserts "exec" is the first element of
// the returned argv (the codex subcommand).
func TestBuildExecArgs_FirstArgIsExec(t *testing.T) {
	req := baseRequest()
	args, err := buildExecArgs(req)
	if err != nil {
		t.Fatalf("buildExecArgs: %v", err)
	}
	if len(args) == 0 || args[0] != "exec" {
		t.Errorf("first argv element must be \"exec\", got %v", args)
	}
}
