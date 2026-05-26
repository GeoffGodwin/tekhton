// Package drift is the m25 Go port of the five lib/drift*.sh files.
//
// It owns three artifact streams that survive across pipeline runs:
//
//   - DRIFT_LOG.md (observation log) — observe.go + prune.go
//   - ARCHITECTURE_DECISION_LOG.md (ADRs) — artifacts.go
//   - HUMAN_ACTION_REQUIRED.md (blocking asks) — artifacts.go
//   - NON_BLOCKING_LOG.md (non-blocking notes) — nonblocking.go
//   - the blocking/non-blocking router with the m21 fix — router.go
//
// Each file maps to one bash file (drift.sh, drift_artifacts.sh,
// drift_prune.sh, drift_cleanup.sh, plus router.go for the new
// classifier). The bodies are pure or write atomically via tmpfile +
// os.Rename so the parity gate can run them headlessly.
package drift

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// initialDriftLog is the seed structure used by EnsureLog. Matches the
// byte-for-byte contents bash _ensure_drift_log used to write.
const initialDriftLog = `# Drift Log

## Metadata
- Last audit: never
- Runs since audit: 0

## Unresolved Observations

## Resolved
`

// Log represents one DRIFT_LOG.md file at a known path. Methods read
// and write the file directly — there is no in-memory cache, mirroring
// the bash convention. This is intentional: drift entries are appended
// during stages and finalize hooks; the cost of a stat+read is
// dwarfed by the agent work that produced the entries.
type Log struct {
	Path string
	// Now returns the current time. Tests substitute a fixed time so
	// the date-tag is deterministic.
	Now func() time.Time
}

// NewLog returns a Log bound to path. Defaults to time.Now for the
// date-tag clock.
func NewLog(path string) *Log {
	return &Log{Path: path, Now: time.Now}
}

// EnsureLog creates the drift log file with the initial structure if
// missing. Idempotent — does nothing when the file is already present.
func (l *Log) EnsureLog() error {
	if _, err := os.Stat(l.Path); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("drift: stat %s: %w", l.Path, err)
	}
	if err := os.MkdirAll(filepath.Dir(l.Path), 0o755); err != nil {
		return fmt.Errorf("drift: mkdir parent: %w", err)
	}
	return os.WriteFile(l.Path, []byte(initialDriftLog), 0o644)
}

// dateTag formats the Log's current time as the date-tag used in
// drift entries (YYYY-MM-DD).
func (l *Log) dateTag() string {
	now := l.Now
	if now == nil {
		now = time.Now
	}
	return now().Format("2006-01-02")
}

// AppendObservations parses a markdown bullet list and appends each
// item to the Unresolved Observations section. Multi-line bullets are
// joined into a single entry. Empty input and "None" tokens are
// skipped — the bash convention.
//
// task is the human-readable task description that gets recorded with
// each entry. Pass an empty string to use "unknown".
func (l *Log) AppendObservations(task string, raw string) error {
	if task == "" {
		task = "unknown"
	}
	entries := parseBulletList(raw)
	if len(entries) == 0 {
		return nil
	}
	if err := l.EnsureLog(); err != nil {
		return err
	}
	date := l.dateTag()
	lines := make([]string, 0, len(entries))
	for _, e := range entries {
		lines = append(lines, fmt.Sprintf(`- [%s | "%s"] %s`, date, task, e))
	}
	return l.insertAfter("## Unresolved Observations", lines)
}

// AppendEntries adds raw text entries to the Unresolved section
// verbatim. Used by the architect audit to re-add Out-of-Scope items
// after a bulk resolve. The "task" label is fixed to "architect audit"
// to match the bash convention.
func (l *Log) AppendEntries(entries []string) error {
	if len(entries) == 0 {
		return nil
	}
	if err := l.EnsureLog(); err != nil {
		return err
	}
	date := l.dateTag()
	lines := make([]string, 0, len(entries))
	for _, e := range entries {
		lines = append(lines, fmt.Sprintf(`- [%s | "architect audit"] %s`, date, e))
	}
	return l.insertAfter("## Unresolved Observations", lines)
}

// CountUnresolved returns the number of unresolved observation
// entries. Used by the audit threshold check.
func (l *Log) CountUnresolved() (int, error) {
	content, err := os.ReadFile(l.Path)
	if os.IsNotExist(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	count := 0
	inSection := false
	for _, line := range strings.Split(string(content), "\n") {
		if strings.HasPrefix(line, "## Unresolved Observations") {
			inSection = true
			continue
		}
		if inSection && strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### ") {
			break
		}
		if inSection && strings.HasPrefix(line, "- [") {
			count++
		}
	}
	return count, nil
}

