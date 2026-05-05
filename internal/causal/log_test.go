package causal

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// helper: open a Log at a tmp path with sane defaults.
func openTestLog(t *testing.T, cap int) (*Log, string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, ".claude", "logs", "CAUSAL_LOG.jsonl")
	l, err := Open(path, cap, "run_test")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return l, path
}

func readLines(t *testing.T, path string) []string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		out = append(out, sc.Text())
	}
	return out
}

// TestEmit_AppendsAndReturnsID verifies the basic emit→file round trip.
func TestEmit_AppendsAndReturnsID(t *testing.T) {
	l, path := openTestLog(t, 0)
	id, err := l.Emit(EmitInput{Stage: "coder", Type: "stage_start", Detail: "hello"})
	if err != nil {
		t.Fatalf("Emit: %v", err)
	}
	if id != "coder.001" {
		t.Errorf("id = %q; want coder.001", id)
	}
	lines := readLines(t, path)
	if len(lines) != 1 {
		t.Fatalf("got %d lines; want 1", len(lines))
	}
	got := lines[0]
	for _, want := range []string{
		`"proto":"tekhton.causal.v1"`,
		`"id":"coder.001"`,
		`"type":"stage_start"`,
		`"stage":"coder"`,
		`"detail":"hello"`,
		`"caused_by":[]`,
		`"verdict":null`,
		`"context":null`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("line missing %q\n  got: %s", want, got)
		}
	}
}

// TestEmit_PerStageMonotonic checks each stage's counter advances independently.
func TestEmit_PerStageMonotonic(t *testing.T) {
	l, _ := openTestLog(t, 0)
	tests := []struct {
		stage string
		want  string
	}{
		{"coder", "coder.001"},
		{"coder", "coder.002"},
		{"review", "review.001"},
		{"coder", "coder.003"},
		{"review", "review.002"},
	}
	for _, tc := range tests {
		got, err := l.Emit(EmitInput{Stage: tc.stage, Type: "stage_start"})
		if err != nil {
			t.Fatalf("Emit: %v", err)
		}
		if got != tc.want {
			t.Errorf("stage %s: got %q, want %q", tc.stage, got, tc.want)
		}
	}
}

// TestEmit_CausedByThreaded checks the caused_by array round-trips correctly.
func TestEmit_CausedByThreaded(t *testing.T) {
	l, path := openTestLog(t, 0)
	_, _ = l.Emit(EmitInput{Stage: "coder", Type: "stage_start"})
	_, _ = l.Emit(EmitInput{Stage: "review", Type: "rework_trigger", CausedBy: []string{"coder.001", "pipeline.001"}})
	lines := readLines(t, path)
	if len(lines) != 2 {
		t.Fatalf("got %d lines; want 2", len(lines))
	}
	if !strings.Contains(lines[1], `"caused_by":["coder.001","pipeline.001"]`) {
		t.Errorf("caused_by not threaded\n  got: %s", lines[1])
	}
}

// TestEmit_VerdictAndContextRaw passes raw JSON for verdict and context.
func TestEmit_VerdictAndContextRaw(t *testing.T) {
	l, path := openTestLog(t, 0)
	_, _ = l.Emit(EmitInput{
		Stage:   "review",
		Type:    "verdict",
		Verdict: json.RawMessage(`{"result":"APPROVED"}`),
		Context: json.RawMessage(`{"files":3}`),
	})
	got := readLines(t, path)[0]
	if !strings.Contains(got, `"verdict":{"result":"APPROVED"}`) {
		t.Errorf("verdict raw missing\n  got: %s", got)
	}
	if !strings.Contains(got, `"context":{"files":3}`) {
		t.Errorf("context raw missing\n  got: %s", got)
	}
}

// TestEmit_EscapesBashCompatible verifies the JSON escape helper matches bash
// _json_escape rules: only \, ", \n, \r, \t are escaped.
func TestEmit_EscapesBashCompatible(t *testing.T) {
	cases := map[string]string{
		`hello "world"`: `"hello \"world\""`,
		"line\nbreak":   `"line\nbreak"`,
		"tab\there":     `"tab\there"`,
		`back\slash`:    `"back\\slash"`,
		"plain":         `"plain"`,
	}
	for in, want := range cases {
		if got := proto.Quote(in); got != want {
			t.Errorf("Quote(%q) = %q; want %q", in, got, want)
		}
	}
}

