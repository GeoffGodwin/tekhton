package notes

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Document is the in-memory representation of HUMAN_NOTES.md. It stores
// every input line verbatim so Write() can produce byte-identical output
// to whatever Load() consumed. Mutations operate on Lines[i].Raw — the
// Notes slice carries cached field views (state, tag, ID, metadata) for
// query/filter logic but is rebuilt from Lines whenever a mutation
// modifies a note line.
//
// Round-trip contract:
//
//	d, _ := Load(path)
//	var buf bytes.Buffer
//	d.Write(&buf)
//	// buf.Bytes() is byte-identical to the file at path.
//
// Mutation contract:
//
//	d.MarkDone("n42")
//	d.Write(...)
//	// All bytes other than line where n42 lives are unchanged;
//	// `[ ]` / `[~]` on that line becomes `[x]` and nothing else
//	// shifts.
type Document struct {
	// Path is the on-disk location the document was loaded from (or the
	// target for Save). Empty when the document was constructed from a
	// reader.
	Path string

	// Lines is every input line in original order. Each entry is the
	// raw line content (no trailing newline). Document.Write joins them
	// with \n and re-adds the original trailing newline state.
	Lines []*Line

	// Notes is the parsed view of every note line in the document, in
	// the order they appear. Each Note has a LineIdx back-pointer into
	// Lines so mutations can update the canonical line text directly.
	Notes []*Note

	// trailingNewline records whether the input ended with a final
	// newline. Write() restores the same trailing state so editor
	// configs that strip/preserve trailing newlines stay stable across
	// round-trips.
	trailingNewline bool

	// Registry resolves tag-related lookups. Defaults to NewTagRegistry()
	// when Load is used; callers can replace it to recognise extra tags
	// from pipeline.conf.
	Registry *TagRegistry
}

// Line is the storage unit for parser round-trip. Every input line —
// blank line, comment, section heading, note, description — becomes
// exactly one Line. Mutations modify Raw; the writer joins Raw values
// without translation.
type Line struct {
	// Raw is the line content without trailing newline.
	Raw string
	// NoteIdx is the index into Document.Notes for note-bearing lines,
	// or -1 for non-note lines. Description lines also point at the
	// owning note (so claim/resolve operations could in principle walk
	// the description block, though the current state machine does
	// not).
	NoteIdx int
	// IsDescription is true when the line is an indented `> ...` block
	// that belongs to the most recent note line. Tracked so Document
	// methods can iterate "note + description" pairs without re-parsing.
	IsDescription bool
}

// Note is the parsed view of a single `- [ ] [TAG] Title <!-- note:nNN -->`
// line. Multiple Notes may share the same Tag; ID is unique once the v2
// migrator has run.
type Note struct {
	// LineIdx is the back-pointer into Document.Lines for the primary
	// note line. Set when the Note is constructed; updated never (Lines
	// are append-only after Load).
	LineIdx int

	// State is the parsed Pending/Active/Done.
	State State

	// Tag is the bracketed tag word (BUG / FEAT / POLISH / ...). Empty
	// only for malformed notes that don't carry a `[TAG]` segment —
	// strict consumers should reject the document via Document.Validate.
	Tag string

	// Title is the human-readable note text — everything between the
	// `[TAG]` bracket and the trailing `<!-- note:... -->` metadata.
	// Leading/trailing whitespace is trimmed.
	Title string

	// ID is the `nNN` identifier from the metadata comment. Empty when
	// the note is in a pre-v2 file that has not been migrated.
	ID string

	// Metadata is every `key:value` pair from the metadata comment
	// other than the leading `note:nNN`. Common keys: created,
	// priority, source, inbox_file, promoted, triage, est_turns,
	// text_hash, triaged, acceptance, reviewer_skipped. Order
	// preservation is best-effort — Write goes through the cached
	// metadata map so re-emission may reorder keys but the values are
	// preserved.
	Metadata map[string]string

	// MetadataOrder records the key order observed at parse time, so
	// metadata round-trips byte-identically when the note is not
	// mutated.
	MetadataOrder []string

	// HasMetadata flags whether the line carried a `<!-- note:... -->`
	// comment at parse time. Used by writers that want to avoid
	// inventing metadata for pre-migration notes.
	HasMetadata bool

	// DescLines is the list of Document.Lines indices for the indented
	// `> ...` description block following this note (may be empty).
	// Mutations rarely touch this — the only consumer today is
	// `tekhton note triage`, which reads description text alongside the
	// title when escalating to the agent.
	DescLines []int

	// SectionHeading is the most recent `## ` line before this note,
	// without the leading `## `. Empty when the note appears outside
	// any H2 section (legacy files).
	SectionHeading string
}

