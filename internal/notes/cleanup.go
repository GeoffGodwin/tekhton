package notes

import (
	"fmt"
	"strings"
)

// ResolveOptions controls how ResolveActive transitions Active notes.
// Mirrors the bash `resolve_human_notes` exit-code branch.
type ResolveOptions struct {
	// ExitCode is the pipeline exit code observed by the finalize
	// chain. 0 → Active becomes Done; non-zero → Active becomes
	// Pending (reset for the next run).
	ExitCode int
	// ClaimedIDs is the list of IDs explicitly claimed during the
	// run. Mirrors the bash `CLAIMED_NOTE_IDS` global. When supplied,
	// these IDs are resolved first; any remaining `[~]` notes are
	// swept by the orphan path.
	ClaimedIDs []string
}

// ResolveResult records the work ResolveActive did, so the calling
// finalize hook can emit a one-line log message.
type ResolveResult struct {
	// ResolvedByID is the number of notes resolved via the
	// ClaimedIDs explicit path.
	ResolvedByID int
	// OrphansSwept is the number of orphan `[~]` notes the function
	// fell back on after the explicit pass.
	OrphansSwept int
	// OutcomeState is the state every resolved/swept note now carries.
	OutcomeState State
}

// ResolveActive transitions every Active note in the document
// according to the supplied ResolveOptions. Mirrors the combined
// behavior of `resolve_human_notes` (lib/notes.sh) and
// `_hook_resolve_notes` (lib/finalize_core_hooks.sh).
//
// When opts.ClaimedIDs is non-empty, those IDs are resolved first.
// Any remaining `[~]` notes (the "orphan" set — claimed via a route
// the finalize chain didn't see) are then swept with the same
// outcome.
func ResolveActive(d *Document, opts ResolveOptions) ResolveResult {
	res := ResolveResult{}
	if d == nil {
		return res
	}
	target := Done
	if opts.ExitCode != 0 {
		target = Pending
	}
	res.OutcomeState = target

	// Explicit-ID pass.
	for _, id := range opts.ClaimedIDs {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		n, err := d.FindByID(id)
		if err != nil {
			continue
		}
		if n.State != Active {
			continue
		}
		n.SetState(d, target)
		res.ResolvedByID++
	}

	// Orphan sweep.
	for _, n := range d.Notes {
		if n.State != Active {
			continue
		}
		n.SetState(d, target)
		res.OrphansSwept++
	}
	return res
}

// ClearActive resets every Active note to Pending without consulting
// the exit code. Used by `_hook_baseline_cleanup` and
// `_hook_failure_context_reset` — when a stage fails before the
// finalize chain runs, ResolveActive's ExitCode-driven branch is the
// wrong choice (the run did not "complete"). ClearActive is the safe
// default in those paths.
func ClearActive(d *Document) int {
	if d == nil {
		return 0
	}
	reset := 0
	for _, n := range d.Notes {
		if n.State != Active {
			continue
		}
		n.SetState(d, Pending)
		reset++
	}
	return reset
}

// RemoveDone removes every Done note line from the document along
// with its description block. Mirrors `clear_completed_human_notes`
// from lib/notes.sh: removes the `- [x] ` line and any trailing
// indented `> ...` description lines that belonged to it. The
// unchecked count is preserved (the bash safety check).
//
// Returns the number of removed top-level notes.
func RemoveDone(d *Document) int {
	if d == nil || len(d.Lines) == 0 {
		return 0
	}
	// Build a "skip" set of line indices to drop.
	skip := make(map[int]struct{})
	removed := 0
	for _, n := range d.Notes {
		if n.State != Done {
			continue
		}
		skip[n.LineIdx] = struct{}{}
		for _, dl := range n.DescLines {
			skip[dl] = struct{}{}
		}
		removed++
	}
	if removed == 0 {
		return 0
	}
	out := make([]*Line, 0, len(d.Lines))
	for i, ln := range d.Lines {
		if _, drop := skip[i]; drop {
			continue
		}
		out = append(out, ln)
	}
	d.Lines = out
	// Notes slice must be rebuilt — line indices shifted. Reparse via
	// the canonical writer→Parse round-trip so caller-visible Note
	// instances remain accurate.
	d.rebuildNotes()
	return removed
}

