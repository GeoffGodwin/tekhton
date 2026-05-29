package detect

import (
	"strings"
	"testing"
)

// TestRenderMatchesBashShape asserts the Go report formatter produces the
// section headers and table-row format that lib/detect_report.sh emits.
// Byte-for-byte parity against the captured baselines is enforced by
// tests/test_detect_parity.sh; this Go-side test guards the smaller
// shape-of-render contract.
func TestRenderMatchesBashShape(t *testing.T) {
	s := &Summary{
		ProjectDir:     "/p",
		ProjectTypeStr: "web-app",
		Languages: []Language{
			{Name: "typescript", Confidence: "high", Manifest: "package.json"},
		},
		Frameworks: []Framework{
			{Name: "react", Language: "node", Evidence: `"react" in package.json dependencies`},
		},
	}
	got := Render(s)

	mustContain := []string{
		"## Tech Stack Detection Report",
		"### Project Type: web-app",
		"### Languages",
		"| Language | Confidence | Manifest |",
		"|----------|------------|----------|",
		"| typescript | high | package.json |",
		"### Frameworks",
		"| Framework | Language | Evidence |",
		"|-----------|----------|----------|",
		"| react | node | \"react\" in package.json dependencies |",
		"### Detected Commands",
		"(none detected)",
		"### Entry Points",
	}
	for _, want := range mustContain {
		if !strings.Contains(got, want) {
			t.Errorf("Render output missing %q\n--- output ---\n%s", want, got)
		}
	}
}

// TestRender_EmptyLanguages emits the "(none detected)" placeholder row
// so the bash baseline shape is preserved.
func TestRender_EmptyLanguages(t *testing.T) {
	s := &Summary{ProjectDir: "/p"}
	got := Render(s)
	if !strings.Contains(got, "| (none detected) | — | — |") {
		t.Errorf("expected empty-languages placeholder row; got:\n%s", got)
	}
	if !strings.Contains(got, "### Project Type: custom") {
		t.Errorf("expected fallback 'custom' project type; got:\n%s", got)
	}
}

// TestRender_FrameworkNoneDetected exercises the bare "(none detected)"
// line emitted when frameworks are empty (vs the table form).
func TestRender_FrameworkNoneDetected(t *testing.T) {
	s := &Summary{
		ProjectDir: "/p",
		Languages: []Language{
			{Name: "go", Confidence: "high", Manifest: "go.mod"},
		},
	}
	got := Render(s)
	lines := strings.Split(got, "\n")
	for i, line := range lines {
		if line == "### Frameworks" {
			if i+1 >= len(lines) || lines[i+1] != "(none detected)" {
				t.Errorf("expected '(none detected)' immediately after ### Frameworks; got %q", lines[i+1])
			}
			return
		}
	}
	t.Errorf("Render did not emit ### Frameworks section:\n%s", got)
}