// notePattern matches a note line and captures: leading list marker +
// checkbox state, optional bracketed tag, and the body after the tag
// bracket. The checkbox is one of " " / "x" / "~" / "DEFERRED" — the
// last for NON_BLOCKING_LOG.md's deferred marker (m34.2). Tag bracket
// is matched greedily so titles that themselves contain bracketed
// words (e.g. "[BUG] [WIP] add ...") parse with the first bracket as
// the tag — matches bash's `[[ $line =~ \[BUG\] ]]` scanning behavior.
var notePattern = regexp.MustCompile(`^- \[( |x|~|DEFERRED)\] (.*)$`)

// tagPattern matches the leading `[TAG]` of a note body. Used after
// notePattern matches the line.
var tagPattern = regexp.MustCompile(`^\[([A-Za-z][A-Za-z0-9_]*)\]\s*(.*)$`)

// metadataPattern matches the trailing `<!-- note:nNN ... -->` comment.
// The body capture is everything between `note:` and the closing ` -->`.
var metadataPattern = regexp.MustCompile(`\s*<!--\s*(note:[^>]*?)\s*-->\s*$`)

// idFromMetadata extracts the `nNN` ID from a metadata body. The body
// is the inner content captured by metadataPattern (i.e. starts with
// `note:`).
var idFromMetadata = regexp.MustCompile(`^note:(\S+)`)

// metadataKeyPair matches each `key:value` pair within the metadata
// body. The value is a non-greedy run of non-space characters so
// adjacent keys can be tokenised.
var metadataKeyPair = regexp.MustCompile(`(\S+):(\S+)`)

// descriptionPattern matches an indented `> ...` line that hangs off a
// note. Leading whitespace is preserved (a description line is allowed
// to be either tab- or space-indented).
var descriptionPattern = regexp.MustCompile(`^\s+>`)

// sectionPattern matches an H2 section heading (the line that
// introduces `## Bugs`, `## Features`, etc.). Only H2 — H1 lines are
// the document title.
var sectionPattern = regexp.MustCompile(`^##\s+(.+)$`)

// notesFormatMarker is the HTML comment that marks a file as v2-format
// (post-migration). Mirrors lib/notes_migrate.sh::_NOTES_FORMAT_MARKER.
const notesFormatMarker = "<!-- notes-format: v2 -->"

// DefaultNotesFileName is the basename of the notes file relative to
// the project directory. Mirrors HUMAN_NOTES_FILE's default value in
// pipeline.conf. Consumers can override via HUMAN_NOTES_FILE env or
// explicit path arguments.
const DefaultNotesFileName = "HUMAN_NOTES.md"

// Load reads HUMAN_NOTES.md from disk and returns a parsed Document.
// Returns ErrNotFound (wrapped) when the file is missing — callers that
// treat "missing" as "empty" (the prompt engine, list output) match on
// errors.Is(err, ErrNotFound).
func Load(path string) (*Document, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("%w: %s", ErrNotFound, path)
		}
		return nil, fmt.Errorf("notes: read %s: %w", path, err)
	}
	d, err := Parse(bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("notes: parse %s: %w", path, err)
	}
	d.Path = path
	// Re-derive trailingNewline from the byte stream — bufio.Scanner
	// elides the final newline but we need to know whether the original
	// file had one so Save() round-trips exactly.
	d.trailingNewline = len(raw) > 0 && raw[len(raw)-1] == '\n'
	return d, nil
}

