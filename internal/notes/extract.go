package notes

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// ExtractOpts controls the HUMAN_NOTES_BLOCK builder. Mirrors the
// bash `NOTES_FILTER` global (FilterTag) and the implicit "only
// unchecked notes" rule baked into lib/notes.sh::extract_human_notes.
//
// OnlyState defaults to Pending (the only state the bash extractor
// emits). Callers that want a full dump (e.g. `tekhton note list`)
// must set IncludeAll instead.
type ExtractOpts struct {
	// FilterTag restricts output to notes carrying the named bracketed
	// tag. Empty string means "all tags."
	FilterTag string

	// OnlyState restricts output to notes in the specified state. The
	// extractor returns *only* notes whose State == OnlyState. Use the
	// zero value (Pending) for the bash-equivalent behavior.
	OnlyState State

	// IncludeAll disables the state filter — every note is emitted
	// regardless of state. Used by `tekhton note list` without a state
	// filter; the bash equivalent is the unfiltered `list_human_notes_cli`
	// call.
	IncludeAll bool

	// IncludeMetadata leaves the trailing `<!-- note:nNN ... -->` comment
	// on each line. Default false to match the bash extractor's
	// `sed 's/ <!-- note:[^>]*-->//'` step.
	IncludeMetadata bool
}

// stripMetadataRE matches the trailing metadata comment plus any
// leading whitespace. Used to peel `<!-- note:nNN ... -->` off the end
// of an extracted line, mirroring the bash
// `sed 's/ <!-- note:[^>]*-->//'` step.
var stripMetadataRE = regexp.MustCompile(`\s*<!--\s*note:[^>]*-->\s*$`)

// Extract returns the HUMAN_NOTES_BLOCK content — the filtered note
// lines joined by newlines, with the leading `- [ ] ` checkbox replaced
// by a bare `- ` (matching `sed 's/^- \[ \] /- /'`) and the trailing
// metadata comment stripped (unless IncludeMetadata is true).
//
// Returns the empty string when the document is nil, has no matching
// notes, or all matching notes are filtered out. Trailing newline is
// not appended — callers that need one (template substitution, file
// writes) can add it explicitly.
//
// Mirrors `extract_human_notes` from lib/notes.sh:
//
//	if [ -n "$NOTES_FILTER" ]; then
//	    grep "^- \[ \] \[${NOTES_FILTER}\]" "${HUMAN_NOTES_FILE}" \
//	        | sed 's/^- \[ \] /- /' \
//	        | sed 's/ <!-- note:[^>]*-->//' || true
//	else
//	    grep "^- \[ \]" "${HUMAN_NOTES_FILE}" \
//	        | sed 's/^- \[ \] /- /' \
//	        | sed 's/ <!-- note:[^>]*-->//' || true
//	fi
//
// Behavior delta: when FilterTag is non-empty the bash version matches
// "first tag bracket is exactly [TAG]"; this implementation walks the
// parsed Note structs which encode the same fact via Note.Tag (set
// from the first `[XXX]` group on the line). Result is identical for
// any HUMAN_NOTES.md the bash parser accepted.
func Extract(d *Document, opts ExtractOpts) string {
	if d == nil {
		return ""
	}
	var b strings.Builder
	first := true
	for _, n := range d.Notes {
		if !opts.IncludeAll && n.State != opts.OnlyState {
			continue
		}
		if opts.FilterTag != "" && n.Tag != opts.FilterTag {
			continue
		}
		line := d.Lines[n.LineIdx].Raw
		// `^- [ ] ` → `- `. The bash `sed 's/^- \[ \] /- /'` only
		// replaced the Pending checkbox; emit the same shape for
		// non-Pending states so callers that bypass the OnlyState
		// guard (IncludeAll) still see a sensible bullet.
		if strings.HasPrefix(line, "- "+n.State.Checkbox()+" ") {
			line = "- " + line[len("- "+n.State.Checkbox()+" "):]
		}
		if !opts.IncludeMetadata {
			line = stripMetadataRE.ReplaceAllString(line, "")
		}
		if !first {
			b.WriteByte('\n')
		}
		b.WriteString(line)
		first = false
	}
	return b.String()
}

// ExtractFromProject is the convenience entry point the prompt engine
// uses when rendering `HUMAN_NOTES_BLOCK`. Loads the document from the
// supplied project directory and applies the supplied filter; missing
// notes file is mapped to the empty string (matches the bash
// `[ ! -f ... ] && return 0` early-exit).
func ExtractFromProject(projectDir string, opts ExtractOpts) (string, error) {
	d, err := LoadDocument(projectDir)
	if err != nil {
		if isNotFound(err) {
			return "", nil
		}
		return "", err
	}
	return Extract(d, opts), nil
}

// Count returns how many notes in the document match the filter. The
// bash equivalent is the per-tag `tag_counts[$tag]` accumulator built
// inside `list_human_notes_cli`.
func Count(d *Document, opts ExtractOpts) int {
	if d == nil {
		return 0
	}
	c := 0
	for _, n := range d.Notes {
		if !opts.IncludeAll && n.State != opts.OnlyState {
			continue
		}
		if opts.FilterTag != "" && n.Tag != opts.FilterTag {
			continue
		}
		c++
	}
	return c
}

// CountUnchecked is the Go equivalent of bash's `count_human_notes` —
// the number of Pending notes in the document, optionally filtered by
// tag. Returns 0 for a nil document so the prompt engine can call it
// without a pre-check.
func CountUnchecked(d *Document, filterTag string) int {
	return Count(d, ExtractOpts{FilterTag: filterTag, OnlyState: Pending})
}

// PerTagCounts returns the count of notes per tag matching the supplied
// state filter. Output keys are limited to the tags the document's
// registry recognises; unknown tags are aggregated into the empty
// string entry so callers can warn about them.
func PerTagCounts(d *Document, opts ExtractOpts) map[string]int {
	out := map[string]int{}
	if d == nil {
		return out
	}
	for _, n := range d.Notes {
		if !opts.IncludeAll && n.State != opts.OnlyState {
			continue
		}
		if opts.FilterTag != "" && n.Tag != opts.FilterTag {
			continue
		}
		out[n.Tag]++
	}
	return out
}

func isNotFound(err error) bool {
	return errors.Is(err, ErrNotFound)
}

// FormatList renders the notes as `tekhton note list --format md` would
// — one bullet per note with optional tag/state prefix. Used by the
// CLI list command; kept in extract.go so all output-formatting logic
// lives in one file.
func FormatList(d *Document, opts ExtractOpts) string {
	if d == nil {
		return ""
	}
	var b strings.Builder
	first := true
	for _, n := range d.Notes {
		if !opts.IncludeAll && n.State != opts.OnlyState {
			continue
		}
		if opts.FilterTag != "" && n.Tag != opts.FilterTag {
			continue
		}
		if !first {
			b.WriteByte('\n')
		}
		first = false
		fmt.Fprintf(&b, "%s [%s] %s", n.State.Checkbox(), n.Tag, n.Title)
		if n.ID != "" {
			fmt.Fprintf(&b, "  (%s)", n.ID)
		}
	}
	return b.String()
}