// rebuildNotes re-derives the Notes slice from Lines. Used by
// mutations that delete lines (RemoveDone) — every Note.LineIdx
// pointer would otherwise dangle.
func (d *Document) rebuildNotes() {
	d.Notes = d.Notes[:0]
	var lastNote *Note
	var currentSection string
	for i, ln := range d.Lines {
		raw := ln.Raw
		if m := sectionPattern.FindStringSubmatch(raw); m != nil {
			currentSection = strings.TrimSpace(m[1])
			lastNote = nil
			ln.NoteIdx = -1
			ln.IsDescription = false
			continue
		}
		if descriptionPattern.MatchString(raw) && lastNote != nil {
			ln.IsDescription = true
			ln.NoteIdx = lastNote.LineIdx
			lastNote.DescLines = append(lastNote.DescLines, i)
			continue
		}
		nm := notePattern.FindStringSubmatch(raw)
		if nm == nil {
			ln.NoteIdx = -1
			ln.IsDescription = false
			lastNote = nil
			continue
		}
		state, err := ParseCheckbox("[" + nm[1] + "]")
		if err != nil {
			continue
		}
		body := nm[2]
		var metaText string
		if mm := metadataPattern.FindStringSubmatchIndex(body); mm != nil {
			metaText = body[mm[2]:mm[3]]
			body = body[:mm[0]]
		}
		var tag string
		if tm := tagPattern.FindStringSubmatch(body); tm != nil {
			tag = tm[1]
			body = tm[2]
		}
		n := &Note{
			LineIdx:        i,
			State:          state,
			Tag:            tag,
			Title:          strings.TrimSpace(body),
			SectionHeading: currentSection,
			Metadata:       map[string]string{},
		}
		if metaText != "" {
			n.HasMetadata = true
			parseMetadata(metaText, n)
		}
		ln.NoteIdx = len(d.Notes)
		ln.IsDescription = false
		d.Notes = append(d.Notes, n)
		lastNote = n
	}
}

// MarkDone transitions the note with the given ID directly to Done.
// Used by `tekhton note done <ID>`. Returns ErrNoteNotFound when the
// ID is unknown.
func (d *Document) MarkDone(id string) error {
	n, err := d.FindByID(id)
	if err != nil {
		return err
	}
	n.SetState(d, Done)
	return nil
}

// MarkPending transitions the note with the given ID to Pending. Used
// by `tekhton note reopen <ID>`.
func (d *Document) MarkPending(id string) error {
	n, err := d.FindByID(id)
	if err != nil {
		return err
	}
	n.SetState(d, Pending)
	return nil
}

// Claim transitions the note with the given ID to Active and returns
// the ID for the caller's CLAIMED_NOTE_IDS bookkeeping. Used by
// `tekhton note claim <ID>` and by the pipeline's per-note claim hook.
func (d *Document) Claim(id string) error {
	n, err := d.FindByID(id)
	if err != nil {
		return err
	}
	if n.State != Pending {
		return fmt.Errorf("notes: cannot claim %s in state %s", id, n.State)
	}
	n.SetState(d, Active)
	return nil
}

// Unclaim transitions the note with the given ID from Active back to
// Pending. Used by `tekhton note unclaim <ID>` when the user wants to
// abort a run-in-progress without finalize sweeping the marker.
func (d *Document) Unclaim(id string) error {
	n, err := d.FindByID(id)
	if err != nil {
		return err
	}
	if n.State != Active {
		return fmt.Errorf("notes: cannot unclaim %s in state %s", id, n.State)
	}
	n.SetState(d, Pending)
	return nil
}

// ResolveByTag bulk-resolves every Pending note carrying the supplied
// tag. Used by `tekhton note resolve --pattern <TAG>`. Returns the
// number of notes transitioned.
func (d *Document) ResolveByTag(tag string) int {
	if d == nil || tag == "" {
		return 0
	}
	count := 0
	for _, n := range d.Notes {
		if n.State != Pending {
			continue
		}
		if n.Tag != tag {
			continue
		}
		n.SetState(d, Done)
		count++
	}
	return count
}

// ClaimMatching transitions every Pending note matching the optional
// tag filter to Active and returns the list of newly-claimed IDs.
// Mirrors `claim_notes_batch` from lib/notes_core.sh — the returned
// list is what the finalize chain reads from CLAIMED_NOTE_IDS.
func (d *Document) ClaimMatching(filterTag string) []string {
	var ids []string
	if d == nil {
		return ids
	}
	for _, n := range d.Notes {
		if n.State != Pending {
			continue
		}
		if filterTag != "" && n.Tag != filterTag {
			continue
		}
		n.SetState(d, Active)
		if n.ID != "" {
			ids = append(ids, n.ID)
		}
	}
	return ids
}
