package tools_test

import (
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/provider/tools"
)

// TestCanonicalTools_PassValidation asserts every named canonical tool passes
// ValidateToolSchema. This is the primary acceptance criterion for Goal 2.
func TestCanonicalTools_PassValidation(t *testing.T) {
	for _, tc := range []struct {
		name string
		tool provider.ToolSchema
	}{
		{"Read", tools.Read},
		{"Write", tools.Write},
		{"Edit", tools.Edit},
		{"Bash", tools.Bash},
		{"Glob", tools.Glob},
		{"Grep", tools.Grep},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := provider.ValidateToolSchema(tc.tool); err != nil {
				t.Errorf("canonical tool %q failed validation: %v", tc.name, err)
			}
		})
	}
}

// TestCanonicalTools_Names asserts each tool's Name field matches its
// expected canonical string — the cross-provider key all translators use.
func TestCanonicalTools_Names(t *testing.T) {
	want := map[string]provider.ToolSchema{
		"Read":  tools.Read,
		"Write": tools.Write,
		"Edit":  tools.Edit,
		"Bash":  tools.Bash,
		"Glob":  tools.Glob,
		"Grep":  tools.Grep,
	}
	for wantName, tool := range want {
		if tool.Name != wantName {
			t.Errorf("canonical tool Name: want %q, got %q", wantName, tool.Name)
		}
	}
}

// TestCanonicalTools_BehaviorHints asserts the BehaviorHints for each tool
// match documented intent (Read/file/shell classification).
func TestCanonicalTools_BehaviorHints(t *testing.T) {
	cases := []struct {
		name          string
		tool          provider.ToolSchema
		wantModifies  bool
		wantReads     bool
		wantExecShell bool
	}{
		{"Read", tools.Read, false, true, false},
		{"Write", tools.Write, true, false, false},
		{"Edit", tools.Edit, true, false, false},
		{"Bash", tools.Bash, false, false, true},
		{"Glob", tools.Glob, false, true, false},
		{"Grep", tools.Grep, false, true, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := tc.tool.BehaviorHints
			if h.ModifiesFiles != tc.wantModifies {
				t.Errorf("ModifiesFiles: want %v, got %v", tc.wantModifies, h.ModifiesFiles)
			}
			if h.Reads != tc.wantReads {
				t.Errorf("Reads: want %v, got %v", tc.wantReads, h.Reads)
			}
			if h.ExecutesShell != tc.wantExecShell {
				t.Errorf("ExecutesShell: want %v, got %v", tc.wantExecShell, h.ExecutesShell)
			}
		})
	}
}

// TestPerStageSlices asserts the four per-stage slices are non-empty and
// contain only tools with unique Names.
func TestPerStageSlices(t *testing.T) {
	slices := []struct {
		name  string
		slice []provider.ToolSchema
	}{
		{"CoderTools", tools.CoderTools},
		{"ReviewerTools", tools.ReviewerTools},
		{"TesterTools", tools.TesterTools},
		{"IntakeTools", tools.IntakeTools},
	}
	for _, tc := range slices {
		t.Run(tc.name, func(t *testing.T) {
			if len(tc.slice) == 0 {
				t.Fatalf("%s: slice must be non-empty", tc.name)
			}
			seen := make(map[string]bool, len(tc.slice))
			for _, tool := range tc.slice {
				if seen[tool.Name] {
					t.Errorf("%s: duplicate tool name %q", tc.name, tool.Name)
				}
				seen[tool.Name] = true
				if err := provider.ValidateToolSchema(tool); err != nil {
					t.Errorf("%s: tool %q failed validation: %v", tc.name, tool.Name, err)
				}
			}
		})
	}
}

// TestCoderTools_ContainsSixTools asserts CoderTools has the full coder set.
func TestCoderTools_ContainsSixTools(t *testing.T) {
	if got := len(tools.CoderTools); got != 6 {
		t.Errorf("CoderTools: want 6 tools, got %d", got)
	}
}

// TestIntakeTools_ReadOnly asserts IntakeTools contains no file-modifying tools.
func TestIntakeTools_ReadOnly(t *testing.T) {
	for _, tool := range tools.IntakeTools {
		if tool.BehaviorHints.ModifiesFiles || tool.BehaviorHints.ExecutesShell {
			t.Errorf("IntakeTools: tool %q has modifying/executing hints — IntakeTools should be read-only", tool.Name)
		}
	}
}

// TestReviewerTools_ContainsBash asserts ReviewerTools includes Bash (for
// running build checks) but not file-writing tools.
func TestReviewerTools_ContainsBash(t *testing.T) {
	found := false
	for _, tool := range tools.ReviewerTools {
		if tool.Name == "Bash" {
			found = true
		}
		if tool.BehaviorHints.ModifiesFiles {
			t.Errorf("ReviewerTools: tool %q modifies files — reviewers should not write", tool.Name)
		}
	}
	if !found {
		t.Error("ReviewerTools: Bash not found (reviewers need it for build checks)")
	}
}
