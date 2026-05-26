package drift

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// nonBlockingPreamble is the initial content for NON_BLOCKING_LOG.md
// when the file is missing. Mirrors the bash _ensure_nonblocking_log
// heredoc verbatim.
const nonBlockingPreamble = `# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from ` + "`## Non-Blocking Notes`" + ` in ${REVIEWER_REPORT_FILE}.
The coder is prompted to address these when the count exceeds the threshold.

## Open
<!-- Items added here by the pipeline. Mark [x] when addressed. -->

## Resolved
`

// NonBlocking represents the NON_BLOCKING_LOG.md file. The bash
// equivalent is lib/drift_cleanup.sh.
type NonBlocking struct {
	Path string
	Now  func() time.Time
}

// NewNonBlocking returns a NonBlocking bound to path.
func NewNonBlocking(path string) *NonBlocking {
	return &NonBlocking{Path: path, Now: time.Now}
}

// EnsureFile creates the non-blocking log with its preamble when
// missing, and repairs missing ## Open / ## Resolved headings when
// only one is present. Mirrors the bash _ensure_nonblocking_log
// repair branch.
func (n *NonBlocking) EnsureFile() error {
	if _, err := os.Stat(n.Path); os.IsNotExist(err) {
		if err := os.MkdirAll(filepath.Dir(n.Path), 0o755); err != nil {
			return err
		}
		return os.WriteFile(n.Path, []byte(nonBlockingPreamble), 0o644)
	} else if err != nil {
		return err
	}
	content, err := os.ReadFile(n.Path)
	if err != nil {
		return err
	}
	body := string(content)
	hasOpen := strings.Contains(body, "## Open")
	hasResolved := strings.Contains(body, "## Resolved")
	if hasOpen && hasResolved {
		return nil
	}
	if !hasOpen {
		// Insert ## Open before ## Resolved if Resolved exists,
		// otherwise append at end.
		insert := "## Open\n<!-- Items added here by the pipeline. Mark [x] when addressed. -->\n\n"
		if hasResolved {
			body = strings.Replace(body, "## Resolved", insert+"## Resolved", 1)
		} else {
			if !strings.HasSuffix(body, "\n") {
				body += "\n"
			}
			body += "\n" + insert
		}
	}
	if !hasResolved {
		if !strings.HasSuffix(body, "\n") {
			body += "\n"
		}
		body += "\n## Resolved\n"
	}
	return writeFileAtomic(n.Path, body)
}

// AppendNotes parses the bullet list of reviewer non-blocking notes
// and appends each item to the ## Open section.
func (n *NonBlocking) AppendNotes(task, raw string) error {
	if task == "" {
		task = "unknown"
	}
	entries := parseBulletList(raw)
	if len(entries) == 0 {
		return nil
	}
	if err := n.EnsureFile(); err != nil {
		return err
	}
	date := n.now().Format("2006-01-02")
	lines := make([]string, 0, len(entries))
	for _, e := range entries {
		lines = append(lines, fmt.Sprintf(`- [ ] [%s | "%s"] %s`, date, task, e))
	}
	return insertAfterIn(n.Path, "## Open", lines)
}

// CountOpen returns the number of `- [ ]` entries in the ## Open
// section.
func (n *NonBlocking) CountOpen() (int, error) {
	content, err := os.ReadFile(n.Path)
	if os.IsNotExist(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	count := 0
	in := false
	for _, line := range strings.Split(string(content), "\n") {
		if strings.HasPrefix(line, "## Open") {
			in = true
			continue
		}
		if in && strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### ") {
			break
		}
		if in && strings.HasPrefix(line, "- [ ]") {
			count++
		}
	}
	return count, nil
}

// GetOpen returns the full open-entry lines (one per line in the
// returned slice).
func (n *NonBlocking) GetOpen() ([]string, error) {
	return scanSection(n.Path, "## Open", func(line string) bool {
		return strings.HasPrefix(line, "- [ ]")
	})
}

// ResolveByModifiedFiles is the heuristic that marks `[x]` on any open
// item whose body mentions a file in modifiedFiles. Mirrors the bash
// _resolve_addressed_nonblocking_notes pass.
//
// Returns the count of items transitioned and whether the file was
// rewritten (when count > 0).
func (n *NonBlocking) ResolveByModifiedFiles(modifiedFiles []string) (int, error) {
	if len(modifiedFiles) == 0 {
		return 0, nil
	}
	if _, err := os.Stat(n.Path); os.IsNotExist(err) {
		return 0, nil
	} else if err != nil {
		return 0, err
	}
	content, err := os.ReadFile(n.Path)
	if err != nil {
		return 0, err
	}
	// Build set of basenames to scan for in open-entry text.
	basenames := make([]string, 0, len(modifiedFiles))
	for _, f := range modifiedFiles {
		f = strings.TrimSpace(f)
		if f == "" {
			continue
		}
		basenames = append(basenames, filepath.Base(f))
	}
	if len(basenames) == 0 {
		return 0, nil
	}
	out := make([]string, 0)
	in := false
	resolved := 0
	for _, line := range strings.Split(string(content), "\n") {
		if strings.HasPrefix(line, "## Open") {
			in = true
			out = append(out, line)
			continue
		}
		if in && strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### ") {
			in = false
		}
		if in && strings.HasPrefix(line, "- [ ]") {
			if anyBasenameInLine(line, basenames) {
				newLine := "- [x]" + strings.TrimPrefix(line, "- [ ]")
				out = append(out, newLine)
				resolved++
				continue
			}
		}
		out = append(out, line)
	}
	if resolved == 0 {
		return 0, nil
	}
	if err := writeFileAtomic(n.Path, strings.Join(out, "\n")); err != nil {
		return resolved, err
	}
	return resolved, nil
}