// TestEvict_KeepsLastCap exercises the in-place rewrite when the count exceeds
// the cap. The pre-cap events should be dropped, the most-recent cap retained.
func TestEvict_KeepsLastCap(t *testing.T) {
	l, path := openTestLog(t, 5)
	for i := 0; i < 8; i++ {
		if _, err := l.Emit(EmitInput{Stage: "cap", Type: "test_cap"}); err != nil {
			t.Fatalf("Emit: %v", err)
		}
	}
	lines := readLines(t, path)
	if len(lines) > 5 {
		t.Errorf("eviction did not enforce cap: %d lines (cap=5)", len(lines))
	}
}

// TestEvict_BelowCap verifies eviction is a no-op below the cap.
func TestEvict_BelowCap(t *testing.T) {
	l, path := openTestLog(t, 100)
	for i := 0; i < 3; i++ {
		_, _ = l.Emit(EmitInput{Stage: "low", Type: "x"})
	}
	if got := len(readLines(t, path)); got != 3 {
		t.Errorf("expected 3 lines below cap; got %d", got)
	}
}

// TestArchive_CopiesAndPrunes verifies archive rotation + retention pruning.
func TestArchive_CopiesAndPrunes(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log.jsonl")
	l, err := Open(path, 0, "run_archive")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, err := l.Emit(EmitInput{Stage: "x", Type: "y"}); err != nil {
		t.Fatalf("Emit: %v", err)
	}
	// Pre-seed several stale archives to verify pruning behavior.
	runsDir := filepath.Join(dir, "runs")
	for _, name := range []string{
		"CAUSAL_LOG_run_a.jsonl",
		"CAUSAL_LOG_run_b.jsonl",
		"CAUSAL_LOG_run_c.jsonl",
		"CAUSAL_LOG_run_d.jsonl",
	} {
		if err := os.WriteFile(filepath.Join(runsDir, name), []byte("{}\n"), 0o644); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	if err := l.Archive(2); err != nil {
		t.Fatalf("Archive: %v", err)
	}
	entries, _ := os.ReadDir(runsDir)
	count := 0
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "CAUSAL_LOG_") {
			count++
		}
	}
	if count > 3 {
		t.Errorf("pruning kept too many archives: %d (retention=2 plus current)", count)
	}
	if _, err := os.Stat(filepath.Join(runsDir, "CAUSAL_LOG_run_archive.jsonl")); err != nil {
		t.Errorf("current run archive missing: %v", err)
	}
}

// TestOpen_SeedsFromExisting checks resume: opening a log with prior events
// must continue per-stage IDs without colliding.
func TestOpen_SeedsFromExisting(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log.jsonl")
	l1, err := Open(path, 0, "r1")
	if err != nil {
		t.Fatalf("Open1: %v", err)
	}
	for i := 0; i < 3; i++ {
		_, _ = l1.Emit(EmitInput{Stage: "coder", Type: "x"})
	}
	_ = l1.Close()

	l2, err := Open(path, 0, "r1")
	if err != nil {
		t.Fatalf("Open2: %v", err)
	}
	id, err := l2.Emit(EmitInput{Stage: "coder", Type: "x"})
	if err != nil {
		t.Fatalf("Emit: %v", err)
	}
	if id != "coder.004" {
		t.Errorf("resume seq broken: got %q, want coder.004", id)
	}
}

// TestEmit_ConcurrentPerStage runs 10 goroutines × 100 emits per stage and
// verifies no duplicate IDs are produced per stage. This is the AC #3 race
// guarantee for the in-process counter.
func TestEmit_ConcurrentPerStage(t *testing.T) {
	l, _ := openTestLog(t, 0)
	const goroutines = 10
	const perGoroutine = 100
	var wg sync.WaitGroup
	idsByStage := make(map[string]*sync.Map)
	stages := []string{"coder", "review", "tester"}
	for _, s := range stages {
		idsByStage[s] = &sync.Map{}
	}
	wg.Add(goroutines * len(stages))
	for _, stage := range stages {
		stage := stage
		for g := 0; g < goroutines; g++ {
			go func() {
				defer wg.Done()
				for i := 0; i < perGoroutine; i++ {
					id, err := l.Emit(EmitInput{Stage: stage, Type: "race"})
					if err != nil {
						t.Errorf("Emit: %v", err)
						return
					}
					if _, dup := idsByStage[stage].LoadOrStore(id, struct{}{}); dup {
						t.Errorf("duplicate id %q for stage %s", id, stage)
					}
				}
			}()
		}
	}
	wg.Wait()
}

