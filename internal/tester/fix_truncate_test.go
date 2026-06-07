package tester

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// --- SmartTruncateTestOutput tests -------------------------------------

func TestSmartTruncateTestOutput_EmptyInput(t *testing.T) {
	if got := SmartTruncateTestOutput("", 1000); got != "" {
		t.Errorf("empty input: got %q, want empty", got)
	}
}

func TestSmartTruncateTestOutput_NoMarkersFallsBackToTail80(t *testing.T) {
	var b strings.Builder
	for i := 1; i <= 200; i++ {
		b.WriteString("line ")
		b.WriteString(intToString(i))
		b.WriteByte('\n')
	}
	got := SmartTruncateTestOutput(b.String(), 100000)
	lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
	if len(lines) > 80 {
		t.Errorf("fallback returned %d lines, want ≤ 80", len(lines))
	}
	if !strings.Contains(got, "line 200") {
		t.Errorf("fallback should contain the tail; got last 100 chars: %q", got[max0(len(got)-100):])
	}
}

func TestSmartTruncateTestOutput_ThreeBlocksJoinedByDashes(t *testing.T) {
	body, err := os.ReadFile(filepath.Join("testdata", "fix", "pytest_three_blocks.txt"))
	if err != nil {
		t.Fatal(err)
	}
	got := SmartTruncateTestOutput(string(body), 100000)
	if c := strings.Count(got, "\n---\n"); c != 2 {
		t.Errorf("expected 2 \\n---\\n separators between 3 blocks, got %d", c)
	}
	// each block should have first-5 + last-5 with omission marker for the
	// long pytest block (which had > 10 body lines).
	if !strings.Contains(got, "lines omitted") {
		t.Errorf("expected at least one '... [N lines omitted]' marker; got %q", got)
	}
}

func TestSmartTruncateTestOutput_NoMarkersFromFixture(t *testing.T) {
	body, err := os.ReadFile(filepath.Join("testdata", "fix", "no_markers.txt"))
	if err != nil {
		t.Fatal(err)
	}
	got := SmartTruncateTestOutput(string(body), 100000)
	if !strings.Contains(got, "Line 1 some output") {
		t.Errorf("fallback should include the input when shorter than 80 lines; got %q", got)
	}
}

func TestSmartTruncateTestOutput_CapsAtLimitWithTruncationNotice(t *testing.T) {
	input := "FAIL: " + strings.Repeat("x", 50000)
	got := SmartTruncateTestOutput(input, 1000)
	if len(got) <= 1000 {
		t.Errorf("expected length > 1000 (truncated + notice), got %d", len(got))
	}
	if !strings.Contains(got, "[truncated at 1000 chars]") {
		t.Errorf("expected truncation notice; got tail %q", got[max0(len(got)-100):])
	}
}

func TestSmartTruncateTestOutput_ShortBlockPassesThrough(t *testing.T) {
	body, err := os.ReadFile(filepath.Join("testdata", "fix", "short_block.txt"))
	if err != nil {
		t.Fatal(err)
	}
	got := SmartTruncateTestOutput(string(body), 100000)
	if strings.Contains(got, "lines omitted") {
		t.Errorf("short blocks (≤10 lines) should not have an omission marker; got %q", got)
	}
}

// --- truncateBlock direct tests ----------------------------------------

func TestTruncateBlock_HeadAndTailWithOmissionMarker(t *testing.T) {
	var b strings.Builder
	b.WriteString("FAIL first\n")
	for i := 1; i <= 30; i++ {
		b.WriteString("  body line ")
		b.WriteString(intToString(i))
		b.WriteByte('\n')
	}
	got := truncateBlock(b.String())
	if !strings.Contains(got, "lines omitted") {
		t.Errorf("expected omission marker; got %q", got)
	}
	if !strings.Contains(got, "FAIL first") {
		t.Errorf("expected head; got %q", got)
	}
	if !strings.Contains(got, "body line 30") {
		t.Errorf("expected tail; got %q", got)
	}
}

func TestTruncateBlock_ShortPassesThrough(t *testing.T) {
	in := "FAIL one\n  body a\n"
	if got := truncateBlock(in); got != in {
		t.Errorf("short block changed: got %q, want %q", got, in)
	}
}

func TestTruncateBlock_EmptyReturnsEmpty(t *testing.T) {
	if got := truncateBlock(""); got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

// --- coder-summary parsing tests ---------------------------------------

func TestCleanCoderSummaryBullet_StripsBacktickAndAnnotation(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"- `src/foo.go` — bug fix", "src/foo.go"},
		{"- `tests/x.go` (NEW)", "tests/x.go"},
		{"- `lib/foo.sh`", "lib/foo.sh"},
		{"- src/raw.go", "src/raw.go"},
		{"no bullet", ""},
	}
	for _, c := range cases {
		if got := cleanCoderSummaryBullet(c.in); got != c.want {
			t.Errorf("cleanCoderSummaryBullet(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestReadCoderSummaryFiles_ParsesFilesModifiedSection(t *testing.T) {
	dir := t.TempDir()
	body := `# Summary
## Files Modified
- ` + "`a.go`" + ` (NEW)
- ` + "`b.go`" + `

## Status
COMPLETE
`
	path := filepath.Join(dir, "CODER_SUMMARY.md")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	files, err := readCoderSummaryFiles(path)
	if err != nil {
		t.Fatal(err)
	}
	if !equalStrSlice(files, []string{"a.go", "b.go"}) {
		t.Errorf("got %v, want [a.go b.go]", files)
	}
}

func TestReadCoderSummaryFiles_MissingFileReturnsError(t *testing.T) {
	if _, err := readCoderSummaryFiles("/nonexistent/path/summary.md"); err == nil {
		t.Errorf("expected error for missing file")
	}
}

func TestTailLines_FewerThanNReturnsAll(t *testing.T) {
	in := "a\nb\nc\n"
	if got := tailLines(in, 10); got != in {
		t.Errorf("got %q, want %q", got, in)
	}
	if got := tailLines("", 10); got != "" {
		t.Errorf("empty: got %q", got)
	}
	if got := tailLines("a\nb\n", 0); got != "" {
		t.Errorf("zero n: got %q", got)
	}
}

func TestIntToString_Conversion(t *testing.T) {
	if got := intToString(42); got != "42" {
		t.Errorf("got %q, want 42", got)
	}
}