// ClearCompleted moves every `- [x]` entry from ## Open into ##
// Resolved. Returns the count of moved entries. Mirrors the bash
// clear_completed_nonblocking_notes.
func (n *NonBlocking) ClearCompleted() (int, error) {
	if _, err := os.Stat(n.Path); os.IsNotExist(err) {
		return 0, nil
	} else if err != nil {
		return 0, err
	}
	content, err := os.ReadFile(n.Path)
	if err != nil {
		return 0, err
	}
	lines := strings.Split(string(content), "\n")
	var completed []string
	// First pass: collect [x] from ## Open.
	in := false
	for _, line := range lines {
		if strings.HasPrefix(line, "## Open") {
			in = true
			continue
		}
		if in && strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### ") {
			break
		}
		if in && strings.HasPrefix(line, "- [x]") {
			completed = append(completed, line)
		}
	}
	if len(completed) == 0 {
		return 0, nil
	}
	out := make([]string, 0, len(lines))
	inOpen := false
	inResolved := false
	for _, line := range lines {
		if strings.HasPrefix(line, "## Open") && !strings.HasPrefix(line, "### ") {
			inOpen = true
			inResolved = false
			out = append(out, line)
			continue
		}
		if strings.HasPrefix(line, "## Resolved") && !strings.HasPrefix(line, "### ") {
			inOpen = false
			inResolved = true
			out = append(out, line)
			out = append(out, completed...)
			continue
		}
		if inOpen && strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### ") {
			inOpen = false
			out = append(out, line)
			continue
		}
		if inResolved && strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### ") {
			inResolved = false
			out = append(out, line)
			continue
		}
		if inOpen && strings.HasPrefix(line, "- [x]") {
			// Already collected.
			continue
		}
		out = append(out, line)
	}
	return len(completed), writeFileAtomic(n.Path, strings.Join(out, "\n"))
}

// ClearResolved empties the ## Resolved section, returning the cleared
// entries for the caller's metrics capture. Bash equivalent:
// clear_resolved_nonblocking_notes.
func (n *NonBlocking) ClearResolved() ([]string, error) {
	if err := n.EnsureFile(); err != nil {
		return nil, err
	}
	content, err := os.ReadFile(n.Path)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(string(content), "\n")
	var cleared []string
	in := false
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.HasPrefix(line, "## Resolved") && !strings.HasPrefix(line, "### ") {
			in = true
			out = append(out, line)
			continue
		}
		if in && strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### ") {
			in = false
			out = append(out, line)
			continue
		}
		if in {
			if strings.HasPrefix(line, "- ") {
				cleared = append(cleared, line)
			}
			// Skip every line in the section except the heading.
			continue
		}
		out = append(out, line)
	}
	if len(cleared) == 0 {
		return nil, nil
	}
	if err := writeFileAtomic(n.Path, strings.Join(out, "\n")); err != nil {
		return cleared, err
	}
	return cleared, nil
}

func (n *NonBlocking) now() time.Time {
	if n.Now != nil {
		return n.Now()
	}
	return time.Now()
}

// --- helpers (file-local) --------------------------------------------

// insertAfterIn rewrites path by inserting lines immediately after the
// first occurrence of sectionHeader.
func insertAfterIn(path, sectionHeader string, lines []string) error {
	content, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	original := strings.Split(string(content), "\n")
	out := make([]string, 0, len(original)+len(lines))
	inserted := false
	for _, line := range original {
		out = append(out, line)
		if !inserted && strings.HasPrefix(line, sectionHeader) {
			out = append(out, lines...)
			inserted = true
		}
	}
	return writeFileAtomic(path, strings.Join(out, "\n"))
}

// scanSection returns every line in the named section that satisfies
// keep. Section boundary is `^## ` excluding `### `.
func scanSection(path, sectionHeader string, keep func(string) bool) ([]string, error) {
	content, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []string
	in := false
	for _, line := range strings.Split(string(content), "\n") {
		if strings.HasPrefix(line, sectionHeader) {
			in = true
			continue
		}
		if in && strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### ") {
			break
		}
		if in && keep(line) {
			out = append(out, line)
		}
	}
	return out, nil
}

func anyBasenameInLine(line string, basenames []string) bool {
	for _, b := range basenames {
		if b == "" {
			continue
		}
		if strings.Contains(line, b) {
			return true
		}
	}
	return false
}