// ResolveObservations marks every unresolved entry whose body matches
// any of the supplied substring patterns as resolved. Deduplicates
// against the existing Resolved section so re-resolution of the same
// observation doesn't accumulate duplicates.
func (l *Log) ResolveObservations(patterns []string) error {
	if len(patterns) == 0 {
		return nil
	}
	if _, err := os.Stat(l.Path); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	matcher := func(line string) bool {
		for _, p := range patterns {
			if p == "" {
				continue
			}
			if matched, _ := regexp.MatchString(p, line); matched {
				return true
			}
		}
		return false
	}
	return l.moveResolved(matcher)
}

// ResolveAllObservations moves every unresolved entry to Resolved.
// Used by the architect audit when every observation has been
// reviewed.
func (l *Log) ResolveAllObservations() error {
	if _, err := os.Stat(l.Path); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	return l.moveResolved(func(string) bool { return true })
}

// moveResolved is the shared implementation. Walks the file once,
// moves matching unresolved lines to the Resolved section, dedups
// against existing resolved bodies, and writes the result atomically.
func (l *Log) moveResolved(match func(string) bool) error {
	content, err := os.ReadFile(l.Path)
	if err != nil {
		return err
	}
	lines := strings.Split(string(content), "\n")
	existing := collectResolvedBodies(lines)
	date := l.dateTag()

	var out []string
	var newlyResolved []string
	inUnresolved := false
	for _, line := range lines {
		switch {
		case strings.HasPrefix(line, "## Unresolved Observations"):
			inUnresolved = true
			out = append(out, line)
		case strings.HasPrefix(line, "## Resolved"):
			inUnresolved = false
			out = append(out, line)
			if len(newlyResolved) > 0 {
				out = append(out, newlyResolved...)
				newlyResolved = nil
			}
		case inUnresolved && strings.HasPrefix(line, "- [") && match(line):
			stripped := stripBracketTag(line)
			if !containsBody(existing, stripped) {
				newlyResolved = append(newlyResolved, fmt.Sprintf("- [RESOLVED %s] %s", date, stripped))
				existing = append(existing, stripped)
			}
		default:
			out = append(out, line)
		}
	}
	return writeFileAtomic(l.Path, strings.Join(out, "\n"))
}

// GetRunsSinceAudit reads the metadata counter. Returns 0 when the
// file is missing or the counter is malformed.
func (l *Log) GetRunsSinceAudit() (int, error) {
	content, err := os.ReadFile(l.Path)
	if os.IsNotExist(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	re := regexp.MustCompile(`Runs since audit:\s*(\d+)`)
	if m := re.FindStringSubmatch(string(content)); m != nil {
		var n int
		_, _ = fmt.Sscanf(m[1], "%d", &n)
		return n, nil
	}
	return 0, nil
}

// IncrementRunsSinceAudit bumps the counter by one. Ensures the file
// exists first so first-run callers get a valid counter.
func (l *Log) IncrementRunsSinceAudit() error {
	if err := l.EnsureLog(); err != nil {
		return err
	}
	cur, err := l.GetRunsSinceAudit()
	if err != nil {
		return err
	}
	return l.setRunsSinceAudit(cur+1, "")
}

// ResetRunsSinceAudit resets the counter to zero and updates the
// "Last audit" date.
func (l *Log) ResetRunsSinceAudit() error {
	if _, err := os.Stat(l.Path); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	return l.setRunsSinceAudit(0, l.dateTag())
}

// setRunsSinceAudit writes the counter and (when non-empty) the
// last-audit date. Pure substitution — operates on the existing file.
func (l *Log) setRunsSinceAudit(n int, lastAudit string) error {
	content, err := os.ReadFile(l.Path)
	if err != nil {
		return err
	}
	body := string(content)
	body = regexp.MustCompile(`Runs since audit:\s*\d+`).ReplaceAllString(body, fmt.Sprintf("Runs since audit: %d", n))
	if lastAudit != "" {
		body = regexp.MustCompile(`Last audit:\s*.*`).ReplaceAllString(body, "Last audit: "+lastAudit)
	}
	return writeFileAtomic(l.Path, body)
}

// ShouldTriggerAudit returns true when either the unresolved count or
// the runs-since-audit counter meets/exceeds the supplied threshold.
// Ports the bash should_trigger_audit two-condition OR.
func (l *Log) ShouldTriggerAudit(obsThreshold, runsThreshold int) (bool, error) {
	obs, err := l.CountUnresolved()
	if err != nil {
		return false, err
	}
	if obs >= obsThreshold {
		return true, nil
	}
	runs, err := l.GetRunsSinceAudit()
	if err != nil {
		return false, err
	}
	return runs >= runsThreshold, nil
}

// --- helpers shared with artifacts.go / nonblocking.go ----------------

// insertAfter rewrites the file by inserting the supplied lines
// immediately after the first line that starts with sectionHeader.
// Returns nil if the section is missing — the bash version was silent
// in that case too; the caller's EnsureLog must have run first.
func (l *Log) insertAfter(sectionHeader string, lines []string) error {
	content, err := os.ReadFile(l.Path)
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
	return writeFileAtomic(l.Path, strings.Join(out, "\n"))
}

// parseBulletList walks a multi-line string and extracts each markdown
// bullet as one entry. Continuation lines (non-bullet, non-empty) get
// joined onto the previous bullet with a single space. "None" tokens
// and bare-dash separators are dropped. Mirrors the bash
// _awk_join_bullets helper.
func parseBulletList(raw string) []string {
	var out []string
	var current string
	flush := func() {
		current = strings.TrimSpace(current)
		if current == "" {
			return
		}
		low := strings.ToLower(current)
		if low == "none" {
			current = ""
			return
		}
		if isDashRun(current) {
			current = ""
			return
		}
		out = append(out, current)
		current = ""
	}
	sc := bufio.NewScanner(strings.NewReader(raw))
	bulletRE := regexp.MustCompile(`^[\t ]*-[\t ]*`)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), " \t")
		if line == "" {
			continue
		}
		if m := bulletRE.FindString(line); m != "" {
			flush()
			current = strings.TrimSpace(line[len(m):])
		} else {
			trim := strings.TrimSpace(line)
			if current == "" {
				current = trim
			} else {
				current = current + " " + trim
			}
		}
	}
	flush()
	return out
}

