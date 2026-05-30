// parse_security_test.go — table-driven coverage for ParseSecurity.

package dashboard

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseSecurity_Golden(t *testing.T) {
	r := &StatusReader{}
	got, err := r.ParseSecurity("testdata/parsers/security/golden.md")
	if err != nil {
		t.Fatalf("ParseSecurity: %v", err)
	}
	if len(got.Findings) != 5 {
		t.Fatalf("findings count: want 5 (4 from Findings + 1 from Resolved Findings), got %d", len(got.Findings))
	}
	wantSeverities := []string{"CRITICAL", "HIGH", "MEDIUM", "LOW", "HIGH"}
	for i, want := range wantSeverities {
		if got.Findings[i].Severity != want {
			t.Errorf("findings[%d].severity: want %q, got %q", i, want, got.Findings[i].Severity)
		}
	}
	if got.Findings[0].Category != "A03" {
		t.Errorf("findings[0].category: want A03, got %q", got.Findings[0].Category)
	}
	if got.Findings[1].Category != "A01" {
		t.Errorf("findings[1].category: want A01, got %q", got.Findings[1].Category)
	}
}

func TestParseSecurity_MissingFile(t *testing.T) {
	r := &StatusReader{}
	got, err := r.ParseSecurity("/nonexistent/path.md")
	if err != nil {
		t.Fatalf("ParseSecurity: want nil err on missing file, got %v", err)
	}
	if got.Findings == nil {
		t.Fatal("Findings must be non-nil empty slice (bash echoes []), got nil")
	}
	if len(got.Findings) != 0 {
		t.Errorf("Findings: want empty, got %d entries", len(got.Findings))
	}
}

func TestParseSecurity_EmptyPath(t *testing.T) {
	r := &StatusReader{}
	got, err := r.ParseSecurity("")
	if err != nil {
		t.Fatalf("ParseSecurity: %v", err)
	}
	if got.Findings == nil || len(got.Findings) != 0 {
		t.Errorf("empty path: want empty findings slice, got %+v", got)
	}
}

func TestParseSecurity_NoFindingsSection(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "no_findings.md")
	if err := os.WriteFile(path, []byte("# Report\n\nNo findings section here.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := &StatusReader{}
	got, _ := r.ParseSecurity(path)
	if len(got.Findings) != 0 {
		t.Errorf("want empty findings, got %d", len(got.Findings))
	}
}

func TestDetectSeverity_Ordering(t *testing.T) {
	// A line with both CRITICAL and HIGH must resolve to CRITICAL (the
	// first match wins). Documents the parse_security.go ordering.
	cases := []struct {
		line string
		want string
	}{
		{"- Severity: CRITICAL high impact", "CRITICAL"},
		{"- HIGH severity bug", "HIGH"},
		{"- MEDIUM concern", "MEDIUM"},
		{"- LOW priority", "LOW"},
		{"- unranked observation", "INFO"},
	}
	for _, c := range cases {
		got := detectSeverity(c.line)
		if got != c.want {
			t.Errorf("detectSeverity(%q): want %q, got %q", c.line, c.want, got)
		}
	}
}
