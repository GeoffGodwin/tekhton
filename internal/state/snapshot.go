// Package state owns the on-disk PIPELINE_STATE.json snapshot.
//
// Pre-m03 the bash side wrote a markdown-with-headings file via heredoc and
// read it back with awk regexes. Both halves leaked: header drift silently
// truncated resume fields, quote-stripping workarounds existed inside the
// writer, and WSL/NTFS atomicity required a temp-file dance per call.
//
// In m03 the file became a JSON envelope (tekhton.state.v1). Atomic writes
// are tmpfile + os.Rename; resume reads are json.Unmarshal. m10 removes the
// legacy markdown reader: any pre-m03 state file now returns ErrLegacyFormat,
// directing the user to migrate via the V4 migration tool rather than
// silently parsing.
package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// ErrNotFound is returned by Read when the state file does not exist.
var ErrNotFound = errors.New("state: snapshot file not found")

// ErrCorrupt is returned by Read when the file is present but unparseable.
// CLI exit 2 maps to this — bash callers must distinguish it from ErrNotFound
// because corruption should trigger --diagnose, not silent retry.
var ErrCorrupt = errors.New("state: snapshot file corrupt")

// ErrLegacyFormat is returned by Read when the file is the pre-m03 V3
// markdown layout (heading-delimited). The legacy reader was retired in m10.
// Callers should surface a migration prompt rather than retrying.
var ErrLegacyFormat = errors.New("state: legacy V3 markdown format; run the V4 migration tool to convert")

// Store owns one PIPELINE_STATE file. Methods are safe for concurrent use
// inside a single process (Update is read-modify-write under mu). Cross-
// process coordination is provided by os.Rename atomicity, not by the mutex.
type Store struct {
	path string
	mu   sync.Mutex
}

// New constructs a Store bound to the given path. The path is not touched
// until a Read/Write/Clear call fires.
func New(path string) *Store {
	return &Store{path: path}
}

// Path returns the configured snapshot path.
func (s *Store) Path() string { return s.path }

// Read returns the parsed snapshot at s.path. If the file does not exist
// ErrNotFound is returned. If the file is present but unparseable, ErrCorrupt
// is returned. If the file is the pre-m03 V3 markdown format, ErrLegacyFormat
// is returned so the caller can prompt the user to run the migration tool —
// the legacy reader was retired in m10.
func (s *Store) Read() (*proto.StateSnapshotV1, error) {
	if s.path == "" {
		return nil, errors.New("state: empty snapshot path")
	}
	f, err := os.Open(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("state: open: %w", err)
	}
	defer f.Close()

	data, err := io.ReadAll(f)
	if err != nil {
		return nil, fmt.Errorf("state: read: %w", err)
	}
	if len(data) == 0 {
		return nil, ErrCorrupt
	}

	if firstNonBlank(data) == '{' {
		var snap proto.StateSnapshotV1
		if err := json.Unmarshal(data, &snap); err != nil {
			return nil, fmt.Errorf("%w: %v", ErrCorrupt, err)
		}
		snap.EnsureProto()
		return &snap, nil
	}

	// Anything else: if it looks like the V3 markdown layout (at least one
	// "## " heading) report ErrLegacyFormat so the bash side surfaces a
	// migration prompt; otherwise it is corrupt.
	if looksLikeLegacyMarkdown(data) {
		return nil, ErrLegacyFormat
	}
	return nil, ErrCorrupt
}

// looksLikeLegacyMarkdown is a single-shot heuristic: any "## " heading at
// the start of a line indicates the pre-m03 markdown layout. We deliberately
// don't try to parse — the goal is just to give a better error than
// ErrCorrupt for a state file that used to be readable.
func looksLikeLegacyMarkdown(data []byte) bool {
	const marker = "\n## "
	if len(data) >= 3 && string(data[:3]) == "## " {
		return true
	}
	for i := 0; i+len(marker) <= len(data); i++ {
		if string(data[i:i+len(marker)]) == marker {
			return true
		}
	}
	return false
}

// Write atomically replaces s.path with the JSON encoding of snap. Crash
// safety relies on os.Rename being atomic on POSIX; on Windows the runtime
// uses MoveFileEx with MOVEFILE_REPLACE_EXISTING since Go 1.5.
//
// Sets Proto and UpdatedAt on the snap value if missing — callers building
// a snapshot field-by-field do not need to remember the envelope tag.
func (s *Store) Write(snap *proto.StateSnapshotV1) error {
	if snap == nil {
		return errors.New("state: write nil snapshot")
	}
	if s.path == "" {
		return errors.New("state: empty snapshot path")
	}
	snap.EnsureProto()
	if snap.UpdatedAt == "" {
		snap.UpdatedAt = nowRFC3339()
	}

	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return fmt.Errorf("state: mkdir: %w", err)
	}

	data, err := snap.MarshalIndented()
	if err != nil {
		return fmt.Errorf("state: marshal: %w", err)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	return atomicWrite(s.path, data)
}

// Update is read-modify-write under the Store mutex. The mutator receives a
// pointer to the parsed snapshot (or a fresh, proto-tagged zero value if the
// file did not exist) and can freely mutate it. UpdatedAt is bumped on
// every successful update.
func (s *Store) Update(fn func(*proto.StateSnapshotV1)) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	var snap *proto.StateSnapshotV1
	cur, err := s.readLocked()
	switch {
	case err == nil:
		snap = cur
	case errors.Is(err, ErrNotFound):
		snap = &proto.StateSnapshotV1{Proto: proto.StateProtoV1, StartedAt: nowRFC3339()}
	default:
		return err
	}
	fn(snap)
	snap.EnsureProto()
	snap.UpdatedAt = nowRFC3339()

	data, err := snap.MarshalIndented()
	if err != nil {
		return fmt.Errorf("state: marshal: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return fmt.Errorf("state: mkdir: %w", err)
	}
	return atomicWrite(s.path, data)
}

// Clear removes the snapshot file. Absent-file is not an error.
func (s *Store) Clear() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	err := os.Remove(s.path)
	if err == nil || os.IsNotExist(err) {
		return nil
	}
	return fmt.Errorf("state: clear: %w", err)
}

// readLocked is the no-mutex Read path used by Update. Read itself acquires
// no mutex, so delegating through a fresh Store bound to the same path keeps
// the contract without copying s (which would copy s.mu and trip
// `go vet -copylocks`).
func (s *Store) readLocked() (*proto.StateSnapshotV1, error) {
	return New(s.path).Read()
}

// atomicWrite materializes data at path via tmpfile + fsync + os.Rename.
// All steps share the same parent directory so the rename is a same-fs op.
func atomicWrite(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".pipeline_state.*.tmp")
	if err != nil {
		return fmt.Errorf("state: create tmp: %w", err)
	}
	tmpName := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpName) }
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		cleanup()
		return fmt.Errorf("state: write tmp: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		cleanup()
		return fmt.Errorf("state: fsync tmp: %w", err)
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return fmt.Errorf("state: close tmp: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		cleanup()
		return fmt.Errorf("state: rename: %w", err)
	}
	return nil
}

func firstNonBlank(data []byte) byte {
	for _, b := range data {
		if b == ' ' || b == '\t' || b == '\n' || b == '\r' {
			continue
		}
		return b
	}
	return 0
}

// nowRFC3339 returns the current time in RFC3339Nano UTC. Indirected so
// snapshot_test.go can pin the timestamp for deterministic comparisons.
var nowRFC3339 = func() string {
	return time.Now().UTC().Format(time.RFC3339Nano)
}