// LoadDocument is a convenience wrapper around Load using the standard
// HUMAN_NOTES_FILE name and a supplied project directory. Returns
// ErrNotFound when no notes file exists.
func LoadDocument(projectDir string) (*Document, error) {
	name := os.Getenv("HUMAN_NOTES_FILE")
	if name == "" {
		name = DefaultNotesFileName
	}
	var path string
	if filepath.IsAbs(name) {
		path = name
	} else {
		path = filepath.Join(projectDir, name)
	}
	return Load(path)
}

// Parse reads from r and returns a parsed Document. Useful for in-memory
// callers (tests, the parity gate); production callers usually want Load.
func Parse(r io.Reader) (*Document, error) {
	d := &Document{
		Registry: NewTagRegistry(),
		Notes:    []*Note{},
		Lines:    []*Line{},
	}
	sc := bufio.NewScanner(r)
	// Allow large lines — the line buffer default of 64KiB is fine for
	// notes files but giving it a 1MiB ceiling guards against pathological
	// hand-edited inputs without preventing a real overflow signal.
	buf := make([]byte, 0, 64*1024)
	sc.Buffer(buf, 1024*1024)

	var currentSection string
	var lastNote *Note
	for sc.Scan() {
		raw := sc.Text()
		line := &Line{Raw: raw, NoteIdx: -1}
		d.Lines = append(d.Lines, line)
		lineIdx := len(d.Lines) - 1

		// Section heading update.
		if m := sectionPattern.FindStringSubmatch(raw); m != nil {
			currentSection = strings.TrimSpace(m[1])
			lastNote = nil
			continue
		}

		// Description line attached to the last note.
		if descriptionPattern.MatchString(raw) && lastNote != nil {
			line.IsDescription = true
			line.NoteIdx = lastNote.LineIdx
			lastNote.DescLines = append(lastNote.DescLines, lineIdx)
			continue
		}

		// Note line.
		nm := notePattern.FindStringSubmatch(raw)
		if nm == nil {
			lastNote = nil
			continue
		}
		state, err := ParseCheckbox("[" + nm[1] + "]")
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", lineIdx+1, err)
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
		title := strings.TrimSpace(body)
		n := &Note{
			LineIdx:        lineIdx,
			State:          state,
			Tag:            tag,
			Title:          title,
			SectionHeading: currentSection,
			Metadata:       map[string]string{},
		}
		if metaText != "" {
			n.HasMetadata = true
			parseMetadata(metaText, n)
		}
		line.NoteIdx = len(d.Notes)
		d.Notes = append(d.Notes, n)
		lastNote = n
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("notes: scan: %w", err)
	}
	return d, nil
}

// parseMetadata splits a `note:nNN created:... priority:... ...`
// metadata body into Note.ID + Note.Metadata. Order of appearance is
// preserved in MetadataOrder so Write() can emit keys in the same order
// the file presented them.
func parseMetadata(body string, n *Note) {
	if m := idFromMetadata.FindStringSubmatch(body); m != nil {
		n.ID = m[1]
	}
	pairs := metadataKeyPair.FindAllStringSubmatch(body, -1)
	for _, p := range pairs {
		if p[1] == "note" {
			continue
		}
		if _, exists := n.Metadata[p[1]]; !exists {
			n.MetadataOrder = append(n.MetadataOrder, p[1])
		}
		n.Metadata[p[1]] = p[2]
	}
}