// TestParseStageAndSeq verifies the resume seeder's id-extraction.
func TestParseStageAndSeq(t *testing.T) {
	cases := []struct {
		line  string
		stage string
		seq   int64
	}{
		{`{"id":"coder.001","ts":"x"}`, "coder", 1},
		{`{"proto":"v","id":"review.042","ts":"x"}`, "review", 42},
		{`{"id":"pipeline.999"}`, "pipeline", 999},
		{`{"no_id":true}`, "", 0},
		{`{"id":"badformat"}`, "", 0},
	}
	for _, tc := range cases {
		stage, seq := parseStageAndSeq([]byte(tc.line))
		if stage != tc.stage || seq != tc.seq {
			t.Errorf("parse(%q) = (%q, %d); want (%q, %d)", tc.line, stage, seq, tc.stage, tc.seq)
		}
	}
}

// TestOpen_RejectsEmptyPath covers the guard at the top of Open. Without this
// case the error branch goes uncovered and the m04 80% gate would slip.
func TestOpen_RejectsEmptyPath(t *testing.T) {
	if _, err := Open("", 0, "rid"); err == nil {
		t.Fatalf("Open(\"\") returned nil error; want non-nil")
	}
}

// TestEmit_RejectsEmptyStageAndType exercises the two top-of-Emit guards so
// the validation path is covered.
func TestEmit_RejectsEmptyStageAndType(t *testing.T) {
	l, _ := openTestLog(t, 0)
	if _, err := l.Emit(EmitInput{Stage: "", Type: "x"}); err == nil {
		t.Errorf("empty stage: want error")
	}
	if _, err := l.Emit(EmitInput{Stage: "coder", Type: ""}); err == nil {
		t.Errorf("empty type: want error")
	}
}

// TestPathAndCount_Getters covers two trivial accessors that the in-process
// causal status reporter and the resume seeder both use.
func TestPathAndCount_Getters(t *testing.T) {
	l, path := openTestLog(t, 0)
	if l.Path() != path {
		t.Errorf("Path() = %q; want %q", l.Path(), path)
	}
	if l.Count() != 0 {
		t.Errorf("fresh Count() = %d; want 0", l.Count())
	}
	_, _ = l.Emit(EmitInput{Stage: "x", Type: "y"})
	if l.Count() != 1 {
		t.Errorf("after-1-emit Count() = %d; want 1", l.Count())
	}
	if err := l.Close(); err != nil {
		t.Errorf("Close: %v", err)
	}
}

// TestPruneArchives_RetentionZeroNoop covers the early-return branch when
// retention is disabled.
func TestPruneArchives_RetentionZeroNoop(t *testing.T) {
	dir := t.TempDir()
	runsDir := filepath.Join(dir, "runs")
	if err := os.MkdirAll(runsDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	for _, name := range []string{"CAUSAL_LOG_a.jsonl", "CAUSAL_LOG_b.jsonl"} {
		if err := os.WriteFile(filepath.Join(runsDir, name), []byte("{}\n"), 0o644); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	if err := pruneArchives(runsDir, 0); err != nil {
		t.Errorf("pruneArchives(0): %v", err)
	}
	entries, _ := os.ReadDir(runsDir)
	if len(entries) != 2 {
		t.Errorf("retention=0 should not prune; got %d entries", len(entries))
	}
}

// TestArchive_NoSourceFile covers the fast-path return when the live log
// does not yet exist.
func TestArchive_NoSourceFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log.jsonl")
	l, err := Open(path, 0, "rid")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	// Open does not create the file — Emit does. Without an Emit, Archive
	// must return nil rather than failing.
	if err := l.Archive(2); err != nil {
		t.Errorf("Archive on missing log: %v", err)
	}
}

// BenchmarkEmit measures the per-event append cost. Captured here so the
// SQLite-vs-flat-file decision (DESIGN_v6.md §3) has a baseline number.
func BenchmarkEmit(b *testing.B) {
	dir := b.TempDir()
	path := filepath.Join(dir, "log.jsonl")
	l, err := Open(path, 2000, "bench")
	if err != nil {
		b.Fatalf("Open: %v", err)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := l.Emit(EmitInput{Stage: "bench", Type: "iter"}); err != nil {
			b.Fatalf("Emit: %v", err)
		}
	}
}
