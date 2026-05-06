package manifest

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

const sampleManifest = `# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|DAG Infrastructure|done||m01-dag-infra.md|foundation
m02|Sliding Window|in_progress|m01|m02-sliding-window.md|foundation
m03|Indexer Setup|pending|m01|m03-indexer-setup.md|indexer
m04|Repo Map Generator|pending|m02,m03|m04-repo-map.md|indexer
`

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func TestLoad_Basic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	writeFile(t, path, sampleManifest)

	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got, want := len(m.Entries), 4; got != want {
		t.Fatalf("len(Entries) = %d, want %d", got, want)
	}
	wantIDs := []string{"m01", "m02", "m03", "m04"}
	for i, want := range wantIDs {
		if m.Entries[i].ID != want {
			t.Errorf("Entries[%d].ID = %q, want %q", i, m.Entries[i].ID, want)
		}
	}
	if m.Entries[3].Depends == nil || len(m.Entries[3].Depends) != 2 {
		t.Fatalf("m04 deps = %v, want [m02 m03]", m.Entries[3].Depends)
	}
	if m.Entries[3].Depends[0] != "m02" || m.Entries[3].Depends[1] != "m03" {
		t.Errorf("m04 deps = %v, want [m02 m03]", m.Entries[3].Depends)
	}
	if m.Entries[0].Group != "foundation" {
		t.Errorf("m01 group = %q, want foundation", m.Entries[0].Group)
	}
}

func TestLoad_NotFound(t *testing.T) {
	_, err := Load(filepath.Join(t.TempDir(), "missing.cfg"))
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

func TestLoad_EmptyPath(t *testing.T) {
	_, err := Load("")
	if err == nil {
		t.Fatal("expected error for empty path")
	}
}

func TestLoad_OnlyComments(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	writeFile(t, path, "# only comments\n# nothing else\n\n")
	_, err := Load(path)
	if !errors.Is(err, ErrEmpty) {
		t.Fatalf("err = %v, want ErrEmpty", err)
	}
}

func TestLoad_StatusDefaultsToPending(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	writeFile(t, path, "m01|Title|||file.md|\n")
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if m.Entries[0].Status != "pending" {
		t.Errorf("Status = %q, want pending", m.Entries[0].Status)
	}
}

func TestLoad_TrimsWhitespace(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	writeFile(t, path, "  m01  |  My Title  |  done  |  |  file.md  |  group  \n")
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	e := m.Entries[0]
	if e.ID != "m01" || e.Title != "My Title" || e.Status != "done" || e.File != "file.md" || e.Group != "group" {
		t.Errorf("trim failed: %+v", e)
	}
}

func TestLoad_SkipsBlankIDLines(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	// One line with empty ID — bash silently skips these. Should not break Load.
	writeFile(t, path, "|Bad|done|||\nm01|Good|done||x.md|\n")
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(m.Entries) != 1 || m.Entries[0].ID != "m01" {
		t.Errorf("entries = %+v, want only m01", m.Entries)
	}
}

func TestLoad_TrailingFieldsOptional(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	// Old-style row missing the parallel_group column.
	writeFile(t, path, "m01|T|done||x.md\n")
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if m.Entries[0].Group != "" {
		t.Errorf("Group = %q, want empty", m.Entries[0].Group)
	}
}

func TestGet(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	writeFile(t, path, sampleManifest)
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	e, ok := m.Get("m02")
	if !ok || e.ID != "m02" || e.Status != "in_progress" {
		t.Errorf("Get(m02) = (%+v, %v)", e, ok)
	}
	if _, ok := m.Get("m999"); ok {
		t.Error("Get(m999) returned ok=true, want false")
	}
}

func TestSetStatus(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	writeFile(t, path, sampleManifest)
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if err := m.SetStatus("m03", "done"); err != nil {
		t.Fatalf("SetStatus: %v", err)
	}
	e, _ := m.Get("m03")
	if e.Status != "done" {
		t.Errorf("Status = %q, want done", e.Status)
	}
	if err := m.SetStatus("m999", "done"); !errors.Is(err, ErrUnknownID) {
		t.Errorf("SetStatus unknown: err = %v, want ErrUnknownID", err)
	}
	if err := m.SetStatus("m01", "bad|status"); !errors.Is(err, ErrInvalidField) {
		t.Errorf("SetStatus pipe: err = %v, want ErrInvalidField", err)
	}
}

func TestFrontier(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	writeFile(t, path, sampleManifest)
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	got := m.Frontier()
	// m01 is done → excluded; m02 in_progress with dep m01=done → included;
	// m03 pending with dep m01=done → included; m04 pending with deps
	// m02(in_progress)+m03(pending) → excluded.
	wantIDs := []string{"m02", "m03"}
	if len(got) != len(wantIDs) {
		t.Fatalf("Frontier len = %d, want %d (got %+v)", len(got), len(wantIDs), got)
	}
	for i, want := range wantIDs {
		if got[i].ID != want {
			t.Errorf("Frontier[%d].ID = %q, want %q", i, got[i].ID, want)
		}
	}
}

func TestFrontier_SkipsSplit(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	writeFile(t, path, "m01|First|split||a.md|\nm02|Second|pending|m01|b.md|\n")
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	got := m.Frontier()
	// m01 is split → excluded; m02 depends on split m01 (not done) → excluded.
	if len(got) != 0 {
		t.Errorf("Frontier = %+v, want empty (split parent should not satisfy deps)", got)
	}
}

func TestFrontier_UnknownDep(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	writeFile(t, path, "m01|First|pending|m_unknown|a.md|\n")
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := m.Frontier(); len(got) != 0 {
		t.Errorf("Frontier = %+v, want empty for unknown dep", got)
	}
}

func TestSave_RoundTrip_PreservesCommentsAndBlanks(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	original := `# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group

# Phase 1
m01|First|done||m01.md|p1
m02|Second|pending|m01|m02.md|p1

# Phase 2 — TODO
m03|Third|pending|m02|m03.md|p2
`
	writeFile(t, path, original)
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if err := m.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(got) != original {
		t.Errorf("round-trip diff:\n--- want ---\n%s\n--- got ---\n%s", original, string(got))
	}
}

func TestSave_AfterSetStatus(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	writeFile(t, path, sampleManifest)
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if err := m.SetStatus("m03", "done"); err != nil {
		t.Fatalf("SetStatus: %v", err)
	}
	if err := m.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}
	m2, err := Load(path)
	if err != nil {
		t.Fatalf("Load2: %v", err)
	}
	if e, _ := m2.Get("m03"); e.Status != "done" {
		t.Errorf("after Save+Load, m03 status = %q, want done", e.Status)
	}
	// Comment lines should still be intact.
	got, _ := os.ReadFile(path)
	if !strings.Contains(string(got), "# Tekhton Milestone Manifest v1") {
		t.Errorf("header comment lost after Save: %q", string(got))
	}
}