// Write serialises the document back to w. Lines are joined with `\n`;
// the document's recorded trailing-newline state is restored. Mutations
// land on Lines[i].Raw directly — Write does no re-rendering of note
// fields. To re-emit metadata from the Note structs after mutation, call
// (*Note).Rewrite which sets the owning Line.Raw to the canonical
// serialisation.
func (d *Document) Write(w io.Writer) error {
	bw := bufio.NewWriter(w)
	for i, ln := range d.Lines {
		if _, err := bw.WriteString(ln.Raw); err != nil {
			return err
		}
		// Always emit a newline between lines. The trailing newline (if
		// the file had one) appears after the last write because Lines
		// records *content* lines only — bufio.Scanner elides the final
		// newline from its tokens.
		if i < len(d.Lines)-1 || d.trailingNewline {
			if _, err := bw.WriteString("\n"); err != nil {
				return err
			}
		}
	}
	return bw.Flush()
}

// Save writes the document atomically to Path via tmpfile + os.Rename.
// Returns an error if Path is empty (caller must have used Load, or set
// it explicitly).
func (d *Document) Save() error {
	if d.Path == "" {
		return errors.New("notes: cannot save without a Path")
	}
	dir := filepath.Dir(d.Path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("notes: mkdir %s: %w", dir, err)
	}
	tmp, err := os.CreateTemp(dir, ".notes.tmp.*")
	if err != nil {
		return fmt.Errorf("notes: tmpfile: %w", err)
	}
	tmpPath := tmp.Name()
	if err := d.Write(tmp); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("notes: close tmp: %w", err)
	}
	if err := os.Rename(tmpPath, d.Path); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("notes: rename: %w", err)
	}
	return nil
}

// FindByID returns the Note with the given ID. Returns nil + ErrNoteNotFound
// when no matching note exists.
func (d *Document) FindByID(id string) (*Note, error) {
	for _, n := range d.Notes {
		if n.ID == id {
			return n, nil
		}
	}
	return nil, fmt.Errorf("%w: %s", ErrNoteNotFound, id)
}

// NotesByState returns the notes currently in the given state, in
// document order. Caller must not mutate the returned slice.
func (d *Document) NotesByState(s State) []*Note {
	out := make([]*Note, 0)
	for _, n := range d.Notes {
		if n.State == s {
			out = append(out, n)
		}
	}
	return out
}

// NextID returns the next free `nNN` identifier — one greater than the
// highest ID currently in the document. Used by Add() and by the v2
// migrator. Format is `n%02d`; values above n99 widen to n100, n101...
// just like the bash printf does.
func (d *Document) NextID() string {
	max := 0
	for _, n := range d.Notes {
		if n.ID == "" {
			continue
		}
		if !strings.HasPrefix(n.ID, "n") {
			continue
		}
		v := 0
		for _, c := range n.ID[1:] {
			if c < '0' || c > '9' {
				v = -1
				break
			}
			v = v*10 + int(c-'0')
		}
		if v > max {
			max = v
		}
	}
	return fmt.Sprintf("n%02d", max+1)
}

// SetState mutates the note to the new state and rewrites its line's
// raw text. Idempotent — calling SetState(Done) twice produces the same
// output as calling it once.
func (n *Note) SetState(d *Document, s State) {
	if n.State == s {
		return
	}
	n.State = s
	d.Lines[n.LineIdx].Raw = n.serialize()
}

// SetMetadata updates a single metadata key on the note (or inserts it
// if missing) and rewrites the owning line. Mirrors the bash function
// `_set_note_metadata` from lib/notes_core.sh, including the in-place
// rewrite semantics.
func (n *Note) SetMetadata(d *Document, key, value string) {
	if _, exists := n.Metadata[key]; !exists {
		n.MetadataOrder = append(n.MetadataOrder, key)
	}
	n.Metadata[key] = value
	n.HasMetadata = true
	d.Lines[n.LineIdx].Raw = n.serialize()
}

