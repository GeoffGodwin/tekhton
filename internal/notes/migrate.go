package notes

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
)

// MigrateResult records what Migrate did. Used by the CLI and finalize
// hooks to log a one-line summary. When Migrated == 0 the caller should
// treat the operation as a no-op (no warnings).
type MigrateResult struct {
	// AlreadyV2 is true when the document already carried the v2 format
	// marker — Migrate returned without modifying anything.
	AlreadyV2 bool
	// Migrated is the number of note lines that received a new ID.
	Migrated int
	// BackupPath is the path to the `.v1-backup` snapshot the migrator
	// writes before mutating the file. Empty when AlreadyV2 is true.
	BackupPath string
}

// Migrate upgrades a pre-v2 HUMAN_NOTES.md in place: adds the format
// marker comment, adds `note:nNN` metadata to every note line that
// lacks one, and writes a `.v1-backup` snapshot for rollback. Mirrors
// `migrate_legacy_notes` from lib/notes_migrate.sh.
//
// Idempotent: re-running on a v2 file returns AlreadyV2=true and does
// not modify the file. Safe across crashes: the backup is written
// before any mutation, and Save is atomic (tmpfile + rename).
//
// The function operates on the supplied Document — the caller is
// responsible for reloading the file from disk if needed. Returns
// ErrAlreadyMigrated as a soft error when the file is already v2; the
// CLI swallows this and exits 0.
func Migrate(d *Document) (MigrateResult, error) {
	if d == nil {
		return MigrateResult{}, errors.New("notes: nil document")
	}
	if d.IsV2() {
		return MigrateResult{AlreadyV2: true}, ErrAlreadyMigrated
	}

	// Discover the existing high-water ID so we don't reuse one if some
	// notes already have IDs (mixed v1/v2 file).
	maxID := 0
	for _, n := range d.Notes {
		if n.ID == "" || !strings.HasPrefix(n.ID, "n") {
			continue
		}
		v := 0
		ok := true
		for _, c := range n.ID[1:] {
			if c < '0' || c > '9' {
				ok = false
				break
			}
			v = v*10 + int(c-'0')
		}
		if ok && v > maxID {
			maxID = v
		}
	}
	next := maxID + 1
	res := MigrateResult{}
	created := time.Now().UTC().Format("2006-01-02")

	for _, n := range d.Notes {
		if n.ID != "" {
			continue
		}
		id := fmt.Sprintf("n%02d", next)
		next++
		res.Migrated++
		n.ID = id
		n.HasMetadata = true
		n.Metadata["created"] = created
		n.Metadata["priority"] = "medium"
		n.Metadata["source"] = "legacy"
		n.MetadataOrder = append(n.MetadataOrder, "created", "priority", "source")
		d.Lines[n.LineIdx].Raw = n.serialize()
	}

	// Insert the format marker + "do not remove" comment after the H1
	// title. When there is no H1, prepend to the document.
	insertMarkerLines(d)

	if d.Path != "" {
		res.BackupPath = d.Path + ".v1-backup"
	}
	return res, nil
}

// insertMarkerLines walks Lines for the first H1 (`# ...`) and inserts
// the v2 marker + helpful comment immediately after it. When no H1 is
// present the markers are prepended to the document.
func insertMarkerLines(d *Document) {
	marker := &Line{Raw: notesFormatMarker, NoteIdx: -1}
	helper := &Line{
		Raw:     "<!-- IDs are auto-managed by Tekhton. Do not remove note: comments. -->",
		NoteIdx: -1,
	}
	for i, ln := range d.Lines {
		if strings.HasPrefix(ln.Raw, "# ") {
			d.Lines = appendAt(d.Lines, i+1, marker, helper)
			fixupAfterInsert(d, i+1, 2)
			return
		}
	}
	d.Lines = append([]*Line{marker, helper}, d.Lines...)
	fixupAfterInsert(d, 0, 2)
}

// appendAt inserts the supplied lines at index idx, returning the new
// slice. Used by migrate to splice in the format marker without
// dropping existing content.
func appendAt(lines []*Line, idx int, inserts ...*Line) []*Line {
	out := make([]*Line, 0, len(lines)+len(inserts))
	out = append(out, lines[:idx]...)
	out = append(out, inserts...)
	out = append(out, lines[idx:]...)
	return out
}

// fixupAfterInsert advances every Note.LineIdx and per-line DescLines
// index that is at or after `startIdx` by `count` to reflect the
// insertion. Without this, mutations after Migrate would target the
// wrong lines.
func fixupAfterInsert(d *Document, startIdx, count int) {
	for _, n := range d.Notes {
		if n.LineIdx >= startIdx {
			n.LineIdx += count
		}
		for i, dl := range n.DescLines {
			if dl >= startIdx {
				n.DescLines[i] = dl + count
			}
		}
	}
}

// WriteBackup writes `<doc>.v1-backup` with the *current* contents of
// the document on disk. Call before mutating. Returns nil when the
// source file does not exist (nothing to back up).
func WriteBackup(path string) (string, error) {
	src, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("notes: read for backup: %w", err)
	}
	bk := path + ".v1-backup"
	if err := os.WriteFile(bk, src, 0o644); err != nil {
		return "", fmt.Errorf("notes: write backup: %w", err)
	}
	return bk, nil
}
