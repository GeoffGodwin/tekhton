package state

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// pinTime fixes nowRFC3339 for the duration of a test so round-trip parity
// (AC #1) sees byte-identical bytes for everything except the field we
// already know differs — the timestamp.
func pinTime(t *testing.T, ts string) {
	t.Helper()
	prev := nowRFC3339
	nowRFC3339 = func() string { return ts }
	t.Cleanup(func() { nowRFC3339 = prev })
}

func newTestStore(t *testing.T) (*Store, string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, ".claude", "PIPELINE_STATE.json")
	return New(path), path
}

// TestRead_Missing maps to ErrNotFound; corrupt to ErrCorrupt — bash callers
// rely on this distinction to route corruption to --diagnose.
func TestRead_MissingAndCorrupt(t *testing.T) {
	s, path := newTestStore(t)

	if _, err := s.Read(); !errors.Is(err, ErrNotFound) {
		t.Errorf("missing: got %v, want ErrNotFound", err)
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := s.Read(); !errors.Is(err, ErrCorrupt) {
		t.Errorf("corrupt: got %v, want ErrCorrupt", err)
	}
}

// TestWriteRead_RoundTrip is AC #1 — fresh JSON snapshot through Write/Read
// preserves every field except UpdatedAt.
func TestWriteRead_RoundTrip(t *testing.T) {
	pinTime(t, "2026-05-04T00:00:00Z")
	s, _ := newTestStore(t)
	want := &proto.StateSnapshotV1{
		RunID:           "run_test",
		StartedAt:       "2026-05-04T00:00:00Z",
		Mode:            "milestone",
		ResumeTask:      "Implement m03",
		ResumeFlag:      "--milestone --start-at coder",
		ExitStage:       "coder",
		ExitReason:      "blockers_remain",
		MilestoneID:     "m03",
		PipelineAttempt: 2,
		AgentCallsTotal: 17,
		Errors: []proto.ErrorRecordV1{
			{Category: "UPSTREAM", Subcategory: "api_500", Transient: true, Recovery: "Retry"},
		},
		Extra: map[string]string{"human_mode": "false"},
	}
	if err := s.Write(want); err != nil {
		t.Fatalf("Write: %v", err)
	}
	got, err := s.Read()
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.ExitStage != "coder" || got.ResumeTask != "Implement m03" {
		t.Errorf("scalar fields not round-tripped: %+v", got)
	}
	if got.PipelineAttempt != 2 || got.AgentCallsTotal != 17 {
		t.Errorf("int fields not round-tripped: %+v", got)
	}
	if len(got.Errors) != 1 || got.Errors[0].Category != "UPSTREAM" {
		t.Errorf("errors not round-tripped: %+v", got.Errors)
	}
	if got.Extra["human_mode"] != "false" {
		t.Errorf("extra not round-tripped: %+v", got.Extra)
	}
}

// TestUpdate_OnlyMutatesNamedFields is AC #3 — partial update preserves
// fields not mentioned in the update.
func TestUpdate_OnlyMutatesNamedFields(t *testing.T) {
	s, _ := newTestStore(t)
	if err := s.Update(func(snap *proto.StateSnapshotV1) {
		snap.ResumeTask = "Task A"
		snap.ExitStage = "tester"
		snap.PipelineAttempt = 1
	}); err != nil {
		t.Fatalf("Update1: %v", err)
	}
	if err := s.Update(func(snap *proto.StateSnapshotV1) {
		snap.ExitStage = "coder"
		snap.PipelineAttempt = 2
	}); err != nil {
		t.Fatalf("Update2: %v", err)
	}
	got, err := s.Read()
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.ResumeTask != "Task A" {
		t.Errorf("ResumeTask clobbered: %q", got.ResumeTask)
	}
	if got.ExitStage != "coder" || got.PipelineAttempt != 2 {
		t.Errorf("update did not apply: %+v", got)
	}
}

// TestAtomicWrite_NoTruncation is AC #4 — a failed write leaves the previous
// file fully intact, never a partial. We exercise this by injecting a write
// failure (read-only path) and confirming the prior snapshot survives.
func TestAtomicWrite_NoTruncation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	s := New(path)
	pinTime(t, "2026-05-04T00:00:00Z")

	if err := s.Write(&proto.StateSnapshotV1{ExitStage: "intake", ResumeTask: "before"}); err != nil {
		t.Fatalf("baseline write: %v", err)
	}
	prior, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read prior: %v", err)
	}

	// Force a temp-file failure by making the directory read-only. atomicWrite
	// CreateTemp's into the same dir, so chmod 0500 (no write) trips it.
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Skipf("cannot chmod tmp dir: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })

	wErr := s.Write(&proto.StateSnapshotV1{ExitStage: "tester", ResumeTask: "after"})
	if wErr == nil {
		t.Fatal("expected Write to fail on read-only dir")
	}

	// Original file must still be intact.
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read after failed write: %v", err)
	}
	if !equalBytes(prior, after) {
		t.Errorf("prior file mutated after failed write\n  prior: %q\n  after: %q", prior, after)
	}
}

// TestUpdate_ConcurrentSerializes is AC #5 — goroutines racing on Update
// produce a final state where every applied increment is visible. We don't
// assert ordering, just that no update is lost (counter equals N after N
// increments).
func TestUpdate_ConcurrentSerializes(t *testing.T) {
	s, _ := newTestStore(t)
	const goroutines = 10
	const perGoroutine = 50
	var wg sync.WaitGroup
	wg.Add(goroutines)
	for g := 0; g < goroutines; g++ {
		go func() {
			defer wg.Done()
			for i := 0; i < perGoroutine; i++ {
				if err := s.Update(func(snap *proto.StateSnapshotV1) {
					snap.PipelineAttempt++
				}); err != nil {
					t.Errorf("Update: %v", err)
					return
				}
			}
		}()
	}
	wg.Wait()
	got, err := s.Read()
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.PipelineAttempt != goroutines*perGoroutine {
		t.Errorf("lost updates: got %d, want %d", got.PipelineAttempt, goroutines*perGoroutine)
	}
}

