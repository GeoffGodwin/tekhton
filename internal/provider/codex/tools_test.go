package codex

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/provider/tools"
)

// toolTranslationFixture is the recorded expected output for translateTools.
type toolTranslationFixture struct {
	ExtraArgs       []string `json:"extra_args"`
	SandboxOverride string   `json:"sandbox_override"`
}

func loadToolTranslationFixture(t *testing.T, name string) toolTranslationFixture {
	t.Helper()
	path := filepath.Join("testdata", "tool_translations", name+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("fixture %q: %v", name, err)
	}
	var f toolTranslationFixture
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatalf("fixture %q: unmarshal: %v", name, err)
	}
	return f
}

// TestTranslateTools_Empty verifies that an empty tool set produces no extra
// args, no sandbox override, and no error — Codex's defaults are preserved.
func TestTranslateTools_Empty(t *testing.T) {
	fix := loadToolTranslationFixture(t, "empty")
	extraArgs, sandboxOverride, err := translateTools([]provider.ToolSchema{})
	if err != nil {
		t.Fatalf("unexpected error for empty tools: %v", err)
	}
	if sandboxOverride != fix.SandboxOverride {
		t.Errorf("sandboxOverride = %q, want %q", sandboxOverride, fix.SandboxOverride)
	}
	if !reflect.DeepEqual(extraArgs, fix.ExtraArgs) {
		t.Errorf("extraArgs = %v, want %v", extraArgs, fix.ExtraArgs)
	}
}

// TestTranslateTools_NilTools verifies that a nil slice is treated identically
// to an empty slice — Codex's defaults are preserved.
func TestTranslateTools_NilTools(t *testing.T) {
	extraArgs, sandboxOverride, err := translateTools(nil)
	if err != nil {
		t.Fatalf("unexpected error for nil tools: %v", err)
	}
	if sandboxOverride != "" {
		t.Errorf("sandboxOverride = %q, want %q", sandboxOverride, "")
	}
	if extraArgs != nil {
		t.Errorf("extraArgs = %v, want nil", extraArgs)
	}
}

// TestTranslateTools_CoderFixture verifies that CoderTools (Read/Write/Edit/Bash/Glob/Grep)
// translates to workspace-write sandbox and the expected -c tools.allowed entry.
func TestTranslateTools_CoderFixture(t *testing.T) {
	fix := loadToolTranslationFixture(t, "coder")
	extraArgs, sandboxOverride, err := translateTools(tools.CoderTools)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sandboxOverride != fix.SandboxOverride {
		t.Errorf("sandboxOverride = %q, want %q", sandboxOverride, fix.SandboxOverride)
	}
	if !reflect.DeepEqual(extraArgs, fix.ExtraArgs) {
		t.Errorf("extraArgs = %v, want %v", extraArgs, fix.ExtraArgs)
	}
}

// TestTranslateTools_ReviewerFixture verifies that ReviewerTools (Read/Glob/Grep/Bash)
// produces workspace-write (Bash is present) and the expected allowed list.
func TestTranslateTools_ReviewerFixture(t *testing.T) {
	fix := loadToolTranslationFixture(t, "reviewer")
	extraArgs, sandboxOverride, err := translateTools(tools.ReviewerTools)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sandboxOverride != fix.SandboxOverride {
		t.Errorf("sandboxOverride = %q, want %q", sandboxOverride, fix.SandboxOverride)
	}
	if !reflect.DeepEqual(extraArgs, fix.ExtraArgs) {
		t.Errorf("extraArgs = %v, want %v", extraArgs, fix.ExtraArgs)
	}
}

// TestTranslateTools_TesterFixture verifies that TesterTools translates
// identically to CoderTools (both have the full Read/Write/Edit/Bash/Glob/Grep set).
func TestTranslateTools_TesterFixture(t *testing.T) {
	fix := loadToolTranslationFixture(t, "tester")
	extraArgs, sandboxOverride, err := translateTools(tools.TesterTools)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sandboxOverride != fix.SandboxOverride {
		t.Errorf("sandboxOverride = %q, want %q", sandboxOverride, fix.SandboxOverride)
	}
	if !reflect.DeepEqual(extraArgs, fix.ExtraArgs) {
		t.Errorf("extraArgs = %v, want %v", extraArgs, fix.ExtraArgs)
	}
}

// TestTranslateTools_IntakeFixture verifies that IntakeTools (Read/Glob/Grep — no
// shell or write tools) produces read-only sandbox, satisfying the safety goal
// that intake agents cannot write to the codebase.
func TestTranslateTools_IntakeFixture(t *testing.T) {
	fix := loadToolTranslationFixture(t, "intake")
	extraArgs, sandboxOverride, err := translateTools(tools.IntakeTools)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sandboxOverride != "read-only" {
		t.Errorf("sandboxOverride = %q, want %q", sandboxOverride, "read-only")
	}
	if sandboxOverride != fix.SandboxOverride {
		t.Errorf("sandboxOverride = %q, want %q (from fixture)", sandboxOverride, fix.SandboxOverride)
	}
	if !reflect.DeepEqual(extraArgs, fix.ExtraArgs) {
		t.Errorf("extraArgs = %v, want %v", extraArgs, fix.ExtraArgs)
	}
}

