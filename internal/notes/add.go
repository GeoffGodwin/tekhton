package notes

import (
	"fmt"
	"path/filepath"
	"strings"
)

// AddOpts describes a new note to append. Mirrors the bash
// `add_human_note` argument list.
type AddOpts struct {
	// Title is the human-readable note text. Required (empty title
	// returns ErrEmptyTitle).
	Title string
	// Tag is the bracketed category (BUG / FEAT / POLISH / custom).
	// Defaults to FEAT when empty, matching bash.
	Tag string
	// Priority defaults to "medium" when empty.
	Priority string
	// Source defaults to "cli" when empty.
	Source string
	// Description is optional indented `> ...` text appended after
	// the note line.
	Description string
	// InboxFile is an optional metadata field populated by the
	// watchtower inbox processor.
	InboxFile string
}

// Add appends a new note to the document. Mirrors `add_human_note`
// (lib/notes_cli.sh): assigns the next free ID, builds a metadata
// comment, inserts before the next H2 section (or appends to the
// end of the matching section), and de-duplicates by case-insensitive
// (tag, title) pair.
//
// Returns the new Note. If a duplicate exists, returns the existing
// Note without modifying the document.
func (d *Document) Add(opts AddOpts) (*Note, error) {
	if d == nil {
		return nil, fmt.Errorf("notes: nil document")
	}
	title := strings.TrimSpace(opts.Title)
	if title == "" {
		return nil, ErrEmptyTitle
	}
	tag := opts.Tag
	if tag == "" {
		tag = "FEAT"
	}
	if d.Registry == nil {
		d.Registry = NewTagRegistry()
	}
	if !d.Registry.IsKnown(tag) {
		return nil, fmt.Errorf("%w: %s (allowed: %s)",
			ErrInvalidTag, tag, strings.Join(d.Registry.Priority(), ", "))
	}
	// Duplicate check (case-insensitive (tag, title)).
	lowerTitle := strings.ToLower(title)
	for _, n := range d.Notes {
		if n.Tag != tag {
			continue
		}
		if strings.ToLower(n.Title) == lowerTitle {
			return n, nil
		}
	}

	id := d.NextID()
	meta := BuildMetadata(id, opts.Priority, opts.Source, opts.InboxFile)
	entryRaw := fmt.Sprintf("- [ ] [%s] %s %s", tag, title, meta)
	sectionHeading := d.Registry.SectionForTag(tag)
	insertIdx := findInsertIndex(d.Lines, sectionHeading)

	inserts := []*Line{{Raw: entryRaw, NoteIdx: -1}}
	if opts.Description != "" {
		inserts = append(inserts, &Line{Raw: "  > " + opts.Description, NoteIdx: -1})
	}

	d.Lines = appendAt(d.Lines, insertIdx, inserts...)
	fixupAfterInsert(d, insertIdx, len(inserts))
	d.rebuildNotes()
	// Look up the freshly-rebuilt Note by ID for the caller.
	n, err := d.FindByID(id)
	if err != nil {
		return nil, fmt.Errorf("notes: post-add lookup: %w", err)
	}
	return n, nil
}

// findInsertIndex returns the Lines index just before the next H2
// section heading after the supplied section. Falls back to "end of
// document" when the section is not found, or appends just before the
// first encountered section heading after the target when reached.
//
// The bash `add_human_note` walked the file looking for the target
// section then for the next `^##` line; we model the same two-pass
// scan here. Empty sectionHeading → append at end.
func findInsertIndex(lines []*Line, sectionHeading string) int {
	if sectionHeading == "" {
		return len(lines)
	}
	foundSection := false
	for i, ln := range lines {
		if foundSection {
			if strings.HasPrefix(ln.Raw, "## ") {
				return i
			}
			continue
		}
		if ln.Raw == sectionHeading {
			foundSection = true
		}
	}
	if !foundSection {
		// Section not present — append at end.
		return len(lines)
	}
	// Found but no next H2 — append to end.
	return len(lines)
}

// EnsureFile ensures a HUMAN_NOTES.md exists at the supplied path,
// creating it from the standard template when missing. Returns the
// loaded Document (either the existing one or the freshly created
// one). Mirrors `_ensure_notes_file` from lib/notes_cli.sh.
func EnsureFile(path, projectName string) (*Document, error) {
	d, err := Load(path)
	if err == nil {
		return d, nil
	}
	if !isNotFound(err) {
		return nil, err
	}
	d = NewDocument(projectName, nil)
	d.Path = path
	if err := d.Save(); err != nil {
		return nil, err
	}
	return d, nil
}

// ResolvePath returns the on-disk path for HUMAN_NOTES.md given the
// project directory. Respects $HUMAN_NOTES_FILE for absolute paths;
// otherwise joins to projectDir.
func ResolvePath(projectDir, override string) string {
	if override == "" {
		override = DefaultNotesFileName
	}
	if filepath.IsAbs(override) {
		return override
	}
	return filepath.Join(projectDir, override)
}
