// Package dag is the milestone DAG state machine.
//
// Pre-m14 the DAG state lived across four bash files (lib/milestone_dag.sh,
// _helpers.sh, _validate.sh, _migrate.sh) operating on parallel arrays plus
// shared globals. m14 ports that state machine into Go: bash callers reach it
// via the `tekhton dag …` subcommands, while in-memory bash queries continue
// to operate on the cached _DAG_* arrays populated by m13's load_manifest.
//
// The on-disk MANIFEST.cfg format is unchanged (m13 owns it). This package
// builds on internal/manifest and adds:
//
//   - Frontier / Active / DepsSatisfied state queries
//   - Status-transition validation in Advance
//   - Manifest validation: cycle detection, missing deps, unknown statuses,
//     duplicate IDs, missing milestone files
//   - Inline-CLAUDE.md → MANIFEST.cfg migration (idempotent)
package dag

import (
	"errors"
	"fmt"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

// Status constants — the canonical milestone statuses. These mirror the bash
// _DAG_STATUSES contents and are accepted by the Save / set-status path.
const (
	StatusPending    = "pending"
	StatusTodo       = "todo"
	StatusInProgress = "in_progress"
	StatusDone       = "done"
	StatusSkipped    = "skipped"
	StatusSplit      = "split"
)

// Sentinel errors. Callers match with errors.Is.
var (
	// ErrUnknownStatus — status string not in the known set.
	ErrUnknownStatus = errors.New("dag: unknown status")
	// ErrInvalidTransition — transition not allowed by the state machine.
	ErrInvalidTransition = errors.New("dag: invalid status transition")
	// ErrNotFound — id not in the manifest.
	ErrNotFound = errors.New("dag: id not in manifest")
	// ErrCycle — circular dependency detected during validation.
	ErrCycle = errors.New("dag: circular dependency")
	// ErrMissingDep — entry depends on an id that is not in the manifest.
	ErrMissingDep = errors.New("dag: missing dependency target")
	// ErrDuplicateID — two entries share the same id.
	ErrDuplicateID = errors.New("dag: duplicate milestone id")
	// ErrMissingFile — entry references a milestone file that doesn't exist.
	ErrMissingFile = errors.New("dag: milestone file missing")
)

// State is the milestone DAG state machine. It wraps a *manifest.Manifest and
// adds frontier/active/transition semantics. The underlying manifest is the
// source of truth for on-disk persistence — call State.Manifest().Save() to
// flush mutations.
type State struct {
	m *manifest.Manifest
}

// New wraps a manifest with the state machine. Returns nil if m is nil so the
// caller's error path is the explicit one (no panics on misuse).
func New(m *manifest.Manifest) *State {
	if m == nil {
		return nil
	}
	return &State{m: m}
}

// Manifest returns the underlying manifest so callers can Save after Advance.
func (s *State) Manifest() *manifest.Manifest { return s.m }

// Frontier returns ready-to-run milestones in manifest order. Mirrors the bash
// dag_get_frontier semantics: skip status=done | split, require all deps done.
func (s *State) Frontier() []*manifest.Entry { return s.m.Frontier() }

// Active returns entries with status=in_progress in manifest order.
func (s *State) Active() []*manifest.Entry {
	out := make([]*manifest.Entry, 0)
	for _, e := range s.m.Entries {
		if e.Status == StatusInProgress {
			out = append(out, e)
		}
	}
	return out
}

// DepsSatisfied returns true when every dep of id has status=done. Returns
// false (no error) when id is not in the manifest, matching bash semantics.
func (s *State) DepsSatisfied(id string) bool {
	e, ok := s.m.Get(id)
	if !ok {
		return false
	}
	for _, dep := range e.Depends {
		d, ok := s.m.Get(dep)
		if !ok {
			return false
		}
		if d.Status != StatusDone {
			return false
		}
	}
	return true
}

// Advance applies a validated status transition.
//
// Allowed transitions:
//
//	pending → todo, in_progress, skipped
//	todo    → pending, in_progress, skipped
//	in_progress → done, skipped, split, todo, pending
//	done | skipped | split → terminal (only same-status idempotent updates)
//
// The terminal-status idempotent rule lets callers re-issue the same status
// without an error (matching bash dag_set_status' permissive behavior on the
// no-op case). The transition rules are derived from m14's design.
//
// Caller must Save() the underlying manifest to persist.
func (s *State) Advance(id, newStatus string) error {
	if !IsKnownStatus(newStatus) {
		return fmt.Errorf("%w: %q", ErrUnknownStatus, newStatus)
	}
	e, ok := s.m.Get(id)
	if !ok {
		return fmt.Errorf("%w: %q", ErrNotFound, id)
	}
	if !validTransition(e.Status, newStatus) {
		return fmt.Errorf("%w: %s → %s", ErrInvalidTransition, e.Status, newStatus)
	}
	return s.m.SetStatus(id, newStatus)
}

// IsKnownStatus reports whether s is one of the canonical status values.
func IsKnownStatus(s string) bool {
	switch s {
	case StatusPending, StatusTodo, StatusInProgress, StatusDone, StatusSkipped, StatusSplit:
		return true
	}
	return false
}

// validTransition encodes the m14 status-transition table.
func validTransition(from, to string) bool {
	if from == to {
		return true
	}
	switch from {
	case "", StatusPending, StatusTodo:
		return to == StatusPending || to == StatusTodo ||
			to == StatusInProgress || to == StatusSkipped
	case StatusInProgress:
		return to == StatusDone || to == StatusSkipped ||
			to == StatusSplit || to == StatusTodo || to == StatusPending
	case StatusDone, StatusSkipped, StatusSplit:
		return false
	}
	return false
}
