package notes

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Snapshot captures the per-note checkbox state at a point in time.
// Used by the rollback subsystem: when a run aborts via Ctrl-C or the
// safety net, restoring the snapshot un-claims any notes that the
// failing run had advanced to Active. Mirrors the JSON-ish blob the
// bash `snapshot_note_states` produced.
type Snapshot struct {
	// CapturedAt is the wall-clock timestamp the snapshot was taken
	// (UTC, RFC3339). The bash side stored only the state map; the Go
	// version preserves the timestamp so callers can reason about
	// snapshot staleness when listing the snapshots directory.
	CapturedAt string `json:"captured_at"`
	// States maps note ID → checkbox glyph (`" "`, `"~"`, or `"x"`)
	// observed at capture time. Maintained for byte-compat with the
	// bash JSON shape consumed by the existing rollback tests.
	States map[string]string `json:"states"`
}

// SnapshotStates returns a Snapshot describing the current
// (post-Load) state of every note in the document. Notes without an
// ID are skipped — they can't be restored anyway.
func SnapshotStates(d *Document) *Snapshot {
	sn := &Snapshot{
		CapturedAt: time.Now().UTC().Format(time.RFC3339),
		States:     map[string]string{},
	}
	if d == nil {
		return sn
	}
	for _, n := range d.Notes {
		if n.ID == "" {
			continue
		}
		sn.States[n.ID] = checkboxInner(n.State)
	}
	return sn
}

// checkboxInner returns the single-character inner content of the
// state's checkbox (`" "`, `"~"`, `"x"`). Mirrors the bash snapshot
// format from `snapshot_note_states`.
func checkboxInner(s State) string {
	switch s {
	case Active:
		return "~"
	case Done:
		return "x"
	default:
		return " "
	}
}

// MarshalLegacy serialises the snapshot in the bash-compatible
// `{"n01":"x","n02":" "}` shape (no captured_at field). Used by the
// rollback parity test and by the bash-shim cutover window. Returns
// `{}` for an empty snapshot to match the bash `echo "{}"` early
// return.
func (s *Snapshot) MarshalLegacy() []byte {
	if s == nil || len(s.States) == 0 {
		return []byte("{}")
	}
	// Sort keys for deterministic output across runs and platforms.
	ids := make([]string, 0, len(s.States))
	for id := range s.States {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var b strings.Builder
	b.WriteByte('{')
	for i, id := range ids {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(&b, "%q:%q", id, s.States[id])
	}
	b.WriteByte('}')
	return []byte(b.String())
}

// WriteSnapshot persists the snapshot under .claude/notes_snapshots/
// using the supplied id (or a timestamp-derived id when empty).
// Returns the full path written. Mirrors the bash behavior of
// archiving snapshots under a timestamped directory.
func WriteSnapshot(projectDir string, sn *Snapshot, id string) (string, error) {
	if id == "" {
		id = sn.CapturedAt
		if id == "" {
			id = time.Now().UTC().Format("20060102_150405")
		}
		id = strings.ReplaceAll(id, ":", "")
	}
	dir := filepath.Join(projectDir, ".claude", "notes_snapshots", id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("notes: mkdir snapshot dir: %w", err)
	}
	path := filepath.Join(dir, "snapshot.json")
	f, err := os.Create(path)
	if err != nil {
		return "", fmt.Errorf("notes: open snapshot: %w", err)
	}
	defer f.Close()
	if err := json.NewEncoder(f).Encode(sn); err != nil {
		return "", fmt.Errorf("notes: encode snapshot: %w", err)
	}
	return path, nil
}

// ReadSnapshot reads a snapshot from disk. Accepts either the
// timestamped directory id (matching what WriteSnapshot wrote) or an
// absolute path to a snapshot.json. The CLI's
// `tekhton note rollback <ID>` accepts the short form.
func ReadSnapshot(projectDir, id string) (*Snapshot, error) {
	var path string
	if filepath.IsAbs(id) {
		path = id
	} else {
		path = filepath.Join(projectDir, ".claude", "notes_snapshots", id, "snapshot.json")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("notes: open snapshot %s: %w", path, err)
	}
	defer f.Close()
	return decodeSnapshot(f)
}

// decodeSnapshot parses a snapshot from r. Accepts both the legacy
// flat-map JSON (bash output) and the Go envelope shape.
func decodeSnapshot(r io.Reader) (*Snapshot, error) {
	raw, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("notes: read snapshot: %w", err)
	}
	// Try the Go envelope first.
	var sn Snapshot
	if err := json.Unmarshal(raw, &sn); err == nil && sn.States != nil {
		return &sn, nil
	}
	// Fall back to legacy flat map.
	var legacy map[string]string
	if err := json.Unmarshal(raw, &legacy); err != nil {
		return nil, fmt.Errorf("notes: parse snapshot: %w", err)
	}
	return &Snapshot{States: legacy}, nil
}

// RestoreStates resets every note that was Pending in the snapshot but
// is Active in the live document back to Pending. Notes that were
// Done in the snapshot stay Done. Notes that were added after the
// snapshot are left untouched (the bash version did the same).
// Mirrors `restore_note_states` from lib/notes_rollback.sh.
func RestoreStates(d *Document, sn *Snapshot) int {
	if d == nil || sn == nil || len(sn.States) == 0 {
		return 0
	}
	reset := 0
	for _, n := range d.Notes {
		if n.ID == "" {
			continue
		}
		prior, ok := sn.States[n.ID]
		if !ok {
			continue
		}
		if n.State == Active && prior == " " {
			n.SetState(d, Pending)
			reset++
		}
	}
	return reset
}