// TestRead_LegacyMarkdownReturnsErrLegacyFormat is the m10 cutover guard —
// a pre-m03 markdown state file no longer auto-migrates. Read returns
// ErrLegacyFormat so the bash shim can surface a migration prompt instead of
// silently parsing.
func TestRead_LegacyMarkdownReturnsErrLegacyFormat(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "PIPELINE_STATE.md")
	body := "## Exit Stage\ncoder\n\n## Task\nx\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	_, err := New(path).Read()
	if !errors.Is(err, ErrLegacyFormat) {
		t.Errorf("legacy markdown: got %v, want ErrLegacyFormat", err)
	}
}

// TestUpdate_OnLegacyMarkdownErrors confirms Update propagates the legacy
// error rather than auto-rewriting; the V4 migration tool is the only path.
func TestUpdate_OnLegacyMarkdownErrors(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "PIPELINE_STATE.md")
	if err := os.WriteFile(path, []byte("## Exit Stage\nintake\n"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	s := New(path)
	err := s.Update(func(snap *proto.StateSnapshotV1) { snap.ExitReason = "x" })
	if !errors.Is(err, ErrLegacyFormat) {
		t.Errorf("legacy update: got %v, want ErrLegacyFormat", err)
	}
}

// TestClear_AbsentIsNoError verifies Clear is idempotent.
func TestClear_AbsentIsNoError(t *testing.T) {
	s, _ := newTestStore(t)
	if err := s.Clear(); err != nil {
		t.Errorf("Clear absent: %v", err)
	}
}

// TestPath_Getter covers the trivial accessor used by the diagnose layer.
func TestPath_Getter(t *testing.T) {
	s, path := newTestStore(t)
	if got := s.Path(); got != path {
		t.Errorf("Path() = %q; want %q", got, path)
	}
}

// TestRead_EmptyFileIsCorrupt covers the zero-length file branch.
func TestRead_EmptyFileIsCorrupt(t *testing.T) {
	s, path := newTestStore(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(""), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := s.Read(); !errors.Is(err, ErrCorrupt) {
		t.Errorf("empty file: got %v, want ErrCorrupt", err)
	}
}

// TestRead_EmptyPath covers the path-validation branch.
func TestRead_EmptyPath(t *testing.T) {
	if _, err := New("").Read(); err == nil {
		t.Errorf("Read empty path: want error")
	}
}

// TestWrite_NilAndEmptyPath covers the two top-of-Write guards.
func TestWrite_NilAndEmptyPath(t *testing.T) {
	s, _ := newTestStore(t)
	if err := s.Write(nil); err == nil {
		t.Errorf("Write(nil): want error")
	}
	if err := New("").Write(&proto.StateSnapshotV1{}); err == nil {
		t.Errorf("Write empty path: want error")
	}
}

// TestRead_GarbageNonMarkdownIsCorrupt — a non-JSON, non-legacy-markdown file
// (no "## " headings) should still surface ErrCorrupt rather than the
// legacy-format error so callers can route it to --diagnose.
func TestRead_GarbageNonMarkdownIsCorrupt(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "garbage.md")
	if err := os.WriteFile(path, []byte("just a plain text file with no headings\n"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := New(path).Read(); !errors.Is(err, ErrCorrupt) {
		t.Errorf("garbage: got %v, want ErrCorrupt", err)
	}
}

// TestLooksLikeLegacyMarkdown covers the heuristic's branches: heading at
// file start, heading mid-file, and heading-free input.
func TestLooksLikeLegacyMarkdown(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want bool
	}{
		{"start_heading", "## Heading\nbody\n", true},
		{"midline_heading", "preamble\n## Heading\n", true},
		{"no_heading", "plain text\nno markers\n", false},
		{"empty", "", false},
		{"short_no_match", "##", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := looksLikeLegacyMarkdown([]byte(tc.in)); got != tc.want {
				t.Errorf("got %v want %v", got, tc.want)
			}
		})
	}
}

// TestRead_OpenFailureWrapsError covers the non-IsNotExist branch of
// os.Open's error path. EACCES on a 0o000-mode file gives a wrapped
// "state: open" error rather than ErrNotFound.
func TestRead_OpenFailureWrapsError(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "PIPELINE_STATE.json")
	if err := os.WriteFile(path, []byte("{}"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := os.Chmod(path, 0o000); err != nil {
		t.Skipf("cannot chmod: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o644) })
	_, err := New(path).Read()
	if err == nil {
		t.Fatal("expected error on unreadable file")
	}
	if errors.Is(err, ErrNotFound) || errors.Is(err, ErrCorrupt) || errors.Is(err, ErrLegacyFormat) {
		t.Errorf("unexpected typed error: %v", err)
	}
}

// TestFirstNonBlank covers the helper's whitespace-skip branches.
func TestFirstNonBlank(t *testing.T) {
	cases := []struct {
		in   string
		want byte
	}{
		{"", 0},
		{"   \t\n\r", 0},
		{"   {", '{'},
		{"## ", '#'},
		{"\nx", 'x'},
	}
	for _, tc := range cases {
		if got := firstNonBlank([]byte(tc.in)); got != tc.want {
			t.Errorf("firstNonBlank(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
