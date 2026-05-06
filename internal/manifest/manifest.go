// Package manifest owns reading, mutating, and writing MANIFEST.cfg.
//
// Pre-m13 the bash side parsed and rewrote MANIFEST.cfg via awk + sed inside
// lib/milestone_dag_io.sh. Status updates were read-modify-write across two
// awk passes plus an mv, with no atomicity guarantee against concurrent
// readers. m13 ports the parser into Go: bash callers reach this package via
// the `tekhton manifest …` subcommands.
//
// The on-disk format is unchanged. MANIFEST.cfg is human-edited (the
// `tekhton --draft-milestones` flow appends rows; operators occasionally tweak
// status by hand). Flipping it to JSON would break authoring, so we preserve
// the legacy CSV-with-#comments shape exactly. Comment lines and blank lines
// round-trip in their original positions through Load → Save.
//
// Atomicity: Save uses tmpfile + os.Rename in the same directory, matching the
// m03 state-wedge pattern. Concurrent readers see either the pre- or post-state,
// never partial.
package manifest

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// Sentinel errors. Callers match with errors.Is.
var (
	// ErrNotFound is returned by Load when the manifest file does not exist.
	ErrNotFound = errors.New("manifest: file not found")

	// ErrEmpty is returned by Load when the file exists but contains no
	// entries (only comments/blanks). The legacy bash parser returned 1 in
	// this case; this preserves the contract.
	ErrEmpty = errors.New("manifest: no entries found")

	// ErrUnknownID is returned by SetStatus when the ID is not in the manifest.
	ErrUnknownID = errors.New("manifest: unknown milestone id")

	// ErrInvalidField is returned by Load/Save when a field value would break
	// the pipe-delimited format (i.e. contains '|').
	ErrInvalidField = errors.New("manifest: field contains delimiter")
)

// Entry is one milestone row as parsed from MANIFEST.cfg. The legacy bash
// arrays carry the same six fields; this struct keeps that shape.
type Entry struct {
	ID      string
	Title   string
	Status  string
	Depends []string
	File    string
	Group   string
}

// Manifest holds the parsed entries and the file-line layout used to round-
// trip comments and blank lines. Methods are safe for concurrent use within a
// single process; cross-process coordination relies on os.Rename atomicity in
// Save, not on the mutex.
type Manifest struct {
	Path    string
	Entries []*Entry

	mu     sync.Mutex
	layout []layoutItem
	idx    map[string]int // id → index into Entries
}

// layoutItem captures one source line for round-trip preservation.
type layoutItem struct {
	kind  lineKind
	raw   string // for comment/blank: the verbatim line; for entry: ""
	entry *Entry // for entry kind: pointer into Manifest.Entries
}

type lineKind uint8

const (
	lineEntry lineKind = iota
	lineComment
	lineBlank
)

// Default header lines emitted by Save when no original layout is available
// (i.e. when we built a Manifest from scratch). Matches the legacy bash
// save_manifest header so callers that re-write a non-existent manifest
// produce the same first two lines as the legacy bash writer did.
const (
	defaultHeaderVersion = "# Tekhton Milestone Manifest v1"
	defaultHeaderFields  = "# id|title|status|depends_on|file|parallel_group"
)

