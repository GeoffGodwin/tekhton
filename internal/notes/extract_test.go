package notes

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestExtractDefaultUnchecked(t *testing.T) {
	d, err := Load(filepath.Join("testdata", "golden", "round_trip.md"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	got := Extract(d, ExtractOpts{})
	// Should include only Pending notes (n01, n04, n05, n06); Active
	// (n02) and Done (n03) are filtered out by default.
	lines := strings.Split(got, "\n")
	if len(lines) != 4 {
		t.Fatalf("expected 4 lines, got %d:\n%s", len(lines), got)
	}
	if !strings.HasPrefix(lines[0], "- [BUG] tester loses track") {
		t.Errorf("line[0] = %q", lines[0])
	}
	if !strings.HasPrefix(lines[1], "- [FEAT] --triage --dry-run") {
		t.Errorf("line[1] = %q", lines[1])
	}
	if !strings.HasPrefix(lines[2], "- [FEAT] support custom note tags") {
		t.Errorf("line[2] = %q", lines[2])
	}
	if !strings.HasPrefix(lines[3], "- [POLISH] reword the intake") {
		t.Errorf("line[3] = %q", lines[3])
	}
	// Metadata should be stripped.
	for _, ln := range lines {
		if strings.Contains(ln, "<!-- note:") {
			t.Errorf("metadata not stripped: %q", ln)
		}
	}
}

func TestExtractFilterTag(t *testing.T) {
	d, err := Load(filepath.Join("testdata", "golden", "round_trip.md"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	got := Extract(d, ExtractOpts{FilterTag: "FEAT"})
	lines := strings.Split(got, "\n")
	if len(lines) != 2 {
		t.Fatalf("expected 2 FEAT lines, got %d:\n%s", len(lines), got)
	}
	for _, ln := range lines {
		if !strings.Contains(ln, "[FEAT]") {
			t.Errorf("non-FEAT line: %q", ln)
		}
	}
}

func TestExtractIncludeAll(t *testing.T) {
	d, err := Load(filepath.Join("testdata", "golden", "round_trip.md"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	got := Extract(d, ExtractOpts{IncludeAll: true})
	lines := strings.Split(got, "\n")
	if len(lines) != 6 {
		t.Fatalf("expected 6 lines, got %d", len(lines))
	}
}

func TestExtractIncludeMetadata(t *testing.T) {
	d, err := Load(filepath.Join("testdata", "golden", "round_trip.md"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	got := Extract(d, ExtractOpts{IncludeMetadata: true})
	if !strings.Contains(got, "<!-- note:n01") {
		t.Errorf("metadata should be present when IncludeMetadata=true")
	}
}

func TestExtractNilDocument(t *testing.T) {
	got := Extract(nil, ExtractOpts{})
	if got != "" {
		t.Errorf("nil document should produce empty extract, got %q", got)
	}
}

func TestCountFunctions(t *testing.T) {
	d, err := Load(filepath.Join("testdata", "golden", "round_trip.md"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := CountUnchecked(d, ""); got != 4 {
		t.Errorf("CountUnchecked all = %d, want 4", got)
	}
	if got := CountUnchecked(d, "BUG"); got != 1 {
		t.Errorf("CountUnchecked BUG = %d, want 1", got)
	}
	if got := CountUnchecked(d, "FEAT"); got != 2 {
		t.Errorf("CountUnchecked FEAT = %d, want 2", got)
	}
	if got := CountUnchecked(nil, ""); got != 0 {
		t.Errorf("CountUnchecked(nil) = %d, want 0", got)
	}
	per := PerTagCounts(d, ExtractOpts{})
	if per["BUG"] != 1 || per["FEAT"] != 2 || per["POLISH"] != 1 {
		t.Errorf("PerTagCounts = %+v", per)
	}
}

func TestExtractFromProjectMissingFile(t *testing.T) {
	got, err := ExtractFromProject(t.TempDir(), ExtractOpts{})
	if err != nil {
		t.Errorf("missing file should map to nil err, got %v", err)
	}
	if got != "" {
		t.Errorf("missing file should produce empty extract")
	}
}
