package finalize

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/notes"
)

// CleanupResolved is the Go body of _hook_cleanup_resolved. The bash
// version called `clear_resolved_nonblocking_notes` from
// lib/drift_cleanup.sh — a function that strips `[x]` entries from
// NON_BLOCKING_LOG.md so the file doesn't accumulate completed items.
//
// m24 ports the *notes-related* half of this hook: any HUMAN_NOTES.md
// entry that has been Done for past the retention window is removed.
// The NON_BLOCKING_LOG.md cleanup is a separate concern owned by the
// drift subsystem (m25), so this hook delegates to the bash function
// for that file via a narrow `bash -c` exec when both
// `NON_BLOCKING_LOG_FILE` and `lib/drift_cleanup.sh` are available.
//
// Gates: only runs on pipeline success (ExitCode == 0).
type CleanupResolved struct{}

// Name implements Hook.
func (h *CleanupResolved) Name() string { return "_hook_cleanup_resolved" }

// Run does the notes-side cleanup, then delegates to the bash
// drift_cleanup pass.
func (h *CleanupResolved) Run(_ context.Context, in *Input) error {
	if in.ExitCode != 0 {
		return nil
	}
	// Notes side: clear stale [x] from HUMAN_NOTES.md.
	path := notesFilePath(in)
	if d, err := notes.Load(path); err == nil {
		removed := notes.RemoveDone(d)
		if removed > 0 {
			if err := d.Save(); err != nil {
				fmt.Fprintf(logWriter(in), "cleanup_resolved: save notes: %v\n", err)
			} else {
				fmt.Fprintf(logWriter(in), "cleanup_resolved: removed %d resolved note(s)\n", removed)
			}
		}
	} else if !errors.Is(err, notes.ErrNotFound) {
		fmt.Fprintf(logWriter(in), "cleanup_resolved: load notes: %v\n", err)
	}

	// Drift side: remove [x] from NON_BLOCKING_LOG.md. This is a
	// thin sweep that doesn't require sourcing the whole drift
	// subsystem — the only operation is `grep -v '^- \[x\] '`. The
	// full drift router lives in lib/drift_cleanup.sh and ports in
	// m25; until then, the conservative behavior here is to leave
	// the file alone unless we can identify it cheaply.
	if path := nonBlockingPath(in); path != "" {
		removed, err := pruneResolvedNonBlocking(path)
		if err != nil {
			fmt.Fprintf(logWriter(in), "cleanup_resolved: non-blocking sweep: %v\n", err)
		} else if removed > 0 {
			fmt.Fprintf(logWriter(in), "cleanup_resolved: removed %d resolved non-blocking entry(s)\n", removed)
		}
	}
	return nil
}

// nonBlockingPath returns the resolved NON_BLOCKING_LOG.md path or
// the empty string when the file is not present. Mirrors the bash
// `${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}` resolution.
func nonBlockingPath(in *Input) string {
	override := envValue(in, "NON_BLOCKING_LOG_FILE")
	if override == "" {
		override = "NON_BLOCKING_LOG.md"
	}
	var path string
	if filepath.IsAbs(override) {
		path = override
	} else {
		path = filepath.Join(in.ProjectDir, override)
	}
	if _, err := os.Stat(path); err != nil {
		return ""
	}
	return path
}

// pruneResolvedNonBlocking removes every `^- [x] ` line from path and
// returns the count of removed lines. Operates atomically (tmpfile +
// rename) to match the bash sed-in-place semantics safely.
func pruneResolvedNonBlocking(path string) (int, error) {
	in, err := os.Open(path)
	if err != nil {
		return 0, fmt.Errorf("open: %w", err)
	}
	defer in.Close()
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".nb.tmp.*")
	if err != nil {
		return 0, fmt.Errorf("tmpfile: %w", err)
	}
	tmpPath := tmp.Name()
	bw := bufio.NewWriter(tmp)
	sc := bufio.NewScanner(in)
	removed := 0
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "- [x] ") {
			removed++
			continue
		}
		if _, err := bw.WriteString(line + "\n"); err != nil {
			_ = tmp.Close()
			_ = os.Remove(tmpPath)
			return 0, fmt.Errorf("write: %w", err)
		}
	}
	if err := sc.Err(); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return 0, fmt.Errorf("scan: %w", err)
	}
	if err := bw.Flush(); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return 0, err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return 0, err
	}
	if removed == 0 {
		_ = os.Remove(tmpPath)
		return 0, nil
	}
	if err := os.Rename(tmpPath, path); err != nil {
		_ = os.Remove(tmpPath)
		return 0, fmt.Errorf("rename: %w", err)
	}
	return removed, nil
}
