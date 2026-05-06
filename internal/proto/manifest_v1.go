package proto

// ManifestProtoV1 is the in-memory proto tag for the parsed manifest shape.
//
// MANIFEST.cfg itself stays in its legacy CSV-with-#comments form on disk:
// it is human-edited (`tekhton --draft-milestones` appends rows; operators
// occasionally tweak status by hand), and flipping the on-disk format to
// JSON would break that workflow. This proto envelope describes only the
// parsed shape — what `tekhton manifest list --json` and library consumers
// see — not what the file looks like on disk.
const ManifestProtoV1 = "tekhton.manifest.v1"

// ManifestEntryV1 is one parsed milestone row.
//
// Field semantics match the legacy bash arrays:
//   - ID:      e.g. "m01"
//   - Title:   free-text milestone title
//   - Status:  one of pending, todo, in_progress, done, skipped, split
//     (the bash parser falls back to "pending" when empty)
//   - Depends: upstream milestone IDs, comma-split into a slice
//   - File:    relative file path within the milestones directory
//   - Group:   parallel_group label (or "" when unset)
type ManifestEntryV1 struct {
	ID      string   `json:"id"`
	Title   string   `json:"title"`
	Status  string   `json:"status"`
	Depends []string `json:"depends,omitempty"`
	File    string   `json:"file,omitempty"`
	Group   string   `json:"group,omitempty"`
}

// ManifestV1 is the JSON-shaped view emitted by `tekhton manifest list --json`.
// Order is preserved (slice, not map) so the output round-trips manifest order.
type ManifestV1 struct {
	Proto   string             `json:"proto"`
	Path    string             `json:"path,omitempty"`
	Entries []*ManifestEntryV1 `json:"entries"`
}
