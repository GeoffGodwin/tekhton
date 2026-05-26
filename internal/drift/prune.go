package drift

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// driftArchivePreamble is the initial body of DRIFT_LOG_ARCHIVE.md.
const driftArchivePreamble = `# Drift Log Archive

Archived resolved drift observations from the active drift log.
Entries are moved here when the resolved section exceeds the configured
retention threshold (DRIFT_RESOLVED_KEEP_COUNT).

## Archived Entries
`

// PruneOptions controls a prune pass.
type PruneOptions struct {
	// KeepCount is the maximum number of resolved entries retained
	// in the active drift log. Excess (oldest, by file-tail order)
	// is moved to the archive. Defaults to 20 when zero.
	KeepCount int
	// ArchivePath is the file the excess is appended to. When empty,
	// no archive is written (the excess is dropped — used by tests).
	ArchivePath string
	// Now provides the date-tag for the archive section header.
	Now func() time.Time
}

// Prune keeps only the newest KeepCount resolved entries in the
// active log; the excess (oldest) is appended to ArchivePath.
//
// Resolved entries are inserted at the top of the section (newest
// first by AppendObservations convention) — so head=newest,
// tail=oldest, and `tail -n excess_count` returns the items to
// archive. Returns the count of pruned entries.
func (l *Log) Prune(opts PruneOptions) (int, error) {
	if opts.KeepCount == 0 {
		opts.KeepCount = 20
	}
	if _, err := os.Stat(l.Path); os.IsNotExist(err) {
		return 0, nil
	} else if err != nil {
		return 0, err
	}
	resolved, err := l.GetResolved()
	if err != nil {
		return 0, err
	}
	if len(resolved) <= opts.KeepCount {
		return 0, nil
	}
	keep := resolved[:opts.KeepCount]
	excess := resolved[opts.KeepCount:]

	// Append excess to archive.
	if opts.ArchivePath != "" {
		if err := appendArchive(opts.ArchivePath, excess); err != nil {
			return 0, err
		}
	}

	// Rewrite the drift file with the kept entries only.
	content, err := os.ReadFile(l.Path)
	if err != nil {
		return 0, err
	}
	lines := strings.Split(string(content), "\n")
	out := make([]string, 0, len(lines))
	in := false
	headingWritten := false
	for _, line := range lines {
		if strings.HasPrefix(line, "## Resolved") && !strings.HasPrefix(line, "### ") {
			in = true
			out = append(out, line)
			if !headingWritten {
				out = append(out, keep...)
				headingWritten = true
			}
			continue
		}
		if in && strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### ") {
			in = false
			out = append(out, line)
			continue
		}
		if in {
			// Skip old entries (now archived) and blank lines in the section.
			if strings.HasPrefix(line, "- ") || strings.TrimSpace(line) == "" {
				continue
			}
		}
		out = append(out, line)
	}
	if err := writeFileAtomic(l.Path, strings.Join(out, "\n")); err != nil {
		return 0, err
	}
	return len(excess), nil
}

// appendArchive ensures the archive file exists and appends every
// entry in excess as a new line under "## Archived Entries". The
// archive's blank-line-then-entries shape matches the bash behavior.
func appendArchive(archivePath string, excess []string) error {
	if len(excess) == 0 {
		return nil
	}
	if _, err := os.Stat(archivePath); os.IsNotExist(err) {
		if err := os.MkdirAll(filepath.Dir(archivePath), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(archivePath, []byte(driftArchivePreamble), 0o644); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	f, err := os.OpenFile(archivePath, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := fmt.Fprintln(f); err != nil {
		return err
	}
	for _, e := range excess {
		if _, err := fmt.Fprintln(f, e); err != nil {
			return err
		}
	}
	return nil
}