// Load reads the manifest at path. If the file does not exist Load returns
// ErrNotFound. If it exists but has no entries (only comments/blanks) Load
// returns ErrEmpty — the legacy bash load_manifest returned 1 in that case.
func Load(path string) (*Manifest, error) {
	if path == "" {
		return nil, errors.New("manifest: empty path")
	}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("manifest: open: %w", err)
	}
	defer f.Close()

	m := &Manifest{Path: path, idx: map[string]int{}}

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	lineNum := 0
	for scanner.Scan() {
		lineNum++
		raw := scanner.Text()
		switch classifyLine(raw) {
		case lineBlank:
			m.layout = append(m.layout, layoutItem{kind: lineBlank, raw: raw})
		case lineComment:
			m.layout = append(m.layout, layoutItem{kind: lineComment, raw: raw})
		case lineEntry:
			e, err := parseEntry(raw)
			if err != nil {
				return nil, fmt.Errorf("manifest: line %d: %w", lineNum, err)
			}
			if e == nil {
				// Empty ID after trimming: the legacy parser silently skips
				// these. Preserve that behavior so existing fixtures don't
				// suddenly fail validation.
				continue
			}
			m.Entries = append(m.Entries, e)
			m.idx[e.ID] = len(m.Entries) - 1
			m.layout = append(m.layout, layoutItem{kind: lineEntry, entry: e})
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("manifest: scan: %w", err)
	}
	if len(m.Entries) == 0 {
		return nil, ErrEmpty
	}
	return m, nil
}

// Get returns the entry with the given ID. The bool result is false when the
// ID is not in the manifest.
func (m *Manifest) Get(id string) (*Entry, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	i, ok := m.idx[id]
	if !ok {
		return nil, false
	}
	return m.Entries[i], true
}

// SetStatus updates the status of one entry in memory. Returns ErrUnknownID
// when the ID is not in the manifest. Call Save afterward to persist.
func (m *Manifest) SetStatus(id, status string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	i, ok := m.idx[id]
	if !ok {
		return fmt.Errorf("%w: %q", ErrUnknownID, id)
	}
	if strings.ContainsRune(status, '|') {
		return fmt.Errorf("%w: status %q", ErrInvalidField, status)
	}
	m.Entries[i].Status = status
	return nil
}

// Frontier returns the entries whose dependencies are all done and whose own
// status is actionable (not "done" and not "split"). Order matches manifest
// order. Mirrors the bash dag_get_frontier semantics.
func (m *Manifest) Frontier() []*Entry {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]*Entry, 0, len(m.Entries))
	for _, e := range m.Entries {
		if e.Status == "done" || e.Status == "split" {
			continue
		}
		if !m.depsSatisfiedLocked(e) {
			continue
		}
		out = append(out, e)
	}
	return out
}

func (m *Manifest) depsSatisfiedLocked(e *Entry) bool {
	for _, dep := range e.Depends {
		i, ok := m.idx[dep]
		if !ok {
			// Unknown dep: treat as unsatisfied. validate_manifest catches
			// this case explicitly; Frontier just refuses to surface the
			// dependent rather than crashing.
			return false
		}
		if m.Entries[i].Status != "done" {
			return false
		}
	}
	return true
}

// Save atomically replaces m.Path with a re-emission of the parsed layout.
// Comment and blank lines from the original file appear verbatim; entry lines
// are rendered from the (possibly mutated) Entry structs. tmpfile + os.Rename
// ensure concurrent readers see either the pre- or post-state.
func (m *Manifest) Save() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.Path == "" {
		return errors.New("manifest: empty path")
	}
	if err := os.MkdirAll(filepath.Dir(m.Path), 0o755); err != nil {
		return fmt.Errorf("manifest: mkdir: %w", err)
	}
	data, err := m.render()
	if err != nil {
		return err
	}
	return atomicWrite(m.Path, data)
}

func (m *Manifest) render() ([]byte, error) {
	var b strings.Builder

	if len(m.layout) == 0 {
		// Built-from-scratch manifest (no Load): emit legacy default header so
		// fresh writes look like the bash writer's output.
		b.WriteString(defaultHeaderVersion)
		b.WriteByte('\n')
		b.WriteString(defaultHeaderFields)
		b.WriteByte('\n')
		for _, e := range m.Entries {
			line, err := renderEntry(e)
			if err != nil {
				return nil, err
			}
			b.WriteString(line)
			b.WriteByte('\n')
		}
		return []byte(b.String()), nil
	}

	for _, item := range m.layout {
		switch item.kind {
		case lineBlank, lineComment:
			b.WriteString(item.raw)
			b.WriteByte('\n')
		case lineEntry:
			line, err := renderEntry(item.entry)
			if err != nil {
				return nil, err
			}
			b.WriteString(line)
			b.WriteByte('\n')
		}
	}
	return []byte(b.String()), nil
}

