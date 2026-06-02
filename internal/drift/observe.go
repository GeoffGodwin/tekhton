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
		lines = append(lines, fmt.Sprintf(`- [ ] [%s | "%s"] %s`, date, task, e))
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
		lines = append(lines, fmt.Sprintf(`- [ ] [%s | "architect audit"] %s`, date, e))
	}
	return l.insertAfter("## Unresolved Observations", lines)
}

// CountUnresolved returns the number of unresolved observation entries.
// Counts both new-format `- [ ] [date | "task"] body` entries and the
// legacy pre-checkbox `- [date | "task"] body` form (entries that pre-
// date the checkbox parity change land as "unresolved" until the next
// agent-or-heuristic resolution pass ticks them). Explicitly excludes
// `- [x]` (ticked, not yet swept) and `- [RESOLVED ...]` (legacy resolved
// markers) so a half-resolved file doesn't double-count.
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
		if inSection && isUnresolvedEntry(line) {
			count++
		}
	}
	return count, nil
}

// isUnresolvedEntry returns true when line is a markdown bullet that
// represents an unresolved drift observation. Recognizes both the new
// `- [ ]` checkbox form and the legacy `- [date | "task"]` form, while
// excluding `- [x]` (ticked) and `- [RESOLVED ...]` (legacy resolved).
func isUnresolvedEntry(line string) bool {
	if !strings.HasPrefix(line, "- [") {
		return false
	}
	// New-format unresolved: "- [ ] ..."
	if strings.HasPrefix(line, "- [ ]") {
		return true
	}
	// Ticked-but-not-yet-swept: skip ("- [x] ...")
	if strings.HasPrefix(line, "- [x]") {
		return false
	}
	// Legacy resolved marker: skip ("- [RESOLVED ...]")
	if strings.HasPrefix(line, "- [RESOLVED") {
		return false
	}
	// Anything else with `- [` prefix is legacy unresolved
	// (e.g. "- [2026-06-01 | \"task\"] body").
	return true
}

// isTickedEntry returns true when line is a markdown bullet with the
// `[x]` ticked marker. Used by MoveTickedToResolved to find entries
// to sweep.
func isTickedEntry(line string) bool {
	return strings.HasPrefix(line, "- [x]")
}

// ResolveObservations ticks every unresolved entry whose body matches
// any of the supplied substring patterns by flipping its `[ ]` marker
// to `[x]` in place. The sweep into the Resolved section happens
// separately via MoveTickedToResolved (called by the finalize hook).
// Legacy entries without a `[ ]` prefix get one inserted at tick time
// so the new-format invariant holds for everything from this point
// forward.
func (l *Log) ResolveObservations(patterns []string) (int, error) {
	if len(patterns) == 0 {
		return 0, nil
	}
	if _, err := os.Stat(l.Path); os.IsNotExist(err) {
		return 0, nil
	} else if err != nil {
		return 0, err
	}
	matcher := func(body string) bool {
		for _, p := range patterns {
			if p == "" {
				continue
			}
			if matched, _ := regexp.MatchString(p, body); matched {
				return true
			}
		}
		return false
	}
	return l.tickObservations(matcher)
}

// ResolveAllObservations ticks every unresolved entry to `[x]`.
// Used by the architect audit when every observation has been
// reviewed. The subsequent finalize sweep moves the ticked entries
// into the Resolved section — the architect doesn't need to do that
// work itself.
func (l *Log) ResolveAllObservations() error {
	if _, err := os.Stat(l.Path); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	_, err := l.tickObservations(func(string) bool { return true })
	return err
}

// ResolveByModifiedFiles is the heuristic that ticks `[x]` on any open
// drift observation whose body mentions a file in modifiedFiles.
// Mirrors NonBlocking.ResolveByModifiedFiles. Returns the count of
// observations transitioned.
func (l *Log) ResolveByModifiedFiles(modifiedFiles []string) (int, error) {
	if len(modifiedFiles) == 0 {
		return 0, nil
	}
	if _, err := os.Stat(l.Path); os.IsNotExist(err) {
		return 0, nil
	} else if err != nil {
		return 0, err
	}
	// Build basenames for substring matching. The bash convention
	// looks for full path mentions but the observation bodies often
	// only reference the basename or short relative path; matching
	// on basename is the most forgiving heuristic.
	basenames := make([]string, 0, len(modifiedFiles))
	for _, f := range modifiedFiles {
		f = strings.TrimSpace(f)
		if f == "" {
			continue
		}
		basenames = append(basenames, f)
		if b := lastSegment(f); b != "" && b != f {
			basenames = append(basenames, b)
		}
	}
	matcher := func(body string) bool {
		for _, name := range basenames {
			if strings.Contains(body, name) {
				return true
			}
		}
		return false
	}
	return l.tickObservations(matcher)
}

