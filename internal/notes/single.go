package notes

import "strings"

// PickNext returns the first Pending note in priority order. Mirrors
// `pick_next_note` from lib/notes_single.sh — used by `--human` mode
// to pull one note at a time off the queue. Returns nil when no
// Pending note matches the filter.
//
// Walk order:
//
//	when filterTag != "" — only that tag's notes (in document order)
//	otherwise            — registry priority order, then document order
//	                       within each section.
func PickNext(d *Document, filterTag string) *Note {
	if d == nil {
		return nil
	}
	if filterTag != "" {
		for _, n := range d.Notes {
			if n.State != Pending {
				continue
			}
			if n.Tag != filterTag {
				continue
			}
			return n
		}
		return nil
	}
	priority := DefaultTagPriority
	if d.Registry != nil {
		priority = d.Registry.Priority()
	}
	for _, tag := range priority {
		for _, n := range d.Notes {
			if n.State != Pending {
				continue
			}
			if n.Tag != tag {
				continue
			}
			return n
		}
	}
	return nil
}

// ExtractText returns the human-readable title of the note with the
// trailing metadata comment removed. Mirrors `extract_note_text` from
// lib/notes_single.sh. The Document parser already strips metadata
// into Note.Title, so this is just a convenience wrapper that exists
// so callers reading raw line text from `Document.Lines` still have a
// one-call path to the clean title.
func ExtractText(raw string) string {
	raw = strings.TrimPrefix(raw, "- ")
	for _, prefix := range []string{"[ ] ", "[x] ", "[~] "} {
		if strings.HasPrefix(raw, prefix) {
			raw = raw[len(prefix):]
			break
		}
	}
	if idx := strings.Index(raw, " <!-- note:"); idx >= 0 {
		raw = raw[:idx]
	}
	return raw
}

// CountUncheckedInSection returns the count of Pending notes inside the
// supplied section heading (e.g. "Bugs"). Mirrors the section-scoped
// branch of `count_unchecked_notes` from lib/notes_single.sh. Empty
// section name → count across all sections.
func CountUncheckedInSection(d *Document, section string) int {
	if d == nil {
		return 0
	}
	c := 0
	for _, n := range d.Notes {
		if n.State != Pending {
			continue
		}
		if section != "" && n.SectionHeading != section {
			continue
		}
		c++
	}
	return c
}

// ClaimSingle transitions exactly one note (by ID, with a description
// for logging) from Pending → Active. Mirrors `claim_single_note`.
// The bash side optionally archived a pre-mutation snapshot; the Go
// side leaves that responsibility to the caller (the rollback
// subsystem handles snapshots explicitly).
func ClaimSingle(d *Document, id string) error {
	if d == nil {
		return ErrNoteNotFound
	}
	return d.Claim(id)
}

// ResolveSingle transitions exactly one note based on the supplied
// exit code. Mirrors `resolve_single_note`. ExitCode 0 → Done;
// otherwise → Pending. Returns ErrNoteNotFound when the ID is unknown
// or already at the wrong state for the transition.
func ResolveSingle(d *Document, id string, exitCode int) error {
	if d == nil {
		return ErrNoteNotFound
	}
	n, err := d.FindByID(id)
	if err != nil {
		return err
	}
	target := Done
	if exitCode != 0 {
		target = Pending
	}
	n.SetState(d, target)
	return nil
}
