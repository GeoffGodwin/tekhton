package dag

import (
	"errors"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

// loadFixture writes a fixture manifest to a temp dir and loads it.
func loadFixture(t *testing.T, body string) (*State, string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	if err := writeFile(path, body); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	m, err := manifest.Load(path)
	if err != nil {
		t.Fatalf("manifest.Load: %v", err)
	}
	return New(m), dir
}

func writeFile(path, body string) error {
	return writeOSFile(path, []byte(body), 0o644)
}

func TestNewNilManifest(t *testing.T) {
	if New(nil) != nil {
		t.Fatalf("New(nil) should return nil")
	}
}

func TestFrontierMirrorsManifest(t *testing.T) {
	body := `# Tekhton Milestone Manifest v1
m01|First|done||m01.md|
m02|Second|pending|m01|m02.md|
m03|Third|pending|m02|m03.md|
m04|Fourth|done|m02|m04.md|
m05|Fifth|split||m05.md|
`
	s, _ := loadFixture(t, body)
	got := []string{}
	for _, e := range s.Frontier() {
		got = append(got, e.ID)
	}
	want := []string{"m02"}
	if !equal(got, want) {
		t.Fatalf("Frontier = %v, want %v", got, want)
	}
}

func TestActiveReturnsInProgress(t *testing.T) {
	body := `m01|First|done||m01.md|
m02|Second|in_progress|m01|m02.md|
m03|Third|in_progress|m01|m03.md|
m04|Fourth|pending|m02|m04.md|
`
	s, _ := loadFixture(t, body)
	got := []string{}
	for _, e := range s.Active() {
		got = append(got, e.ID)
	}
	if !equal(got, []string{"m02", "m03"}) {
		t.Fatalf("Active = %v, want [m02 m03]", got)
	}
}

func TestActiveEmptyWhenNoneInProgress(t *testing.T) {
	body := `m01|First|done||m01.md|
m02|Second|pending|m01|m02.md|
`
	s, _ := loadFixture(t, body)
	if got := s.Active(); len(got) != 0 {
		t.Fatalf("Active = %v, want empty", got)
	}
}

func TestDepsSatisfied(t *testing.T) {
	body := `m01|First|done||m01.md|
m02|Second|pending|m01|m02.md|
m03|Third|pending|m02|m03.md|
m04|Fourth|pending|m_nonexistent|m04.md|
`
	s, _ := loadFixture(t, body)
	cases := []struct {
		id   string
		want bool
	}{
		{"m01", true},  // no deps
		{"m02", true},  // dep m01 done
		{"m03", false}, // dep m02 pending
		{"m04", false}, // unknown dep
		{"m99", false}, // unknown id
	}
	for _, c := range cases {
		if got := s.DepsSatisfied(c.id); got != c.want {
			t.Errorf("DepsSatisfied(%s) = %v, want %v", c.id, got, c.want)
		}
	}
}

func TestAdvanceTransitions(t *testing.T) {
	body := `m01|First|pending||m01.md|
m02|Second|in_progress|m01|m02.md|
m03|Third|done|m01|m03.md|
m04|Fourth|todo|m01|m04.md|
m05|Fifth|skipped|m01|m05.md|
`
	cases := []struct {
		id      string
		next    string
		wantErr error
	}{
		// pending → in_progress: allowed
		{"m01", StatusInProgress, nil},
		// pending → done: not allowed (must go through in_progress)
		{"m01", StatusDone, ErrInvalidTransition},
		// in_progress → done: allowed
		{"m02", StatusDone, nil},
		// in_progress → todo: allowed (resume after failure)
		{"m02", StatusTodo, nil},
		// in_progress → split: allowed
		{"m02", StatusSplit, nil},
		// done → done: idempotent
		{"m03", StatusDone, nil},
		// done → in_progress: not allowed (terminal)
		{"m03", StatusInProgress, ErrInvalidTransition},
		// todo → in_progress: allowed
		{"m04", StatusInProgress, nil},
		// skipped → in_progress: not allowed (terminal)
		{"m05", StatusInProgress, ErrInvalidTransition},
		// unknown status: rejected
		{"m01", "wibble", ErrUnknownStatus},
		// unknown id: rejected
		{"m99", StatusDone, ErrNotFound},
	}
	for _, c := range cases {
		s, _ := loadFixture(t, body)
		err := s.Advance(c.id, c.next)
		if c.wantErr == nil {
			if err != nil {
				t.Errorf("Advance(%s, %s) = %v, want nil", c.id, c.next, err)
			}
			continue
		}
		if !errors.Is(err, c.wantErr) {
			t.Errorf("Advance(%s, %s) = %v, want errors.Is %v", c.id, c.next, err, c.wantErr)
		}
	}
}

func TestAdvancePersistsViaSave(t *testing.T) {
	body := `m01|First|pending||m01.md|
`
	s, dir := loadFixture(t, body)
	if err := s.Advance("m01", StatusInProgress); err != nil {
		t.Fatalf("Advance: %v", err)
	}
	if err := s.Manifest().Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}
	// Reload and verify.
	m2, err := manifest.Load(filepath.Join(dir, "MANIFEST.cfg"))
	if err != nil {
		t.Fatalf("Reload: %v", err)
	}
	e, ok := m2.Get("m01")
	if !ok {
		t.Fatalf("m01 missing after reload")
	}
	if e.Status != StatusInProgress {
		t.Fatalf("Status = %s, want in_progress", e.Status)
	}
}

func TestIsKnownStatus(t *testing.T) {
	known := []string{
		StatusPending, StatusTodo, StatusInProgress,
		StatusDone, StatusSkipped, StatusSplit,
	}
	for _, s := range known {
		if !IsKnownStatus(s) {
			t.Errorf("IsKnownStatus(%q) = false, want true", s)
		}
	}
	for _, s := range []string{"", "foo", "DONE"} {
		if IsKnownStatus(s) {
			t.Errorf("IsKnownStatus(%q) = true, want false", s)
		}
	}
}

func equal(a, b []string) bool {
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
