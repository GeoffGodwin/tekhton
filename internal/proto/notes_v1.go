package proto

// NotesListProtoV1 is the in-memory proto tag for `tekhton note list --format json`.
//
// HUMAN_NOTES.md itself stays in its hand-edited markdown form on disk —
// users add notes via the CLI or by typing into the file. This proto
// envelope only describes the structured CLI output; the markdown file
// is not affected.
const NotesListProtoV1 = "tekhton.notes.list.v1"

// NoteEntryV1 is one note as the CLI list emits it.
//
// Field semantics:
//
//	ID        — the `nNN` identifier (empty for pre-v2 unmigrated notes).
//	Tag       — bracketed category (BUG, FEAT, POLISH, or custom).
//	State     — one of "pending", "active", "done".
//	Title     — note title text (metadata comment stripped).
//	Section   — H2 section heading the note is under (e.g. "Bugs").
//	Priority  — metadata priority (typically "high", "medium", "low").
//	Source    — metadata source (cli, legacy, watchtower-inbox, ...).
//	Created   — metadata created date (YYYY-MM-DD).
//	Triage    — metadata triage disposition if cached.
type NoteEntryV1 struct {
	ID       string `json:"id,omitempty"`
	Tag      string `json:"tag,omitempty"`
	State    string `json:"state"`
	Title    string `json:"title"`
	Section  string `json:"section,omitempty"`
	Priority string `json:"priority,omitempty"`
	Source   string `json:"source,omitempty"`
	Created  string `json:"created,omitempty"`
	Triage   string `json:"triage,omitempty"`
}

// NotesListV1 is the JSON envelope emitted by `tekhton note list --format json`.
type NotesListV1 struct {
	Proto   string         `json:"proto"`
	Path    string         `json:"path,omitempty"`
	Filter  string         `json:"filter,omitempty"`
	Total   int            `json:"total"`
	Entries []*NoteEntryV1 `json:"entries"`
}
