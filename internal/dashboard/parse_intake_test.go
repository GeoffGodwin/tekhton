// parse_intake_test.go — table-driven coverage for ParseIntake.

package dashboard

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseIntake_InlineFormat(t *testing.T) {
	r := &StatusReader{}
	got, err := r.ParseIntake("testdata/parsers/intake/inline.md")
	if err != nil {
		t.Fatalf("ParseIntake: %v", err)
	}
	if got.Verdict != "PASS" {
		t.Errorf("verdict: want PASS, got %q", got.Verdict)
	}
	if got.Confidence != 82 {
		t.Errorf("confidence: want 82, got %d", got.Confidence)
	}
	if got.TaskText == "" {
		t.Error("task_text: want non-empty (Tweaked Content section populated)")
	}
}

func TestParseIntake_HeaderFormat(t *testing.T) {
	r := &StatusReader{}
	got, err := r.ParseIntake("testdata/parsers/intake/header.md")
	if err != nil {
		t.Fatalf("ParseIntake: %v", err)
	}
	if got.Verdict != "NEEDS_WORK" {
		t.Errorf("verdict: want NEEDS_WORK, got %q", got.Verdict)
	}
	if got.Confidence != 40 {
		t.Errorf("confidence: want 40, got %d", got.Confidence)
	}
}

func TestParseIntake_MissingFile(t *testing.T) {
	r := &StatusReader{}
	got, err := r.ParseIntake("/nonexistent/intake.md")
	if err != nil {
		t.Fatalf("want nil err on missing file, got %v", err)
	}
	if got.Verdict != "unknown" {
		t.Errorf("missing-file verdict: want 'unknown', got %q", got.Verdict)
	}
	if got.Confidence != 0 {
		t.Errorf("missing-file confidence: want 0, got %d", got.Confidence)
	}
}

func TestParseIntake_MalformedNoVerdict(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "malformed.md")
	if err := os.WriteFile(path, []byte("# Random\n\nNothing useful here.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := &StatusReader{}
	got, _ := r.ParseIntake(path)
	if got.Verdict != "unknown" {
		t.Errorf("malformed verdict: want 'unknown', got %q", got.Verdict)
	}
}

func TestExtractTweakedContent_Capping(t *testing.T) {
	content := `# Header
## Tweaked Content

line 1
line 2
line 3
line 4
line 5
line 6 should NOT appear

## Next Section
should not be reached
`
	got := extractTweakedContent(content)
	if got == "" {
		t.Fatal("expected non-empty extraction")
	}
	if contains := "line 6"; len(got) > 0 && containsString(got, contains) {
		t.Errorf("5-line cap violated; line 6 surfaced: %q", got)
	}
	for _, want := range []string{"line 1", "line 2", "line 3", "line 4", "line 5"} {
		if !containsString(got, want) {
			t.Errorf("missing %q in extracted text: %q", want, got)
		}
	}
}

func containsString(haystack, needle string) bool {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}
