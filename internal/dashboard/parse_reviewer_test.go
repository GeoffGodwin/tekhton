// parse_reviewer_test.go — table-driven coverage for ParseReviewer.

package dashboard

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseReviewer_Golden(t *testing.T) {
	r := &StatusReader{}
	got, err := r.ParseReviewer("testdata/parsers/reviewer/golden.md")
	if err != nil {
		t.Fatalf("ParseReviewer: %v", err)
	}
	if got.Verdict != "APPROVED_WITH_NOTES" {
		t.Errorf("verdict: want APPROVED_WITH_NOTES, got %q", got.Verdict)
	}
}

func TestParseReviewer_MissingFile(t *testing.T) {
	r := &StatusReader{}
	got, err := r.ParseReviewer("/nonexistent/path.md")
	if err != nil {
		t.Fatalf("want nil err, got %v", err)
	}
	if got.Verdict != "unknown" {
		t.Errorf("missing-file verdict: want 'unknown', got %q", got.Verdict)
	}
}

func TestParseReviewer_NoVerdictSection(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "no_verdict.md")
	if err := os.WriteFile(path, []byte("# Reviewer Report\n\nNothing useful here.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := &StatusReader{}
	got, _ := r.ParseReviewer(path)
	if got.Verdict != "unknown" {
		t.Errorf("no-verdict: want 'unknown', got %q", got.Verdict)
	}
}

func TestParseReviewer_VerdictWithBlankBefore(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "with_blank.md")
	body := `## Verdict

APPROVED
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	r := &StatusReader{}
	got, _ := r.ParseReviewer(path)
	if got.Verdict != "APPROVED" {
		t.Errorf("blank-then-verdict: want APPROVED, got %q", got.Verdict)
	}
}
