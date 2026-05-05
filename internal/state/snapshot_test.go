package state

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
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

// TestRead_LegacyMarkdown is AC #2 — V3 markdown parses successfully and
// the legacy sentinel surfaces in Extra so the bash shim can fire its
// STATE_LEGACY_MIGRATED causal event.
func TestRead_LegacyMarkdown(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "PIPELINE_STATE.md")
	body := `# Pipeline State — 2026-05-04 00:00:00
## Exit Stage
coder

## Exit Reason
blockers_remain

## Resume Command
--milestone --start-at coder

## Task
Implement m03 wedge

## Notes
3 complex blockers

## Milestone
m03

## Pipeline Order
standard

## Tester Mode
verify_passing

## Orchestration Context
Pipeline attempt: 4
Cumulative agent calls: 12
Cumulative turns: 250
Wall-clock elapsed: 3600s

## Human Mode
false

## Error Classification
Category: UPSTREAM
Subcategory: api_500
Transient: true
Recovery: Retry

### Last Agent Output (redacted)
hello world
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	snap, err := New(path).Read()
	if err != nil {
		t.Fatalf("Read legacy: %v", err)
	}
	if snap.ExitStage != "coder" || snap.ResumeTask != "Implement m03 wedge" {
		t.Errorf("legacy basics not parsed: %+v", snap)
	}
	if snap.PipelineAttempt != 4 || snap.AgentCallsTotal != 12 {
		t.Errorf("legacy orchestration block not parsed: %+v", snap)
	}
	if len(snap.Errors) != 1 || snap.Errors[0].Category != "UPSTREAM" {
		t.Errorf("legacy error block not parsed: %+v", snap.Errors)
	}
	if snap.Errors[0].LastOutput == "" {
		t.Errorf("legacy last_output missing: %+v", snap.Errors[0])
	}
	if snap.Extra[LegacyMigratedSentinel] != "true" {
		t.Errorf("legacy sentinel not set: %+v", snap.Extra)
	}
}

// TestUpdate_StripsLegacySentinel verifies the next Update after a legacy
// read rewrites the file as JSON and removes the migration marker.
func TestUpdate_StripsLegacySentinel(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "PIPELINE_STATE.md")
	body := "## Exit Stage\nintake\n\n## Task\nlegacy\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	s := New(path)
	if err := s.Update(func(snap *proto.StateSnapshotV1) { snap.ExitReason = "now_json" }); err != nil {
		t.Fatalf("Update: %v", err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.HasPrefix(strings.TrimSpace(string(raw)), "{") {
		t.Errorf("file not rewritten as JSON: %q", raw)
	}
	snap, err := s.Read()
	if err != nil {
		t.Fatalf("read after update: %v", err)
	}
	if _, ok := snap.Extra[LegacyMigratedSentinel]; ok {
		t.Errorf("sentinel survived update: %+v", snap.Extra)
	}
	if snap.ExitStage != "intake" {
		t.Errorf("legacy ExitStage lost: %+v", snap)
	}
}

// TestClear_AbsentIsNoError verifies Clear is idempotent.
func TestClear_AbsentIsNoError(t *testing.T) {
	s, _ := newTestStore(t)
	if err := s.Clear(); err != nil {
		t.Errorf("Clear absent: %v", err)
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