// classifyLine inspects one source line and returns its layout kind.
func classifyLine(raw string) lineKind {
	trimmed := strings.TrimSpace(raw)
	switch {
	case trimmed == "":
		return lineBlank
	case strings.HasPrefix(trimmed, "#"):
		return lineComment
	default:
		return lineEntry
	}
}

// parseEntry splits one pipe-delimited row into an Entry. Whitespace around
// each field is trimmed (matching the legacy bash parser). Returns (nil, nil)
// when the resulting ID is empty, mirroring the bash parser's silent-skip.
func parseEntry(raw string) (*Entry, error) {
	parts := strings.Split(raw, "|")
	// Pad to 6 fields so the legacy "trailing-fields-optional" behavior holds.
	for len(parts) < 6 {
		parts = append(parts, "")
	}
	id := strings.TrimSpace(parts[0])
	if id == "" {
		return nil, nil
	}
	e := &Entry{
		ID:     id,
		Title:  strings.TrimSpace(parts[1]),
		Status: strings.TrimSpace(parts[2]),
		File:   strings.TrimSpace(parts[4]),
		Group:  strings.TrimSpace(parts[5]),
	}
	if e.Status == "" {
		e.Status = "pending"
	}
	depsRaw := strings.TrimSpace(parts[3])
	if depsRaw != "" {
		for _, d := range strings.Split(depsRaw, ",") {
			d = strings.TrimSpace(d)
			if d != "" {
				e.Depends = append(e.Depends, d)
			}
		}
	}
	return e, nil
}

// renderEntry serializes one Entry to its on-disk pipe-delimited line.
// Validates that no field contains the '|' delimiter (which would corrupt
// subsequent reads).
func renderEntry(e *Entry) (string, error) {
	deps := strings.Join(e.Depends, ",")
	for _, fv := range []string{e.ID, e.Title, e.Status, deps, e.File, e.Group} {
		if strings.ContainsRune(fv, '|') {
			return "", fmt.Errorf("%w: %q", ErrInvalidField, fv)
		}
	}
	return e.ID + "|" + e.Title + "|" + e.Status + "|" + deps + "|" + e.File + "|" + e.Group, nil
}

// atomicWrite materializes data at path via tmpfile + fsync + os.Rename.
// Same shape as internal/state's atomicWrite — duplicated here to keep the
// manifest package self-contained.
func atomicWrite(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".manifest.*.tmp")
	if err != nil {
		return fmt.Errorf("manifest: create tmp: %w", err)
	}
	tmpName := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpName) }
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		cleanup()
		return fmt.Errorf("manifest: write tmp: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		cleanup()
		return fmt.Errorf("manifest: fsync tmp: %w", err)
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return fmt.Errorf("manifest: close tmp: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		cleanup()
		return fmt.Errorf("manifest: rename: %w", err)
	}
	return nil
}

// ToProto converts the parsed manifest into the wire-shape envelope used by
// `tekhton manifest list --json`. Order matches manifest order.
func (m *Manifest) ToProto() *proto.ManifestV1 {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := &proto.ManifestV1{
		Proto:   proto.ManifestProtoV1,
		Path:    m.Path,
		Entries: make([]*proto.ManifestEntryV1, 0, len(m.Entries)),
	}
	for _, e := range m.Entries {
		out.Entries = append(out.Entries, &proto.ManifestEntryV1{
			ID:      e.ID,
			Title:   e.Title,
			Status:  e.Status,
			Depends: append([]string(nil), e.Depends...),
			File:    e.File,
			Group:   e.Group,
		})
	}
	return out
}
