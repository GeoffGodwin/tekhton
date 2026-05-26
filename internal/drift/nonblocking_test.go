package drift

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func tempNB(t *testing.T) *NonBlocking {
	t.Helper()
	dir := t.TempDir()
	nb := NewNonBlocking(filepath.Join(dir, "NON_BLOCKING_LOG.md"))
	nb.Now = func() time.Time { return time.Date(2026, 5, 26, 0, 0, 0, 0, time.UTC) }
	return nb
}

func TestNonBlocking_EnsureFile_Creates(t *testing.T) {
	nb := tempNB(t)
	if err := nb.EnsureFile(); err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(nb.Path)
	s := string(body)
	if !strings.Contains(s, "## Open") {
		t.Error("missing ## Open")
	}
	if !strings.Contains(s, "## Resolved") {
		t.Error("missing ## Resolved")
	}
}

func TestNonBlocking_EnsureFile_RepairsMissingOpen(t *testing.T) {
	nb := tempNB(t)
	// Pre-existing file with only ## Resolved.
	_ = os.WriteFile(nb.Path, []byte("# log\n\n## Resolved\n"), 0o644)
	if err := nb.EnsureFile(); err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(nb.Path)
	if !strings.Contains(string(body), "## Open") {
		t.Errorf("Open not repaired:\n%s", body)
	}
}

func TestNonBlocking_AppendNotes(t *testing.T) {
	nb := tempNB(t)
	raw := `- minor style issue
- naming inconsistency`
	if err := nb.AppendNotes("task X", raw); err != nil {
		t.Fatal(err)
	}
	n, _ := nb.CountOpen()
	if n != 2 {
		t.Errorf("CountOpen = %d, want 2", n)
	}
}

func TestNonBlocking_GetOpen(t *testing.T) {
	nb := tempNB(t)
	_ = nb.AppendNotes("t", "- one\n- two\n- three")
	got, err := nb.GetOpen()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Errorf("GetOpen = %d, want 3", len(got))
	}
}

func TestNonBlocking_ResolveByModifiedFiles(t *testing.T) {
	nb := tempNB(t)
	_ = nb.AppendNotes("t",
		`- check internal/notes/state.go for a missing comment
- something unrelated`)
	resolved, err := nb.ResolveByModifiedFiles([]string{"internal/notes/state.go"})
	if err != nil {
		t.Fatal(err)
	}
	if resolved != 1 {
		t.Errorf("resolved = %d, want 1", resolved)
	}
	// One entry should now be [x].
	body, _ := os.ReadFile(nb.Path)
	if !strings.Contains(string(body), "- [x]") {
		t.Errorf("[x] marker missing:\n%s", body)
	}
}

func TestNonBlocking_ClearCompleted(t *testing.T) {
	nb := tempNB(t)
	_ = nb.AppendNotes("t", "- one\n- two")
	_, _ = nb.ResolveByModifiedFiles([]string{"one"})
	moved, err := nb.ClearCompleted()
	if err != nil {
		t.Fatal(err)
	}
	if moved != 1 {
		t.Errorf("ClearCompleted moved %d, want 1", moved)
	}
	body, _ := os.ReadFile(nb.Path)
	s := string(body)
	openIdx := strings.Index(s, "## Open")
	resolvedIdx := strings.Index(s, "## Resolved")
	if openIdx == -1 || resolvedIdx == -1 {
		t.Fatal("missing section markers")
	}
	if !strings.Contains(s[resolvedIdx:], "- [x]") {
		t.Errorf("[x] not in Resolved:\n%s", s)
	}
	if strings.Contains(s[openIdx:resolvedIdx], "- [x]") {
		t.Errorf("[x] still in Open:\n%s", s)
	}
}

func TestNonBlocking_ClearResolved(t *testing.T) {
	nb := tempNB(t)
	_ = nb.AppendNotes("t", "- one\n- two")
	_, _ = nb.ResolveByModifiedFiles([]string{"one"})
	_, _ = nb.ClearCompleted()
	cleared, err := nb.ClearResolved()
	if err != nil {
		t.Fatal(err)
	}
	if len(cleared) != 1 {
		t.Errorf("cleared = %d, want 1", len(cleared))
	}
	body, _ := os.ReadFile(nb.Path)
	// ## Resolved heading should still be present.
	if !strings.Contains(string(body), "## Resolved") {
		t.Errorf("Resolved heading lost:\n%s", body)
	}
}
