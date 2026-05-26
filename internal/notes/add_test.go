package notes

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

func TestAddNewNote(t *testing.T) {
	d := loadGolden(t)
	want := "test new feature"
	n, err := d.Add(AddOpts{Title: want, Tag: "FEAT"})
	if err != nil {
		t.Fatalf("Add: %v", err)
	}
	if n.Title != want {
		t.Errorf("note title = %q, want %q", n.Title, want)
	}
	if n.Tag != "FEAT" {
		t.Errorf("note tag = %q, want FEAT", n.Tag)
	}
	if n.ID == "" {
		t.Errorf("note ID was not assigned")
	}
	if n.State != Pending {
		t.Errorf("new note state = %v, want Pending", n.State)
	}
}

func TestAddDuplicate(t *testing.T) {
	d := loadGolden(t)
	// Use an existing FEAT title (case-insensitive).
	n, err := d.Add(AddOpts{Title: "--triage --dry-run subflow", Tag: "FEAT"})
	if err != nil {
		t.Fatalf("Add duplicate: %v", err)
	}
	if n.ID != "n04" {
		t.Errorf("duplicate returned ID = %q, want n04", n.ID)
	}
}

func TestAddInvalidTag(t *testing.T) {
	d := loadGolden(t)
	_, err := d.Add(AddOpts{Title: "x", Tag: "UNKNOWN"})
	if !errors.Is(err, ErrInvalidTag) {
		t.Errorf("expected ErrInvalidTag, got %v", err)
	}
}

func TestAddEmptyTitle(t *testing.T) {
	d := loadGolden(t)
	_, err := d.Add(AddOpts{Title: "   ", Tag: "BUG"})
	if !errors.Is(err, ErrEmptyTitle) {
		t.Errorf("expected ErrEmptyTitle, got %v", err)
	}
}

func TestAddDefaultTagFeat(t *testing.T) {
	d := loadGolden(t)
	n, err := d.Add(AddOpts{Title: "no tag specified"})
	if err != nil {
		t.Fatalf("Add: %v", err)
	}
	if n.Tag != "FEAT" {
		t.Errorf("default tag = %q, want FEAT", n.Tag)
	}
}

func TestAddIntoSection(t *testing.T) {
	d := loadGolden(t)
	_, err := d.Add(AddOpts{Title: "new bug", Tag: "BUG"})
	if err != nil {
		t.Fatalf("Add: %v", err)
	}
	// Check the new line is under ## Bugs but before ## Features.
	var bugIdx, featIdx, newIdx int
	for i, ln := range d.Lines {
		switch {
		case strings.HasPrefix(ln.Raw, "## Bugs"):
			bugIdx = i
		case strings.HasPrefix(ln.Raw, "## Features"):
			featIdx = i
		case strings.Contains(ln.Raw, "new bug"):
			newIdx = i
		}
	}
	if !(bugIdx < newIdx && newIdx < featIdx) {
		t.Errorf("new bug not under Bugs section: bug=%d new=%d feat=%d", bugIdx, newIdx, featIdx)
	}
}

func TestExtractText(t *testing.T) {
	tests := []struct {
		in   string
		want string
	}{
		{"- [ ] [BUG] fix it <!-- note:n01 created:x -->", "[BUG] fix it"},
		{"- [x] [FEAT] add it", "[FEAT] add it"},
		{"- [~] [POLISH] tidy", "[POLISH] tidy"},
	}
	for _, tc := range tests {
		if got := ExtractText(tc.in); got != tc.want {
			t.Errorf("ExtractText(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestResolvePath(t *testing.T) {
	got := ResolvePath("/proj", "")
	want := filepath.Join("/proj", DefaultNotesFileName)
	if got != want {
		t.Errorf("ResolvePath = %q, want %q", got, want)
	}
	if got := ResolvePath("/proj", "/abs/PATH"); got != "/abs/PATH" {
		t.Errorf("ResolvePath absolute = %q", got)
	}
}