// serialize renders the note back to a single `- [.] [TAG] Title
// <!-- note:nNN ... -->` line. Always called via SetState/SetMetadata
// so callers never have to think about it; centralised here so the
// metadata key order is honored consistently.
func (n *Note) serialize() string {
	var b strings.Builder
	b.WriteString("- ")
	b.WriteString(n.State.Checkbox())
	b.WriteByte(' ')
	if n.Tag != "" {
		b.WriteByte('[')
		b.WriteString(n.Tag)
		b.WriteString("] ")
	}
	b.WriteString(n.Title)
	if n.HasMetadata {
		b.WriteByte(' ')
		b.WriteString("<!-- ")
		b.WriteString("note:")
		if n.ID != "" {
			b.WriteString(n.ID)
		}
		// Re-emit metadata in observed order, then any keys observed
		// only via SetMetadata after MetadataOrder was populated.
		seen := make(map[string]struct{}, len(n.Metadata))
		for _, k := range n.MetadataOrder {
			v, ok := n.Metadata[k]
			if !ok {
				continue
			}
			seen[k] = struct{}{}
			b.WriteByte(' ')
			b.WriteString(k)
			b.WriteByte(':')
			b.WriteString(v)
		}
		// Stable tail order: lexicographic for anything not in the
		// observed order.
		var extras []string
		for k := range n.Metadata {
			if _, ok := seen[k]; ok {
				continue
			}
			extras = append(extras, k)
		}
		sort.Strings(extras)
		for _, k := range extras {
			b.WriteByte(' ')
			b.WriteString(k)
			b.WriteByte(':')
			b.WriteString(n.Metadata[k])
		}
		b.WriteString(" -->")
	}
	return b.String()
}

// NewDocument creates an empty document with a project-named H1, the v2
// format marker, and the standard section headings. Mirrors the bash
// `_ensure_notes_file` from lib/notes_cli.sh.
func NewDocument(projectName string, registry *TagRegistry) *Document {
	if registry == nil {
		registry = NewTagRegistry()
	}
	if projectName == "" {
		projectName = "project"
	}
	d := &Document{
		Registry:        registry,
		trailingNewline: true,
	}
	push := func(s string) {
		d.Lines = append(d.Lines, &Line{Raw: s, NoteIdx: -1})
	}
	push(fmt.Sprintf("# Human Notes — %s", projectName))
	push(notesFormatMarker)
	push("<!-- IDs are auto-managed by Tekhton. Do not remove note: comments. -->")
	push("")
	push("Add your observations below as unchecked items. The pipeline will inject")
	push("unchecked items into the next coder run and archive them when done.")
	push("")
	push("Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.")
	push("Tag with [BUG], [FEAT], or [POLISH] to use --notes-filter.")
	push("")
	for _, tag := range registry.Priority() {
		push(registry.SectionForTag(tag))
		push(fmt.Sprintf("<!-- - [ ] [%s] Example: describe a %s -->", tag, strings.ToLower(tag)))
		push("")
	}
	return d
}

// IsV2 reports whether the document carries the v2 format marker. The
// migrator uses this to decide whether to convert pre-v2 files; the CLI
// uses it to emit a one-line warning when an old file is detected at
// startup.
func (d *Document) IsV2() bool {
	for _, ln := range d.Lines {
		if strings.Contains(ln.Raw, notesFormatMarker) {
			return true
		}
	}
	return false
}

// BuildMetadata composes a fresh `<!-- note:nNN created:... ... -->`
// metadata string. Mirrors `_build_metadata_comment` from
// lib/notes_core.sh.
func BuildMetadata(id, priority, source, inboxFile string) string {
	if priority == "" {
		priority = "medium"
	}
	if source == "" {
		source = "cli"
	}
	created := time.Now().UTC().Format("2006-01-02")
	var b strings.Builder
	fmt.Fprintf(&b, "<!-- note:%s created:%s priority:%s source:%s", id, created, priority, source)
	if inboxFile != "" {
		b.WriteString(" inbox_file:")
		b.WriteString(inboxFile)
	}
	b.WriteString(" -->")
	return b.String()
}
