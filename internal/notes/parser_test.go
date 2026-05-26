package notes

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRoundTripGolden(t *testing.T) {
	path := filepath.Join("testdata", "golden", "round_trip.md")
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	d, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	var buf bytes.Buffer
	if err := d.Write(&buf); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if !bytes.Equal(buf.Bytes(), want) {
		t.Errorf("round-trip mismatch:\n--- got (%d bytes)\n%s\n--- want (%d bytes)\n%s\n",
			buf.Len(), buf.String(), len(want), string(want))
	}
}

func TestParseNoteFields(t *testing.T) {
	path := filepath.Join("testdata", "golden", "round_trip.md")
	d, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := len(d.Notes); got != 6 {
		t.Fatalf("got %d notes, want 6", got)
	}
	// First note: BUG, Pending, n01, with description line.
	n := d.Notes[0]
	if n.State != Pending {
		t.Errorf("n01 state = %v, want Pending", n.State)
	}
	if n.Tag != "BUG" {
		t.Errorf("n01 tag = %q, want BUG", n.Tag)
	}
	if n.ID != "n01" {
		t.Errorf("n01 ID = %q, want n01", n.ID)
	}
	if n.Title != "tester loses track of orphan test files after partial runs" {
		t.Errorf("n01 title = %q", n.Title)
	}
	if n.Metadata["priority"] != "high" {
		t.Errorf("n01 priority = %q, want high", n.Metadata["priority"])
	}
	if len(n.DescLines) != 1 {
		t.Errorf("n01 should have 1 description line, got %d", len(n.DescLines))
	}
	if n.SectionHeading != "Bugs" {
		t.Errorf("n01 section = %q, want Bugs", n.SectionHeading)
	}
	// Second: Active.
	if d.Notes[1].State != Active {
		t.Errorf("n02 state = %v, want Active", d.Notes[1].State)
	}
	// Third: Done.
	if d.Notes[2].State != Done {
		t.Errorf("n03 state = %v, want Done", d.Notes[2].State)
	}
	// n04 has no description.
	if len(d.Notes[3].DescLines) != 0 {
		t.Errorf("n04 should have no description lines")
	}
}

func TestSetStateRewrite(t *testing.T) {
	path := filepath.Join("testdata", "golden", "round_trip.md")
	d, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	// Mark n01 (Pending) as Done. Only that line should change.
	n01, err := d.FindByID("n01")
	if err != nil {
		t.Fatalf("FindByID: %v", err)
	}
	wantBefore := d.Lines[n01.LineIdx].Raw
	if !strings.HasPrefix(wantBefore, "- [ ] ") {
		t.Fatalf("n01 line should start with `- [ ] `, got %q", wantBefore)
	}
	n01.SetState(d, Done)
	after := d.Lines[n01.LineIdx].Raw
	if !strings.HasPrefix(after, "- [x] ") {
		t.Errorf("after SetState(Done), line = %q", after)
	}
	if !strings.Contains(after, "note:n01") {
		t.Errorf("metadata lost: %q", after)
	}
	if !strings.Contains(after, "priority:high") {
		t.Errorf("priority lost: %q", after)
	}
	// Idempotent.
	n01.SetState(d, Done)
	if d.Lines[n01.LineIdx].Raw != after {
		t.Errorf("SetState not idempotent")
	}
}

func TestNextID(t *testing.T) {
	d, err := Load(filepath.Join("testdata", "golden", "round_trip.md"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := d.NextID(); got != "n07" {
		t.Errorf("NextID = %q, want n07", got)
	}
}

func TestLoadNotFound(t *testing.T) {
	_, err := Load(filepath.Join(t.TempDir(), "missing.md"))
	if err == nil {
		t.Fatalf("expected error for missing file")
	}
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestSetMetadataNewKey(t *testing.T) {
	d, err := Load(filepath.Join("testdata", "golden", "round_trip.md"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	n, err := d.FindByID("n04")
	if err != nil {
		t.Fatalf("FindByID: %v", err)
	}
	n.SetMetadata(d, "triage", "fit")
	line := d.Lines[n.LineIdx].Raw
	if !strings.Contains(line, "triage:fit") {
		t.Errorf("triage:fit not present after SetMetadata: %q", line)
	}
}

func TestSaveAtomic(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join("testdata", "golden", "round_trip.md")
	dst := filepath.Join(dir, "HUMAN_NOTES.md")
	b, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read src: %v", err)
	}
	if err := os.WriteFile(dst, b, 0o644); err != nil {
		t.Fatalf("write dst: %v", err)
	}
	d, err := Load(dst)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if err := d.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("read after save: %v", err)
	}
	if !bytes.Equal(got, b) {
		t.Errorf("Save changed file bytes:\n--- got\n%s\n--- want\n%s", string(got), string(b))
	}
}

func TestNewDocument(t *testing.T) {
	d := NewDocument("foo", nil)
	if len(d.Lines) == 0 {
		t.Fatalf("NewDocument produced no lines")
	}
	if d.Lines[0].Raw != "# Human Notes — foo" {
		t.Errorf("first line = %q", d.Lines[0].Raw)
	}
	if !d.IsV2() {
		t.Errorf("NewDocument should be v2")
	}
}

func TestParseEmptyDocument(t *testing.T) {
	d, err := Parse(strings.NewReader(""))
	if err != nil {
		t.Fatalf("Parse empty: %v", err)
	}
	if len(d.Notes) != 0 {
		t.Errorf("empty doc should have 0 notes")
	}
	if len(d.Lines) != 0 {
		t.Errorf("empty doc should have 0 lines")
	}
}
