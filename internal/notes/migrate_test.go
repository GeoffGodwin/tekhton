package notes

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

func TestMigrateLegacy(t *testing.T) {
	d, err := Load(filepath.Join("testdata", "v2_format", "HUMAN_NOTES.md"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if d.IsV2() {
		t.Fatalf("fixture should NOT be v2 before Migrate")
	}
	res, err := Migrate(d)
	if err != nil {
		t.Fatalf("Migrate: %v", err)
	}
	if res.AlreadyV2 {
		t.Errorf("AlreadyV2 should be false on first migrate")
	}
	if res.Migrated != 3 {
		t.Errorf("Migrated = %d, want 3", res.Migrated)
	}
	if !d.IsV2() {
		t.Errorf("document should be v2 after Migrate")
	}
	for _, n := range d.Notes {
		if n.ID == "" {
			t.Errorf("note %q has no ID after Migrate", n.Title)
		}
		if n.Metadata["source"] != "legacy" {
			t.Errorf("note %q source = %q, want legacy", n.Title, n.Metadata["source"])
		}
	}
}

func TestMigrateIdempotent(t *testing.T) {
	// Round-trip golden (already v2) → Migrate must no-op.
	d, err := Load(filepath.Join("testdata", "golden", "round_trip.md"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	res, err := Migrate(d)
	if !errors.Is(err, ErrAlreadyMigrated) {
		t.Errorf("expected ErrAlreadyMigrated, got %v", err)
	}
	if !res.AlreadyV2 {
		t.Errorf("AlreadyV2 should be true on v2 file")
	}
	if res.Migrated != 0 {
		t.Errorf("Migrated = %d, want 0", res.Migrated)
	}
}

func TestMigratePreservesContent(t *testing.T) {
	d, err := Load(filepath.Join("testdata", "v2_format", "HUMAN_NOTES.md"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	_, _ = Migrate(d)
	var lines []string
	for _, ln := range d.Lines {
		lines = append(lines, ln.Raw)
	}
	out := strings.Join(lines, "\n")
	// Original title preserved.
	if !strings.Contains(out, "# Human Notes — legacy") {
		t.Errorf("title lost")
	}
	// Format marker injected.
	if !strings.Contains(out, notesFormatMarker) {
		t.Errorf("marker not injected")
	}
	// Original note text preserved.
	if !strings.Contains(out, "sample legacy bug") {
		t.Errorf("bug text lost")
	}
}