// isDashRun reports whether s is entirely dashes (e.g. "---").
func isDashRun(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r != '-' {
			return false
		}
	}
	return true
}

// stripBracketTag removes the leading "- [tag] " prefix from a drift
// entry, returning the bare observation body. Used by the resolve
// logic when moving entries between sections so the same observation
// body is what gets dedup-compared against existing Resolved entries.
func stripBracketTag(line string) string {
	re := regexp.MustCompile(`^- \[[^\]]*\] `)
	return re.ReplaceAllString(line, "")
}

// collectResolvedBodies returns the stripped-body form of every
// existing Resolved-section entry. Used for dedup.
func collectResolvedBodies(lines []string) []string {
	var out []string
	in := false
	for _, line := range lines {
		if strings.HasPrefix(line, "## Resolved") {
			in = true
			continue
		}
		if in && strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### ") {
			break
		}
		if in && strings.HasPrefix(line, "- ") {
			out = append(out, stripBracketTag(line))
		}
	}
	return out
}

// containsBody reports whether body appears in the existing-resolved
// slice (substring match, mirroring `grep -qF` semantics).
func containsBody(existing []string, body string) bool {
	for _, e := range existing {
		if strings.Contains(e, body) {
			return true
		}
	}
	return false
}

// writeFileAtomic writes content to path via a sibling tmpfile +
// rename, matching the bash mktemp + mv pattern. dir must exist.
func writeFileAtomic(path, content string) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".drift.*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.WriteString(content); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	return nil
}

// ClearResolved empties the ## Resolved section, dropping every bullet
// entry while preserving the heading. Returns the count of cleared
// entries. Bash equivalent: clear_resolved_drift_observations.
func (l *Log) ClearResolved() (int, error) {
	if _, err := os.Stat(l.Path); os.IsNotExist(err) {
		return 0, nil
	} else if err != nil {
		return 0, err
	}
	content, err := os.ReadFile(l.Path)
	if err != nil {
		return 0, err
	}
	lines := strings.Split(string(content), "\n")
	in := false
	cleared := 0
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
		if in && strings.HasPrefix(line, "- ") {
			cleared++
			continue
		}
		out = append(out, line)
	}
	if cleared == 0 {
		return 0, nil
	}
	if err := writeFileAtomic(l.Path, strings.Join(out, "\n")); err != nil {
		return 0, err
	}
	return cleared, nil
}

// GetResolved returns the text of all entries in the Resolved section
// (one per line). Used to include resolved drift items in the commit
// message.
func (l *Log) GetResolved() ([]string, error) {
	content, err := os.ReadFile(l.Path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []string
	in := false
	for _, line := range strings.Split(string(content), "\n") {
		if strings.HasPrefix(line, "## Resolved") {
			in = true
			continue
		}
		if in && strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### ") {
			break
		}
		if in && strings.HasPrefix(line, "- ") {
			out = append(out, line)
		}
	}
	return out, nil
}