func TestSave_BuildFromScratchEmitsDefaultHeader(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	m := &Manifest{Path: path, idx: map[string]int{}}
	m.Entries = append(m.Entries, &Entry{
		ID: "m01", Title: "First", Status: "pending", File: "m01.md", Group: "p1",
	})
	m.idx["m01"] = 0
	if err := m.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, _ := os.ReadFile(path)
	wantHeader := "# Tekhton Milestone Manifest v1\n# id|title|status|depends_on|file|parallel_group\n"
	if !strings.HasPrefix(string(got), wantHeader) {
		t.Errorf("scratch save header = %q, want prefix %q", string(got), wantHeader)
	}
	if !strings.Contains(string(got), "m01|First|pending||m01.md|p1") {
		t.Errorf("scratch save row missing: %q", string(got))
	}
}

func TestSave_RejectsPipeInField(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	m := &Manifest{Path: path, idx: map[string]int{"m01": 0}}
	m.Entries = []*Entry{{ID: "m01", Title: "Has | pipe", Status: "pending", File: "m01.md"}}
	err := m.Save()
	if !errors.Is(err, ErrInvalidField) {
		t.Errorf("Save with pipe in title: err = %v, want ErrInvalidField", err)
	}
}

func TestSave_AtomicWrite_RecoverableTmpfileFailure(t *testing.T) {
	// Write into a directory that becomes nonexistent — verifies cleanup.
	dir := t.TempDir()
	path := filepath.Join(dir, "subdir", "MANIFEST.cfg")
	writeFile(t, filepath.Join(dir, "MANIFEST.cfg"), sampleManifest)
	m, err := Load(filepath.Join(dir, "MANIFEST.cfg"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	m.Path = path
	if err := m.Save(); err != nil {
		t.Fatalf("Save (auto-mkdir): %v", err)
	}
	// Ensure no .tmp leftovers in the subdir.
	entries, _ := os.ReadDir(filepath.Dir(path))
	for _, e := range entries {
		if strings.Contains(e.Name(), ".tmp") {
			t.Errorf("leftover tmpfile: %s", e.Name())
		}
	}
}

func TestToProto(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	writeFile(t, path, sampleManifest)
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	p := m.ToProto()
	if p.Proto != "tekhton.manifest.v1" {
		t.Errorf("Proto = %q", p.Proto)
	}
	if len(p.Entries) != 4 {
		t.Errorf("len(Entries) = %d, want 4", len(p.Entries))
	}
	if p.Entries[3].Depends[0] != "m02" {
		t.Errorf("Entries[3].Depends[0] = %q, want m02", p.Entries[3].Depends[0])
	}
}

func TestConcurrentReadsAfterRename(t *testing.T) {
	// Smoke test: spam concurrent Loads while another goroutine spams Saves.
	// Each Load must succeed without error (atomic rename guarantees
	// readers see either pre- or post-state).
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	writeFile(t, path, sampleManifest)
	m, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	var wg sync.WaitGroup
	stop := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		toggle := false
		for {
			select {
			case <-stop:
				return
			default:
			}
			toggle = !toggle
			status := "done"
			if toggle {
				status = "pending"
			}
			_ = m.SetStatus("m03", status)
			_ = m.Save()
		}
	}()
	for i := 0; i < 200; i++ {
		got, err := Load(path)
		if err != nil {
			close(stop)
			wg.Wait()
			t.Fatalf("concurrent Load[%d]: %v", i, err)
		}
		if len(got.Entries) != 4 {
			close(stop)
			wg.Wait()
			t.Fatalf("concurrent Load[%d]: entries = %d, want 4", i, len(got.Entries))
		}
	}
	close(stop)
	wg.Wait()
}
