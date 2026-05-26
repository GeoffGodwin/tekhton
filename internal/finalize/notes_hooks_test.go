package finalize

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/notes"
)

func writeFixtureNotes(t *testing.T, dir string) string {
	t.Helper()
	// Tests run with cwd = internal/finalize. Reach into the sibling
	// internal/notes/testdata for the golden fixture.
	src, err := os.ReadFile(filepath.Join("..", "notes", "testdata", "golden", "round_trip.md"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	path := filepath.Join(dir, "HUMAN_NOTES.md")
	if err := os.WriteFile(path, src, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	// HUMAN_NOTES_FILE may leak from the parent shell. Clear it so the
	// hook's path resolution lands on dir/HUMAN_NOTES.md, not some
	// pipeline.conf-supplied override.
	t.Setenv("HUMAN_NOTES_FILE", "")
	return path
}

func TestResolveNotesSuccess(t *testing.T) {
	dir := t.TempDir()
	writeFixtureNotes(t, dir)
	in := &Input{
		ProjectDir: dir,
		ExitCode:   0,
		Env:        []string{"CLAIMED_NOTE_IDS=n02"},
	}
	var log bytes.Buffer
	in.Log = &log
	h := &ResolveNotes{}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("ResolveNotes: %v", err)
	}
	d, err := notes.Load(filepath.Join(dir, "HUMAN_NOTES.md"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	n02, _ := d.FindByID("n02")
	if n02.State != notes.Done {
		t.Errorf("n02 should be Done after ResolveNotes success path, got %v", n02.State)
	}
}

func TestResolveNotesFailure(t *testing.T) {
	dir := t.TempDir()
	writeFixtureNotes(t, dir)
	in := &Input{
		ProjectDir: dir,
		ExitCode:   1,
		Env:        []string{"CLAIMED_NOTE_IDS=n02"},
	}
	if err := (&ResolveNotes{}).Run(context.Background(), in); err != nil {
		t.Fatalf("ResolveNotes: %v", err)
	}
	d, _ := notes.Load(filepath.Join(dir, "HUMAN_NOTES.md"))
	n02, _ := d.FindByID("n02")
	if n02.State != notes.Pending {
		t.Errorf("n02 should be Pending after failure, got %v", n02.State)
	}
}

func TestResolveNotesMissingFile(t *testing.T) {
	dir := t.TempDir()
	in := &Input{ProjectDir: dir, ExitCode: 0}
	if err := (&ResolveNotes{}).Run(context.Background(), in); err != nil {
		t.Errorf("missing file should not error, got %v", err)
	}
}

func TestBaselineCleanupClearsActive(t *testing.T) {
	dir := t.TempDir()
	writeFixtureNotes(t, dir)
	in := &Input{ProjectDir: dir, ExitCode: 0}
	if err := (&BaselineCleanup{}).Run(context.Background(), in); err != nil {
		t.Fatalf("BaselineCleanup: %v", err)
	}
	d, _ := notes.Load(filepath.Join(dir, "HUMAN_NOTES.md"))
	// n02 was Active in the fixture; BaselineCleanup should reset it.
	n02, _ := d.FindByID("n02")
	if n02.State != notes.Pending {
		t.Errorf("n02 should be Pending after BaselineCleanup, got %v", n02.State)
	}
}

func TestFailureContextResetGatedOnSuccess(t *testing.T) {
	dir := t.TempDir()
	writeFixtureNotes(t, dir)
	// On failure, the hook is a no-op for the notes branch (bash semantics).
	in := &Input{ProjectDir: dir, ExitCode: 1}
	if err := (&FailureContextReset{}).Run(context.Background(), in); err != nil {
		t.Fatalf("FailureContextReset: %v", err)
	}
	d, _ := notes.Load(filepath.Join(dir, "HUMAN_NOTES.md"))
	n02, _ := d.FindByID("n02")
	if n02.State != notes.Active {
		t.Errorf("n02 should remain Active on failure, got %v", n02.State)
	}
}

func TestFailureContextResetSuccess(t *testing.T) {
	dir := t.TempDir()
	writeFixtureNotes(t, dir)
	in := &Input{ProjectDir: dir, ExitCode: 0}
	if err := (&FailureContextReset{}).Run(context.Background(), in); err != nil {
		t.Fatalf("FailureContextReset: %v", err)
	}
	d, _ := notes.Load(filepath.Join(dir, "HUMAN_NOTES.md"))
	n02, _ := d.FindByID("n02")
	if n02.State != notes.Pending {
		t.Errorf("n02 should be Pending after FailureContextReset, got %v", n02.State)
	}
}

func TestCleanupResolvedRemovesDone(t *testing.T) {
	dir := t.TempDir()
	writeFixtureNotes(t, dir)
	in := &Input{ProjectDir: dir, ExitCode: 0}
	if err := (&CleanupResolved{}).Run(context.Background(), in); err != nil {
		t.Fatalf("CleanupResolved: %v", err)
	}
	d, _ := notes.Load(filepath.Join(dir, "HUMAN_NOTES.md"))
	// n03 was Done in the fixture; should be gone.
	if _, err := d.FindByID("n03"); err == nil {
		t.Errorf("n03 should be removed by CleanupResolved")
	}
}

func TestExpressPersistGated(t *testing.T) {
	dir := t.TempDir()
	in := &Input{ProjectDir: dir, ExitCode: 0}
	// Without EXPRESS_MODE_ACTIVE this is a no-op.
	if err := (&ExpressPersist{}).Run(context.Background(), in); err != nil {
		t.Errorf("ExpressPersist no-op should not error: %v", err)
	}
}

func TestNoteAcceptanceNoTag(t *testing.T) {
	dir := t.TempDir()
	in := &Input{ProjectDir: dir, ExitCode: 0}
	// Without NOTES_FILTER, the hook is a no-op.
	if err := (&NoteAcceptance{}).Run(context.Background(), in); err != nil {
		t.Errorf("NoteAcceptance no-tag should not error: %v", err)
	}
}

func TestNotesHooksRegistered(t *testing.T) {
	// Verify all six m24 hook names point at Go bodies in the orchestrator
	// registry — not bash shim invocations.
	for _, name := range []string{
		"_hook_baseline_cleanup",
		"_hook_express_persist",
		"_hook_note_acceptance",
		"_hook_failure_context_reset",
		"_hook_cleanup_resolved",
		"_hook_resolve_notes",
	} {
		ctor, ok := goNativeHooks[name]
		if !ok {
			t.Errorf("%s not in goNativeHooks (still routed through bash shim)", name)
			continue
		}
		hook := ctor()
		if hook.Name() != name {
			t.Errorf("ctor(%s) produced hook with name %q", name, hook.Name())
		}
		// Must NOT be a BashShimHook.
		if _, isBash := hook.(*BashShimHook); isBash {
			t.Errorf("%s should be a pure-Go body, got BashShimHook", name)
		}
	}
}

func TestEnvValueOrdering(t *testing.T) {
	in := &Input{
		EnvKV: []string{"K=from-envkv"},
		Env:   []string{"K=from-env"},
	}
	if got := envValue(in, "K"); got != "from-envkv" {
		t.Errorf("EnvKV should win, got %q", got)
	}
	in2 := &Input{Env: []string{"K=from-env"}}
	if got := envValue(in2, "K"); got != "from-env" {
		t.Errorf("Env fallback, got %q", got)
	}
}

func TestSplitClaimedIDs(t *testing.T) {
	got := splitClaimedIDs("n01 n02   n03")
	if len(got) != 3 || got[0] != "n01" || got[2] != "n03" {
		t.Errorf("splitClaimedIDs = %v", got)
	}
	if got := splitClaimedIDs(""); got != nil {
		t.Errorf("empty should be nil, got %v", got)
	}
}

func TestPruneResolvedNonBlocking(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "NON_BLOCKING_LOG.md")
	content := `# Non-blocking log

## Open
- [ ] item one
- [x] item two (resolved)
- [ ] item three
- [x] item four (resolved)
`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	removed, err := pruneResolvedNonBlocking(path)
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if removed != 2 {
		t.Errorf("removed = %d, want 2", removed)
	}
	got, _ := os.ReadFile(path)
	if strings.Contains(string(got), "[x]") {
		t.Errorf("[x] lines should be gone:\n%s", string(got))
	}
	if !strings.Contains(string(got), "item one") || !strings.Contains(string(got), "item three") {
		t.Errorf("[ ] lines should remain:\n%s", string(got))
	}
}
