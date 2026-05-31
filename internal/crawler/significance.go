package crawler

import "path/filepath"

// Significance classifies a change set by structural impact. Thresholds
// match rescan_helpers.sh::_detect_significant_changes verbatim:
//   - Major:    manifestChanges >= 2  ||  newDirs >= 5  ||  deletedFiles >= 10
//   - Moderate: manifestChanges >= 1  ||  newDirs >= 1
//   - Trivial:  anything else
type Significance int

const (
	// Trivial — small content edits that don't touch the project's
	// shape. Rescan can selectively regen inventory + samples + meta.
	Trivial Significance = iota
	// Moderate — at least one new dir or one manifest edit. Rescan
	// regenerates the directory tree (if new dirs) or the dependency
	// graph (if manifest edit) in addition to the trivial set.
	Moderate
	// Major — large structural change (2+ manifests, 5+ new dirs, 10+
	// deletions). Rescan falls back to a full crawl for accuracy.
	Major
)

// String returns the lowercase label that bash printed (used by log
// messages and by tests that match against the bash output verbatim).
func (s Significance) String() string {
	switch s {
	case Major:
		return "major"
	case Moderate:
		return "moderate"
	default:
		return "trivial"
	}
}

// ClassifyChanges returns the Significance verdict for a change set.
// Mirrors rescan_helpers.sh::_detect_significant_changes:
//
//   - A/D under a non-"." directory contribute to newDirs / deletedFiles.
//   - M against a manifest file contributes to manifestChanges.
//   - R that crosses directory boundaries contributes to newDirs.
//   - The R contribution requires both Path and RenameTo populated; if
//     the input lacks RenameTo, the rename is treated as a no-op (matches
//     bash, which only checked old_dir != new_dir when `rest` was set).
//
// Thresholds are load-bearing and must not be tightened or loosened
// without coordinated bash deletion + parity update.
func ClassifyChanges(changes []Change) Significance {
	var newDirs, deletedFiles, manifestChanges int

	for _, c := range changes {
		if c.Status == "" {
			continue
		}
		switch c.Status[0] {
		case 'D':
			deletedFiles++
			if IsManifestFile(c.Path) {
				manifestChanges++
			}
		case 'A':
			if filepath.Dir(c.Path) != "." {
				newDirs++
			}
			if IsManifestFile(c.Path) {
				manifestChanges++
			}
		case 'M':
			if IsManifestFile(c.Path) {
				manifestChanges++
			}
		case 'R':
			if c.RenameTo == "" {
				continue
			}
			if filepath.Dir(c.Path) != filepath.Dir(c.RenameTo) {
				newDirs++
			}
		}
	}

	switch {
	case manifestChanges >= 2 || newDirs >= 5 || deletedFiles >= 10:
		return Major
	case manifestChanges >= 1 || newDirs >= 1:
		return Moderate
	default:
		return Trivial
	}
}