// TestTranslateTools_ErrorOnInvalidSchema verifies that a ToolSchema with an
// empty Name triggers a validation error before any translation proceeds.
func TestTranslateTools_ErrorOnInvalidSchema(t *testing.T) {
	bad := provider.ToolSchema{
		Name:        "",
		Description: "a tool with no name",
		Parameters:  provider.ParameterSchema{Type: "object"},
	}
	_, _, err := translateTools([]provider.ToolSchema{bad})
	if err == nil {
		t.Fatal("expected error for ToolSchema with empty Name, got nil")
	}
}

// TestTranslateTools_UnknownToolFallback verifies that a tool whose Name is not
// in the codexToolMap falls back to the "shell" permission key and does NOT
// return an error. This preserves forward-compat with future Tekhton tools
// before they are added to the mapping table.
func TestTranslateTools_UnknownToolFallback(t *testing.T) {
	fix := loadToolTranslationFixture(t, "unknown")

	// The unknown tool has ExecutesShell=true to drive workspace-write sandbox.
	unknown := provider.ToolSchema{
		Name:        "UnknownTool",
		Description: "A tool not in the codex mapping table.",
		Parameters:  provider.ParameterSchema{Type: "object"},
		BehaviorHints: provider.BehaviorHints{
			ExecutesShell: true,
		},
	}
	extraArgs, sandboxOverride, err := translateTools([]provider.ToolSchema{unknown})
	if err != nil {
		t.Fatalf("unexpected error for unknown tool: %v", err)
	}
	if sandboxOverride != fix.SandboxOverride {
		t.Errorf("sandboxOverride = %q, want %q", sandboxOverride, fix.SandboxOverride)
	}
	if !reflect.DeepEqual(extraArgs, fix.ExtraArgs) {
		t.Errorf("extraArgs = %v, want %v", extraArgs, fix.ExtraArgs)
	}
}

// TestJoinAllowed_ProducesJSONLikeArray verifies that joinAllowed formats names
// as a bracketed, comma-separated list of double-quoted identifiers compatible
// with Codex's inline-config array syntax.
func TestJoinAllowed_ProducesJSONLikeArray(t *testing.T) {
	cases := []struct {
		input []string
		want  string
	}{
		{[]string{"fs_read"}, `["fs_read"]`},
		{[]string{"fs_read", "shell"}, `["fs_read","shell"]`},
		{[]string{"fs_read", "fs_write", "shell"}, `["fs_read","fs_write","shell"]`},
	}
	for _, tc := range cases {
		got := joinAllowed(tc.input)
		if got != tc.want {
			t.Errorf("joinAllowed(%v) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

// TestTranslateTools_SandboxWorkspaceWriteWhenModifiesFiles verifies that a
// tool with ModifiesFiles=true (but no ExecutesShell) produces workspace-write
// sandbox — covering the Write/Edit path explicitly.
func TestTranslateTools_SandboxWorkspaceWriteWhenModifiesFiles(t *testing.T) {
	writeOnly := provider.ToolSchema{
		Name:          "Write",
		Description:   "Write content to a file.",
		Parameters:    provider.ParameterSchema{Type: "object"},
		BehaviorHints: provider.BehaviorHints{ModifiesFiles: true},
	}
	_, sandboxOverride, err := translateTools([]provider.ToolSchema{writeOnly})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sandboxOverride != "workspace-write" {
		t.Errorf("sandboxOverride = %q, want %q", sandboxOverride, "workspace-write")
	}
}

// TestCodexToolName_KnownNames verifies that all six canonical Tekhton tool
// names resolve to a non-empty Codex permission key.
func TestCodexToolName_KnownNames(t *testing.T) {
	canonical := []string{"Read", "Write", "Edit", "Bash", "Glob", "Grep"}
	for _, name := range canonical {
		got, ok := codexToolName(name)
		if !ok {
			t.Errorf("codexToolName(%q) = (%q, false), want (non-empty, true)", name, got)
		}
		if got == "" {
			t.Errorf("codexToolName(%q) returned empty permission key", name)
		}
	}
}

// TestCodexToolName_UnknownName verifies that an unknown tool name returns
// ("", false) so callers can safely route to the catch-all.
func TestCodexToolName_UnknownName(t *testing.T) {
	got, ok := codexToolName("NotATekhtonTool")
	if ok {
		t.Errorf("codexToolName(%q) = (%q, true), want (\"\", false)", "NotATekhtonTool", got)
	}
	if got != "" {
		t.Errorf("codexToolName(%q) returned non-empty key %q on miss", "NotATekhtonTool", got)
	}
}
