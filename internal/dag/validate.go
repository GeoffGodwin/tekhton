package dag

import (
	"fmt"
	"os"
	"path/filepath"
)

// ValidationError describes one problem found during State.Validate. The
// Wrapped sentinel lets callers match with errors.Is(err, dag.ErrCycle) etc.
type ValidationError struct {
	ID      string
	Kind    string
	Msg     string
	Wrapped error
}

// Error returns the human-readable message.
func (e *ValidationError) Error() string { return e.Msg }

// Unwrap returns the sentinel for errors.Is matching.
func (e *ValidationError) Unwrap() error { return e.Wrapped }

// Validate inspects the state for structural problems. Returns nil when the
// manifest is valid. Checks performed:
//
//  1. Duplicate IDs (manifest.Load already deduplicates, but a manifest built
//     by hand could still end up with one).
//  2. Missing dependency targets (an id listed as a dep that's not in the
//     manifest).
//  3. Unknown statuses (anything not in IsKnownStatus).
//  4. Missing milestone files (when milestoneDir is non-empty, the entry's
//     File field must point to a real file under that directory).
//  5. Circular dependencies (DFS).
//
// Pass milestoneDir="" to skip the file-existence check (useful when the
// caller is doing a structural-only validation, e.g. before files exist).
func (s *State) Validate(milestoneDir string) []*ValidationError {
	errs := s.checkDuplicates()
	errs = append(errs, s.checkDeps()...)
	errs = append(errs, s.checkStatuses()...)
	if milestoneDir != "" {
		errs = append(errs, s.checkFiles(milestoneDir)...)
	}
	errs = append(errs, s.checkCycles()...)
	return errs
}

// checkDuplicates scans for repeated IDs. Manifest.Load's idx map collapses
// duplicates by overwriting, but the entries slice still contains both, so we
// detect them here.
func (s *State) checkDuplicates() []*ValidationError {
	var errs []*ValidationError
	seen := map[string]int{}
	for _, e := range s.m.Entries {
		seen[e.ID]++
	}
	for id, n := range seen {
		if n > 1 {
			errs = append(errs, &ValidationError{
				ID:      id,
				Kind:    "duplicate_id",
				Msg:     fmt.Sprintf("duplicate milestone id %q (appears %d times)", id, n),
				Wrapped: ErrDuplicateID,
			})
		}
	}
	return errs
}

// checkDeps reports deps that point at unknown ids.
func (s *State) checkDeps() []*ValidationError {
	var errs []*ValidationError
	for _, e := range s.m.Entries {
		for _, dep := range e.Depends {
			if _, ok := s.m.Get(dep); !ok {
				errs = append(errs, &ValidationError{
					ID:      e.ID,
					Kind:    "missing_dep",
					Msg:     fmt.Sprintf("ERROR: %s depends on '%s' which is not in the manifest", e.ID, dep),
					Wrapped: ErrMissingDep,
				})
			}
		}
	}
	return errs
}

// checkStatuses reports status values outside the canonical set. Empty status
// is permitted (manifest.parseEntry replaces "" with "pending").
func (s *State) checkStatuses() []*ValidationError {
	var errs []*ValidationError
	for _, e := range s.m.Entries {
		if e.Status == "" {
			continue
		}
		if !IsKnownStatus(e.Status) {
			errs = append(errs, &ValidationError{
				ID:      e.ID,
				Kind:    "unknown_status",
				Msg:     fmt.Sprintf("ERROR: %s has unknown status %q", e.ID, e.Status),
				Wrapped: ErrUnknownStatus,
			})
		}
	}
	return errs
}

// checkFiles asserts each entry's File field resolves to an existing file
// under milestoneDir. Empty File field is allowed (some entries are
// pure-manifest with no detail file).
func (s *State) checkFiles(milestoneDir string) []*ValidationError {
	var errs []*ValidationError
	for _, e := range s.m.Entries {
		if e.File == "" {
			continue
		}
		p := filepath.Join(milestoneDir, e.File)
		if _, err := os.Stat(p); err != nil {
			errs = append(errs, &ValidationError{
				ID:      e.ID,
				Kind:    "missing_file",
				Msg:     fmt.Sprintf("ERROR: %s references file '%s' which does not exist in %s", e.ID, e.File, milestoneDir),
				Wrapped: ErrMissingFile,
			})
		}
	}
	return errs
}

// checkCycles is a DFS-based cycle detector. Mirrors bash _dfs_cycle_check:
// missing-dep edges are skipped (those are already reported by checkDeps).
func (s *State) checkCycles() []*ValidationError {
	const (
		stUnvisited = 0
		stOnStack   = 1
		stDone      = 2
	)
	visited := make(map[string]int, len(s.m.Entries))
	var errs []*ValidationError

	var dfs func(id string)
	dfs = func(id string) {
		if visited[id] == stDone {
			return
		}
		visited[id] = stOnStack
		e, ok := s.m.Get(id)
		if ok {
			for _, dep := range e.Depends {
				if _, depOk := s.m.Get(dep); !depOk {
					continue
				}
				switch visited[dep] {
				case stOnStack:
					errs = append(errs, &ValidationError{
						ID:      id,
						Kind:    "cycle",
						Msg:     fmt.Sprintf("ERROR: Circular dependency detected: %s → %s", id, dep),
						Wrapped: ErrCycle,
					})
				case stUnvisited:
					dfs(dep)
				}
			}
		}
		visited[id] = stDone
	}

	for _, e := range s.m.Entries {
		if visited[e.ID] == stUnvisited {
			dfs(e.ID)
		}
	}
	return errs
}
