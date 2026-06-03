package cleanup

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/notes"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// makeBatchDoc returns a parsed document with the supplied titles as
// pending notes, plus a matching batch slice for processResults.
func makeBatchDoc(t *testing.T, titles ...string) (*notes.Document, []*notes.Note) {
	t.Helper()
	lines := []string{"## Open"}
	for _, ti := range titles {
		lines = append(lines, "- [ ] [BUG] "+ti)
	}
	d, err := notes.Parse(strings.NewReader(strings.Join(lines, "\n") + "\n"))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	return d, d.NotesByState(notes.Pending)
}

func TestProcessResults_BuildFail_NoMutations(t *testing.T) {
	d, batch := makeBatchDoc(t, "alpha", "beta")
	req := &proto.StageRequestV1{Stage: proto.StageCleanup}
	res := processResults(d, batch, false, req)
	if res.Resolved != 0 || res.Deferred != 0 {
		t.Errorf("processResults(build fail) = %+v, want zero", res)
	}
	for _, n := range d.Notes {
		if n.State != notes.Pending {
			t.Errorf("note %q state = %v, want Pending (build failed)", n.Title, n.State)
		}
	}
}

func TestParseReport_StructuredOutput(t *testing.T) {
	d, batch := makeBatchDoc(t, "alpha needs work", "beta cleanup", "gamma polish")
	report := `# Cleanup Report

## Resolved
- alpha needs work
- gamma polish

## Deferred
- beta cleanup: out of scope for this sweep

## Not Attempted
- (nothing)
`
	dir := t.TempDir()
	reportPath := filepath.Join(dir, "CLEANUP_REPORT.md")
	if err := os.WriteFile(reportPath, []byte(report), 0o644); err != nil {
		t.Fatalf("write report: %v", err)
	}

	res := parseReport(d, batch, reportPath)
	if res.Resolved != 2 {
		t.Errorf("Resolved = %d, want 2", res.Resolved)
	}
	if res.Deferred != 1 {
		t.Errorf("Deferred = %d, want 1", res.Deferred)
	}

	// Verify state transitions.
	resolvedCount, deferredCount := 0, 0
	for _, n := range d.Notes {
		switch n.State {
		case notes.Done:
			resolvedCount++
		case notes.Deferred:
			deferredCount++
		}
	}
	if resolvedCount != 2 {
		t.Errorf("resolved-state notes = %d, want 2", resolvedCount)
	}
	if deferredCount != 1 {
		t.Errorf("deferred-state notes = %d, want 1", deferredCount)
	}
}

func TestParseReport_IgnoresNotAttempted(t *testing.T) {
	d, batch := makeBatchDoc(t, "alpha", "beta")
	report := `# Report

## Resolved
- alpha

## Not Attempted
- beta
`
	dir := t.TempDir()
	reportPath := filepath.Join(dir, "CLEANUP_REPORT.md")
	if err := os.WriteFile(reportPath, []byte(report), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	res := parseReport(d, batch, reportPath)
	if res.Resolved != 1 || res.Deferred != 0 {
		t.Errorf("res = %+v, want resolved=1 deferred=0 (Not Attempted ignored)", res)
	}
	// beta must remain Pending (Not Attempted is the no-op section).
	for _, n := range d.Notes {
		if strings.Contains(n.Title, "beta") && n.State != notes.Pending {
			t.Errorf("beta state = %v, want Pending (Not Attempted)", n.State)
		}
	}
}

func TestProcessResults_FallbackToFileChanges(t *testing.T) {
	// processResults falls back to resolveByFileChanges when the
	// report file is absent. We can't easily fake `git diff` from a
	// unit test, but we CAN verify the "no report exists" branch
	// dispatches there by giving an unwritable report path AND a
	// nonexistent project dir for git diff. The expected outcome is
	// zero mutations (git diff in this temp dir = empty), proving the
	// dispatch went through the fallback rather than parseReport.
	d, batch := makeBatchDoc(t, "alpha")
	req := &proto.StageRequestV1{
		Stage:        proto.StageCleanup,
		EnvOverrides: map[string]string{"PROJECT_DIR": t.TempDir()},
	}
	// Point CLEANUP_REPORT_FILE at a path that does not exist.
	t.Setenv("CLEANUP_REPORT_FILE", filepath.Join(t.TempDir(), "no-such-report.md"))
	res := processResults(d, batch, true, req)
	if res.Resolved != 0 || res.Deferred != 0 {
		t.Errorf("processResults fallback = %+v, want zero (empty git diff)", res)
	}
}

func TestExtractMarkdownSection(t *testing.T) {
	content := `# Title

## Resolved
- one
- two

## Deferred
- three

## Other
- ignored
`
	got := extractMarkdownSection(content, "## Resolved")
	want := []string{"- one", "- two"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Errorf("got[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestMatchesBatch(t *testing.T) {
	_, batch := makeBatchDoc(t, "alpha needs work", "beta polish")
	if !matchesBatch("alpha", batch) {
		t.Error("matchesBatch(alpha, ...) = false, want true")
	}
	if !matchesBatch("alpha needs work", batch) {
		t.Error("matchesBatch(full title, ...) = false, want true")
	}
	if matchesBatch("zeta", batch) {
		t.Error("matchesBatch(zeta, ...) = true, want false")
	}
	if matchesBatch("", batch) {
		t.Error("matchesBatch('', ...) = true, want false")
	}
}

func TestStripBulletPrefix(t *testing.T) {
	cases := []struct {
		in     string
		marker string
		want   string
	}{
		{"- [x] alpha", "[x] ", "alpha"},
		{"- alpha", "[x] ", "alpha"},
		{"- [DEFERRED] beta", "[DEFERRED] ", "beta"},
	}
	for _, tc := range cases {
		got := stripBulletPrefix(tc.in, tc.marker)
		if got != tc.want {
			t.Errorf("stripBulletPrefix(%q, %q) = %q, want %q", tc.in, tc.marker, got, tc.want)
		}
	}
}
