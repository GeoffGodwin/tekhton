package notes

import "errors"

// Sentinel errors. Callers match with errors.Is.
var (
	// ErrNotFound is returned when HUMAN_NOTES.md does not exist on disk.
	// LoadDocument returns this so callers (notably the prompt engine's
	// HUMAN_NOTES_BLOCK builder) can map "missing file" to "empty block"
	// without inspecting the underlying os.IsNotExist.
	ErrNotFound = errors.New("notes: HUMAN_NOTES.md not found")

	// ErrUnknownCheckbox is returned by ParseCheckbox when the supplied
	// glyph is not one of the three canonical strings (`[ ]`, `[~]`, `[x]`).
	// Indicates either a malformed line or a non-note bullet.
	ErrUnknownCheckbox = errors.New("notes: unknown checkbox")

	// ErrNoteNotFound is returned when an ID-based mutation (claim,
	// resolve, done, reopen) cannot locate a matching note in the
	// document. Callers map this to a user-facing "no such note" CLI
	// error.
	ErrNoteNotFound = errors.New("notes: note not found")

	// ErrInvalidTag is returned when an add/list operation references a
	// tag that is not in the active TagRegistry. The CLI prints the
	// allowed tags from registry.Priority() alongside this error.
	ErrInvalidTag = errors.New("notes: invalid tag")

	// ErrEmptyTitle is returned by Add when the supplied title is empty
	// after trimming. The bash side enforced the same via
	// `[[ -z "$text" ]] && error`.
	ErrEmptyTitle = errors.New("notes: note title is required")

	// ErrAlreadyMigrated is returned by Migrate when the document already
	// carries the v2 format marker. Idempotent operations (the CLI's
	// `tekhton note migrate` and the auto-migrate at pipeline start) map
	// this to a no-op exit instead of an error.
	ErrAlreadyMigrated = errors.New("notes: already in v2 format")

	// ErrAmbiguousMatch is returned when a substring-based mutation (e.g.
	// `tekhton note done "fix bug"`) matches more than one note. The
	// caller is expected to either be more specific or supply an ID.
	ErrAmbiguousMatch = errors.New("notes: ambiguous match")
)
