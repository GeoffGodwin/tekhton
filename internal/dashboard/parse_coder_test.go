// parse_coder_test.go — table-driven coverage for ParseCoder.

package dashboard

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseCoder_Golden(t *testing.T) {
	r := &StatusReader{}
	got, err := r.ParseCoder("testdata/parsers/coder/golden.md")
	if err != nil {
		t.Fatalf("ParseCoder: %v", err)
	}
	if got.Status != "COMPLETE" {
		t.Errorf("status: want COMPLETE, got %q", got.Status)
	}
	// 2 Created + 2 Modified = 4 entries
	if got.FilesModified != 4 {
		t.Errorf("files_modified: want 4, got %d", got.FilesModified)
	}
}

func TestParseCoder_MissingFile(t *testing.T) {
	r := &StatusReader{}
	got, err := r.ParseCoder("/nonexistent/path.md")
	if err != nil {
		t.Fatalf("want nil err, got %v", err)
	}
	if got.Status != "unknown" {
		t.Errorf("missing-file status: want 'unknown', got %q", got.Status)
	}
}

func TestParseCoder_HeaderFormat(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "summary.md")
	body := `# Summary

## Status
IN PROGRESS

## Files Modified
- foo.go
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	r := &StatusReader{}
	got, _ := r.ParseCoder(path)
	if got.Status != "IN PROGRESS" {
		t.Errorf("header status: want 'IN PROGRESS', got %q", got.Status)
	}
	if got.FilesModified != 1 {
		t.Errorf("header files_modified: want 1, got %d", got.FilesModified)
	}
}

func TestParseCoder_NoFilesSection(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "no_files.md")
	if err := os.WriteFile(path, []byte("## Status: DONE\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := &StatusReader{}
	got, _ := r.ParseCoder(path)
	if got.FilesModified != 0 {
		t.Errorf("no Files section: want 0, got %d", got.FilesModified)
	}
}

func TestIsFilesSectionHeading(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"## Files Created", true},
		{"## Files Modified", true},
		{"## Files created", true},
		{"## Files modified", true},
		{"## Files Touched", false},
		{"## Status: DONE", false},
		{"### Files Modified", false},
	}
	for _, c := range cases {
		if got := isFilesSectionHeading(c.in); got != c.want {
			t.Errorf("isFilesSectionHeading(%q): want %v, got %v", c.in, c.want, got)
		}
	}
}