// MoveTickedToResolved moves every `- [x] ...` entry out of the
// Unresolved Observations section and into the Resolved section,
// preserving the body verbatim. Dedups against existing resolved
// bodies. Returns the count of entries moved.
func (l *Log) MoveTickedToResolved() (int, error) {
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
	existing := collectResolvedBodies(lines)

	var out []string
	var newlyResolved []string
	inUnresolved := false
	moved := 0
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
		case inUnresolved && isTickedEntry(line):
			body := strings.TrimSpace(strings.TrimPrefix(line, "- [x]"))
			if !containsBody(existing, body) {
				newlyResolved = append(newlyResolved, line)
				existing = append(existing, body)
			}
			moved++
		default:
			out = append(out, line)
		}
	}
	if moved == 0 {
		return 0, nil
	}
	return moved, writeFileAtomic(l.Path, strings.Join(out, "\n"))
}

// tickObservations is the shared implementation for the three
// resolution entry points (ResolveObservations, ResolveAllObservations,
// ResolveByModifiedFiles). For every unresolved entry where match(body)
// returns true, the line gets a `[x]` marker. Legacy entries without
// any checkbox marker get `[x]` inserted; new-format `[ ]` entries get
// the `[ ]` flipped to `[x]`. Returns the count of entries ticked.
func (l *Log) tickObservations(match func(body string) bool) (int, error) {
	content, err := os.ReadFile(l.Path)
	if err != nil {
		return 0, err
	}
	lines := strings.Split(string(content), "\n")
	inUnresolved := false
	ticked := 0
	for i, line := range lines {
		switch {
		case strings.HasPrefix(line, "## Unresolved Observations"):
			inUnresolved = true
		case strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### "):
			inUnresolved = false
		case inUnresolved && isUnresolvedEntry(line):
			// Body for matching purposes: strip the leading `- [ ] `
			// or `- [date | "task"] ` so the heuristic is matching
			// the human text, not the metadata.
			body := unresolvedBody(line)
			if !match(body) {
				continue
			}
			lines[i] = tickLine(line)
			ticked++
		}
	}
	if ticked == 0 {
		return 0, nil
	}
	return ticked, writeFileAtomic(l.Path, strings.Join(lines, "\n"))
}

// unresolvedBody extracts the human-text body from an unresolved
// drift-log line for matching purposes. Strips the leading bullet,
// the `[ ]` (or legacy `[date | "task"]`) tag, and surrounding
// whitespace.
func unresolvedBody(line string) string {
	if strings.HasPrefix(line, "- [ ]") {
		rest := strings.TrimSpace(strings.TrimPrefix(line, "- [ ]"))
		// New format may still carry a legacy-style `[date | "task"]`
		// tag after the checkbox. Strip it so the body for matching
		// is just the human text.
		return stripBracketTag(rest)
	}
	// Legacy form: "- [date | \"task\"] body" — stripBracketTag drops
	// the leading `- [...] ` tag and returns the body.
	return stripBracketTag(line)
}

// tickLine produces the `[x]` form of an unresolved drift-log line.
// `- [ ] foo`        → `- [x] foo`
// `- [date|...] foo` → `- [x] [date|...] foo`
func tickLine(line string) string {
	if strings.HasPrefix(line, "- [ ]") {
		return "- [x]" + strings.TrimPrefix(line, "- [ ]")
	}
	// Legacy entry: prepend `- [x] ` before the existing `[date|...]`
	// tag. The tag-and-body remain intact so the entry is still
	// machine-parseable.
	rest := strings.TrimPrefix(line, "- ")
	return "- [x] " + rest
}

// lastSegment returns the last `/`-delimited segment of path, or
// path itself when there's no separator. Used to derive a basename
// when the caller passes a full relative path.
func lastSegment(path string) string {
	if i := strings.LastIndex(path, "/"); i >= 0 {
		return path[i+1:]
	}
	return path
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
