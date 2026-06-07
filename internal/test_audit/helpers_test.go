package test_audit

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadTestFilesFromReport(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "TESTER_REPORT.md")
	body := "# Planned Tests\n" +
		"- [x] `internal/foo/foo_test.go` — passes\n" +
		"- [x] `tests/test_bar.py`\n" +
		"- [ ] `tests/test_unfinished.py`\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	got := readTestFilesFromReport(path)
	if len(got) != 2 {
		t.Fatalf("expected 2 ticked test files, got %d: %v", len(got), got)
	}
	if got[0] != "internal/foo/foo_test.go" || got[1] != "tests/test_bar.py" {
		t.Fatalf("unexpected test files: %v", got)
	}
}

func TestReadImplFilesFromCoderSummary_FiltersTests(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "CODER_SUMMARY.md")
	body := "## Files Modified\n" +
		"- `internal/foo/foo.go` (NEW)\n" +
		"- `tests/test_foo.py` (NEW)\n" +
		"- `internal/bar/spec_helpers.go` (MOD)\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	got := readImplFilesFromCoderSummary(path)
	for _, f := range got {
		if strings.Contains(strings.ToLower(f), "test") || strings.Contains(strings.ToLower(f), "spec") {
			t.Fatalf("expected test/spec filter to drop %q", f)
		}
	}
	if len(got) == 0 {
		t.Fatalf("expected at least one non-test impl file, got none")
	}
}

func TestCollectAuditContext_PopulatesAllFields(t *testing.T) {
	dir := t.TempDir()
	testerPath := filepath.Join(dir, "TESTER_REPORT.md")
	_ = os.WriteFile(testerPath, []byte("- [x] `tests/t.go`\n"), 0o644)
	coderPath := filepath.Join(dir, "CODER_SUMMARY.md")
	_ = os.WriteFile(coderPath, []byte("- `internal/x/x.go`\n"), 0o644)
	req := &Request{
		ProjectDir:       dir,
		TesterReportFile: testerPath,
		CoderSummaryFile: coderPath,
	}
	ac := CollectAuditContext(context.Background(), req)
	if len(ac.TestFiles) != 1 || ac.TestFiles[0] != "tests/t.go" {
		t.Fatalf("test files wrong: %v", ac.TestFiles)
	}
	if len(ac.ImplFiles) != 1 || ac.ImplFiles[0] != "internal/x/x.go" {
		t.Fatalf("impl files wrong: %v", ac.ImplFiles)
	}
}

func TestBuildTestAuditContext_ContainsAllSections(t *testing.T) {
	ac := &AuditContext{
		TestFiles:         []string{"tests/t.go"},
		ImplFiles:         []string{"internal/x.go"},
		SampleFiles:       []string{"tests/old_test.py"},
		OrphanFindings:    []string{"ORPHAN: tests/t.go imports deleted module 'src/foo.py'"},
		WeakeningFindings: []string{"WEAKENING: tests/t.go — net loss of 2 assertion(s)"},
		DeletedFiles:      []string{"src/foo.py", "src/bar.py"},
	}
	got, deleted := BuildTestAuditContext(ac)
	wantSections := []string{
		"Test Files Under Audit (modified this run)",
		"Test Files Under Audit (freshness sample — may be stale)",
		"Implementation Files Changed",
		"Shell-Detected Orphans (pre-verified)",
		"Shell-Detected Weakening (pre-verified)",
		"ORPHAN: tests/t.go",
		"WEAKENING: tests/t.go",
	}
	for _, w := range wantSections {
		if !strings.Contains(got, w) {
			t.Fatalf("missing section %q in context:\n%s", w, got)
		}
	}
	if deleted != "src/foo.py\nsrc/bar.py" {
		t.Fatalf("deleted-files mismatch: %q", deleted)
	}
}

func TestBuildTestAuditContext_NoneWhenEmpty(t *testing.T) {
	ac := &AuditContext{}
	got, _ := BuildTestAuditContext(ac)
	if !strings.Contains(got, "- (none)") {
		t.Fatalf("expected '- (none)' marker for empty test set, got:\n%s", got)
	}
}

func TestDiscoverAllTestFiles_FindsConventionalNames(t *testing.T) {
	dir := setupGitRepo(t)
	files := []string{
		"tests/test_a.py",
		"src/foo.test.js",
		"pkg/spec_helpers.rb",
		"src/util/regular.go", // non-test file
	}
	for _, p := range files {
		full := filepath.Join(dir, p)
		_ = os.MkdirAll(filepath.Dir(full), 0o755)
		_ = os.WriteFile(full, []byte("# t"), 0o644)
	}
	gitInRepo(t, dir, "add", ".")
	gitInRepo(t, dir, "commit", "-m", "seed")

	got := DiscoverAllTestFiles(context.Background(), dir)
	gotSet := map[string]bool{}
	for _, f := range got {
		gotSet[f] = true
	}
	if !gotSet["tests/test_a.py"] || !gotSet["src/foo.test.js"] {
		t.Fatalf("expected to find test_a.py + foo.test.js, got %v", got)
	}
	if gotSet["src/util/regular.go"] {
		t.Fatalf("non-test file %q should not be discovered", "src/util/regular.go")
	}
}

func TestDiscoverAllTestFiles_NonGitDirReturnsEmpty(t *testing.T) {
	dir := t.TempDir()
	got := DiscoverAllTestFiles(context.Background(), dir)
	if len(got) != 0 {
		t.Fatalf("non-git directory should return empty, got %v", got)
	}
}

func TestDedupeStrings(t *testing.T) {
	got := dedupeStrings([]string{"a", "b", "a", "", "c", "b"})
	want := []string{"a", "b", "c"}
	if len(got) != len(want) {
		t.Fatalf("length mismatch: %v vs %v", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("dedupe mismatch at %d: got %s want %s", i, got[i], want[i])
		}
	}
}
