package test_audit

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRecordAndPruneHistory(t *testing.T) {
	dir := t.TempDir()
	histPath := filepath.Join(dir, "history.jsonl")
	opts := SamplerOptions{
		K:           3,
		MaxRecords:  4,
		HistoryFile: histPath,
	}
	files := []string{"a.go", "b.go", "c.go", "d.go", "e.go", "f.go"}
	if err := RecordAuditHistory(files, opts); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(histPath)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(string(body), "\n"), "\n")
	if len(lines) != opts.MaxRecords {
		t.Fatalf("expected pruned to %d lines, got %d", opts.MaxRecords, len(lines))
	}
	for _, line := range lines {
		var entry historyEntry
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("invalid JSON: %v: %s", err, line)
		}
		if entry.File == "" || entry.Timestamp == "" {
			t.Fatalf("missing field in history entry: %+v", entry)
		}
	}
}

func TestSampleUnauditedTestFiles_NoHistoryReturnsOldestFirst(t *testing.T) {
	t.Setenv("REPO_MAP_CACHE_DIR", t.TempDir())
	// Set up a git repo with test files.
	dir := setupGitRepo(t)
	for _, p := range []string{"tests/test_a.py", "tests/test_b.py", "tests/test_c.py"} {
		full := filepath.Join(dir, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte("# t"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	gitInRepo(t, dir, "add", ".")
	gitInRepo(t, dir, "commit", "-m", "seed")

	ac := &AuditContext{}
	opts := SamplerOptions{K: 3, HistoryFile: filepath.Join(t.TempDir(), "history.jsonl")}
	sampled := SampleUnauditedTestFiles(context.Background(), ac, dir, opts)
	if len(sampled) != 3 {
		t.Fatalf("expected 3 sampled files, got %d: %v", len(sampled), sampled)
	}
}

func TestSampleUnauditedTestFiles_OldestSortedFirst(t *testing.T) {
	dir := setupGitRepo(t)
	files := []string{"tests/test_a.py", "tests/test_b.py", "tests/test_c.py", "tests/test_d.py", "tests/test_e.py"}
	for _, p := range files {
		full := filepath.Join(dir, p)
		_ = os.MkdirAll(filepath.Dir(full), 0o755)
		_ = os.WriteFile(full, []byte("# t"), 0o644)
	}
	gitInRepo(t, dir, "add", ".")
	gitInRepo(t, dir, "commit", "-m", "seed")

	histPath := filepath.Join(t.TempDir(), "history.jsonl")
	// b audited recently, c audited long ago.
	rows := []historyEntry{
		{Timestamp: "2026-06-06T12:00:00Z", File: "tests/test_b.py"},
		{Timestamp: "2024-01-01T00:00:00Z", File: "tests/test_c.py"},
	}
	f, _ := os.Create(histPath)
	for _, r := range rows {
		raw, _ := json.Marshal(r)
		f.Write(raw)
		f.WriteString("\n")
	}
	f.Close()

	ac := &AuditContext{}
	opts := SamplerOptions{K: 3, HistoryFile: histPath}
	sampled := SampleUnauditedTestFiles(context.Background(), ac, dir, opts)
	if len(sampled) != 3 {
		t.Fatalf("expected 3 sampled files, got %d: %v", len(sampled), sampled)
	}
	// Files with no history (a, d, e) should come before the recently audited b.
	// c has old history but still older than the never-audited would be... actually
	// never-audited = epoch sentinel, which sorts before all real timestamps. So
	// a, d, e all share epoch and sort by filename; c is next; b is last.
	// First 3 picks should NOT include 'b'.
	for _, f := range sampled {
		if f == "tests/test_b.py" {
			t.Fatalf("recently-audited file %s should not be in first %d picks: %v",
				f, opts.K, sampled)
		}
	}
}

func TestSampleUnauditedTestFiles_SkipsFilesInCurrentSet(t *testing.T) {
	dir := setupGitRepo(t)
	files := []string{"tests/test_a.py", "tests/test_b.py", "tests/test_c.py"}
	for _, p := range files {
		full := filepath.Join(dir, p)
		_ = os.MkdirAll(filepath.Dir(full), 0o755)
		_ = os.WriteFile(full, []byte("# t"), 0o644)
	}
	gitInRepo(t, dir, "add", ".")
	gitInRepo(t, dir, "commit", "-m", "seed")

	ac := &AuditContext{
		TestFiles: []string{"tests/test_a.py", "tests/test_b.py"},
	}
	opts := SamplerOptions{K: 3, HistoryFile: filepath.Join(t.TempDir(), "h.jsonl")}
	sampled := SampleUnauditedTestFiles(context.Background(), ac, dir, opts)
	for _, f := range sampled {
		if f == "tests/test_a.py" || f == "tests/test_b.py" {
			t.Fatalf("sampled %s should be excluded by current-set filter", f)
		}
	}
}

func TestSampleUnauditedTestFiles_ZeroKReturnsNothing(t *testing.T) {
	dir := setupGitRepo(t)
	ac := &AuditContext{}
	opts := SamplerOptions{K: 0, HistoryFile: filepath.Join(t.TempDir(), "h.jsonl")}
	sampled := SampleUnauditedTestFiles(context.Background(), ac, dir, opts)
	if len(sampled) != 0 {
		t.Fatalf("K=0 must return zero samples, got %d", len(sampled))
	}
}

func TestEnsureHistoryFile_DefaultsUnderProject(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("REPO_MAP_CACHE_DIR", "")
	got := EnsureHistoryFile(dir)
	want := filepath.Join(dir, ".claude/index/test_audit_history.jsonl")
	if got != want {
		t.Fatalf("EnsureHistoryFile mismatch:\n got %q\nwant %q", got, want)
	}
}

func TestFormatHistoryEntry(t *testing.T) {
	// Internal helper sanity — proves JSON shape parity for any caller
	// that wants to inspect the wire format.
	got := formatHistoryEntry("2026-01-01T00:00:00Z", "tests/test.py")
	if !strings.Contains(got, `"ts":"2026-01-01T00:00:00Z"`) ||
		!strings.Contains(got, `"file":"tests/test.py"`) {
		t.Fatalf("unexpected history entry format: %s", got)
	}
}
