// Package intake ports the intake-stage helpers from lib/intake_helpers.sh
// and lib/intake_verdict_handlers.sh. The Helpers struct exposes the
// content-hash / report-parse / tweak-application / PM-metadata functions
// that stages/intake.sh consumes; the VerdictHandler routes TWEAKED,
// SPLIT_RECOMMENDED, and NEEDS_CLARITY verdicts.
//
// m36.2 lands the helpers and the verdict handler; the bash stage continues
// to call into them via the transition Cobra shim `tekhton intake ...`.
// m36.3 deletes the shim subcommands together with stages/intake.sh.
package intake

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Helpers carries the per-call dependencies the intake helpers need. The
// fields replace the bash-era env-var soup with explicit values — every
// CLI subcommand and the eventual in-process M36.3 caller constructs one.
type Helpers struct {
	ProjectDir         string // typically the pipeline-run CWD
	SessionDir         string // typically .tekhton/session/<TIMESTAMP>
	MilestoneDir       string // typically .claude/milestones
	ProjectRulesFile   string // typically CLAUDE.md (inline-mode fallback)
	ClarificationsFile string // typically .tekhton/CLARIFICATIONS.md
	DagEnabled         bool   // MILESTONE_DAG_ENABLED
	// MilestoneFileResolver is an optional escape hatch for DAG-mode lookups
	// when the manifest is not on disk. When nil, MilestoneContent falls back
	// to the inline-mode CLAUDE.md scan. The bash equivalent shelled out to
	// dag_get_file; the Go port leaves the seam open for the M36.3 in-process
	// integration with internal/manifest.
	MilestoneFileResolver func(num string) string
}

// ErrTweakRejected signals that ApplyTweakMilestone refused to overwrite the
// milestone file because the tweaked content fell below the configured size
// floor. The original file is untouched; the rejected tweak is written under
// <SessionDir>/REJECTED_TWEAK.md for the operator to inspect.
var ErrTweakRejected = errors.New("intake: tweak rejected — size below minimum")

// ContentHash returns SHA-256 of content as lowercase hex. Matches the bash
// `printf '%s' "$content" | sha256sum | cut -d' ' -f1`.
func (h *Helpers) ContentHash(content string) string {
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}

// ShouldSkip returns true when <SessionDir>/intake_content_hash exists and its
// content equals hash. Mirrors bash _intake_should_skip — missing session dir
// or missing file → false (do not skip).
func (h *Helpers) ShouldSkip(hash string) bool {
	if h.SessionDir == "" {
		return false
	}
	data, err := os.ReadFile(filepath.Join(h.SessionDir, "intake_content_hash"))
	if err != nil {
		return false
	}
	return strings.TrimRight(string(data), "\n") == hash
}

// SaveHash writes hash to <SessionDir>/intake_content_hash with a trailing
// newline (matches bash `echo "$hash" >`).
func (h *Helpers) SaveHash(hash string) error {
	if h.SessionDir == "" {
		return errors.New("intake: SessionDir not configured")
	}
	if err := os.MkdirAll(h.SessionDir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(h.SessionDir, "intake_content_hash"), []byte(hash+"\n"), 0o644)
}

// allowedVerdicts mirrors the bash case statement at intake_helpers.sh:55-58.
var allowedVerdicts = map[string]struct{}{
	"PASS":              {},
	"TWEAKED":           {},
	"SPLIT_RECOMMENDED": {},
	"NEEDS_CLARITY":     {},
}

// ParseVerdict reads the report file and returns one of PASS / TWEAKED /
// SPLIT_RECOMMENDED / NEEDS_CLARITY. Anything else (missing file, garbage
// value, empty section) falls back to PASS — matches bash semantics.
func (h *Helpers) ParseVerdict(reportPath string) string {
	body, err := os.ReadFile(reportPath)
	if err != nil {
		return "PASS"
	}
	v := scanSectionFirstNonEmpty(string(body), "## Verdict")
	// Bash normalizes via `tr '[:lower:]' '[:upper:]' | tr -d '[:space:]'`.
	v = strings.ToUpper(strings.Map(stripSpace, v))
	if _, ok := allowedVerdicts[v]; ok {
		return v
	}
	return "PASS"
}

// ParseConfidence reads the report file and returns an int in 0..100.
// Falls back to 100 if the section is missing or unparsable.
func (h *Helpers) ParseConfidence(reportPath string) int {
	body, err := os.ReadFile(reportPath)
	if err != nil {
		return 100
	}
	raw := scanSectionFirstNonEmpty(string(body), "## Confidence")
	// Bash `gsub(/[^0-9]/, "")`.
	digits := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, raw)
	if digits == "" {
		return 100
	}
	n := 0
	for _, r := range digits {
		n = n*10 + int(r-'0')
		if n > 100 {
			return 100
		}
	}
	return n
}

// stopSectionPatterns enumerates the section headings that terminate the
// "## Tweaked Content" or "## Questions" body parses. Mirrors the bash
// awk patterns at intake_helpers.sh:84 and :93.
var (
	tweaksStopHeadings    = []string{"## Verdict", "## Confidence", "## Reasoning", "## Split Recommendations", "## Questions"}
	questionsStopHeadings = []string{"## Verdict", "## Confidence", "## Reasoning", "## Tweaked Content", "## Split Recommendations"}
)

// ParseTweaks extracts the body between "## Tweaked Content" and the next
// recognized section heading. Returns "" when the file or section is absent.
func (h *Helpers) ParseTweaks(reportPath string) string {
	body, err := os.ReadFile(reportPath)
	if err != nil {
		return ""
	}
	return extractSection(string(body), "## Tweaked Content", tweaksStopHeadings)
}

// ParseQuestions extracts the body between "## Questions" and the next
// recognized section heading. Returns "" when the file or section is absent.
func (h *Helpers) ParseQuestions(reportPath string) string {
	body, err := os.ReadFile(reportPath)
	if err != nil {
		return ""
	}
	return extractSection(string(body), "## Questions", questionsStopHeadings)
}

// MilestoneContent returns the milestone file body (DAG or inline), or the
// task string when milestoneMode is false. Mirrors the bash helper.
func (h *Helpers) MilestoneContent(milestoneMode bool, currentMs, task string) (string, error) {
	if !milestoneMode || currentMs == "" {
		return task, nil
	}
	// DAG mode: try <MilestoneDir>/<id>.md first, then the optional resolver.
	if h.DagEnabled {
		if h.MilestoneDir != "" {
			// The bash helper passes `_CURRENT_MILESTONE` straight through to
			// dag_number_to_id. The Go shim does the same — callers can
			// supply either an id or a number; resolver bridges the gap.
			candidate := filepath.Join(h.MilestoneDir, currentMs+".md")
			if data, err := os.ReadFile(candidate); err == nil {
				return string(data), nil
			}
			if h.MilestoneFileResolver != nil {
				if name := h.MilestoneFileResolver(currentMs); name != "" {
					p := filepath.Join(h.MilestoneDir, name)
					if data, err := os.ReadFile(p); err == nil {
						return string(data), nil
					}
				}
			}
		}
	}
	// Inline mode: scan CLAUDE.md for the matching milestone heading.
	if h.ProjectRulesFile == "" {
		return "", nil
	}
	body, err := os.ReadFile(h.ProjectRulesFile)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	return extractInlineMilestoneBlock(string(body), currentMs), nil
}

// ApplyTweakMilestone overwrites the milestone file for msNum with
// tweakedContent. Three guards in order:
//
//   - Size guard: when the original is more than 20 lines and the tweaked
//     line count is below minPct% of the original line count, reject by
//     writing <SessionDir>/REJECTED_TWEAK.md and returning ErrTweakRejected.
//   - Backup: cp the original to <msFile>.pre-tweak before overwrite.
//   - Atomic: write to a tmpfile inside MilestoneDir, then os.Rename.
//
// On success, calls AddPMMetadata to stamp the PM-tweaked comment.
func (h *Helpers) ApplyTweakMilestone(tweakedContent, msNum string, minPct int) error {
	if strings.TrimSpace(tweakedContent) == "" {
		return errors.New("intake: no tweaked content to apply")
	}
	if h.MilestoneDir == "" {
		return errors.New("intake: MilestoneDir not configured")
	}
	msFile := filepath.Join(h.MilestoneDir, msNum+".md")
	if _, err := os.Stat(msFile); os.IsNotExist(err) {
		if h.MilestoneFileResolver != nil {
			if name := h.MilestoneFileResolver(msNum); name != "" {
				msFile = filepath.Join(h.MilestoneDir, name)
			}
		}
	}
	orig, err := os.ReadFile(msFile)
	if err != nil {
		return fmt.Errorf("intake: could not locate milestone file for %s: %w", msNum, err)
	}

	origLines := countLines(orig)
	// Bash uses `printf '%s\n' "$tweaked_content" | wc -l` — the trailing
	// newline guarantees at least one line. Mirror by writing the same
	// suffix before counting.
	tweakedWithNL := ensureTrailingNL(tweakedContent)
	tweakedLines := countLines([]byte(tweakedWithNL))
	if origLines > 20 && tweakedLines > 0 {
		pct := (tweakedLines * 100) / origLines
		if pct < minPct {
			// Save rejected tweak for operator review.
			if h.SessionDir != "" {
				_ = os.MkdirAll(h.SessionDir, 0o755)
				_ = os.WriteFile(filepath.Join(h.SessionDir, "REJECTED_TWEAK.md"),
					[]byte(tweakedWithNL), 0o644)
			}
			return ErrTweakRejected
		}
	}

	// Backup before overwriting.
	backupPath := msFile + ".pre-tweak"
	if err := os.WriteFile(backupPath, orig, 0o644); err != nil {
		return fmt.Errorf("intake: backup write: %w", err)
	}

	// Atomic tmpfile + rename inside MilestoneDir so the rename stays on the
	// same filesystem (matches bash `mktemp "${MILESTONE_DIR}/intake_tweak.XXXXXX"`).
	tmp, err := os.CreateTemp(h.MilestoneDir, "intake_tweak.*")
	if err != nil {
		return fmt.Errorf("intake: tmpfile: %w", err)
	}
	tmpPath := tmp.Name()
	if _, err := tmp.WriteString(tweakedWithNL); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return err
	}
	if err := os.Rename(tmpPath, msFile); err != nil {
		os.Remove(tmpPath)
		return err
	}
	// Stamp PM metadata.
	return h.AddPMMetadata(msFile)
}

// ApplyTweakTask replaces the active task with the first non-empty line of
// tweakedContent and persists it to <SessionDir>/INTAKE_TWEAKED_TASK.md so
// a resume can recover it. Returns the new task string.
func (h *Helpers) ApplyTweakTask(tweakedContent string) (string, error) {
	if strings.TrimSpace(tweakedContent) == "" {
		return "", errors.New("intake: no tweaked content to apply")
	}
	var newTask string
	sc := bufio.NewScanner(strings.NewReader(tweakedContent))
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			continue
		}
		newTask = line
		break
	}
	if newTask == "" {
		return "", nil
	}
	if h.SessionDir != "" {
		if err := os.MkdirAll(h.SessionDir, 0o755); err != nil {
			return "", err
		}
		if err := os.WriteFile(filepath.Join(h.SessionDir, "INTAKE_TWEAKED_TASK.md"),
			[]byte(newTask+"\n"), 0o644); err != nil {
			return "", err
		}
	}
	return newTask, nil
}

// pmDateRE matches the existing `<!-- PM-tweaked: YYYY-MM-DD -->` comment so
// AddPMMetadata can refresh it in-place.
var pmDateRE = regexp.MustCompile(`<!-- PM-tweaked: [0-9-]* -->`)

// AddPMMetadata inserts or updates the `<!-- PM-tweaked: YYYY-MM-DD -->`
// comment in msFile. Atomic via tmpfile + os.Rename.
//
// Insertion rules mirror bash _intake_add_pm_metadata:
//
//   - Existing comment → replace YYYY-MM-DD in place.
//   - Milestone-meta block present → insert immediately after the line
//     that ends the block (the bash `sed "/^-->/a ..."`).
//   - No meta block → insert directly after the first line.
//
// Today is supplied by the package-level dateProvider so tests can pin it.
func (h *Helpers) AddPMMetadata(msFile string) error {
	body, err := os.ReadFile(msFile)
	if err != nil {
		return err
	}
	dateStr := dateProvider()
	text := string(body)
	hadTrailingNL := strings.HasSuffix(text, "\n")
	if pmDateRE.MatchString(text) {
		text = pmDateRE.ReplaceAllString(text,
			fmt.Sprintf("<!-- PM-tweaked: %s -->", dateStr))
	} else if strings.Contains(text, "milestone-meta") {
		text = insertAfterMetaBlock(text, dateStr)
	} else {
		text = insertAfterFirstLine(text, dateStr)
	}
	if hadTrailingNL && !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	return atomicWrite(msFile, []byte(text))
}

// --- helpers (file-local) ----------------------------------------------------

// scanSectionFirstNonEmpty mirrors bash `awk '/^## H/{getline; gsub; print; exit}'`
// — but returns "" instead of the literal blank line if the line after the
// heading is empty. The bash version's `print` always prints the immediate
// next line regardless of content; the Go port keeps that semantic.
func scanSectionFirstNonEmpty(body, heading string) string {
	sc := bufio.NewScanner(strings.NewReader(body))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		if strings.HasPrefix(sc.Text(), heading) {
			if sc.Scan() {
				return strings.TrimSpace(sc.Text())
			}
			return ""
		}
	}
	return ""
}

// extractSection returns the block of lines between the start heading and the
// first heading in stopHeadings (or EOF). The start line is excluded; the stop
// line is excluded. Mirrors bash awk: starts after `## H`, terminates before
// any `## (X|Y|Z)`, prints everything else.
func extractSection(body, start string, stops []string) string {
	var buf strings.Builder
	in := false
	sc := bufio.NewScanner(strings.NewReader(body))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if !in {
			if strings.HasPrefix(line, start) {
				in = true
			}
			continue
		}
		for _, stop := range stops {
			if strings.HasPrefix(line, stop) {
				return strings.TrimRight(buf.String(), "\n")
			}
		}
		buf.WriteString(line)
		buf.WriteByte('\n')
	}
	return strings.TrimRight(buf.String(), "\n")
}

// inlineMilestoneRE matches headings of the form `## Milestone 12` or
// `### milestone 3.2`. The bash awk variant matches `#{1,5}[[:space:]]+(M|m)ilestone[[:space:]]+`.
var inlineMilestoneRE = regexp.MustCompile(`^#{1,5}\s+[Mm]ilestone\s+([0-9]+(?:\.[0-9]+)*)`)
var inlineHeadingRE = regexp.MustCompile(`^#{1,5}\s`)

// extractInlineMilestoneBlock returns the block under a "# Milestone <num>"
// heading, stopping at the next H1-H5 heading. Matches bash awk at
// intake_helpers.sh:221-228.
func extractInlineMilestoneBlock(claudeMD, num string) string {
	var buf strings.Builder
	in := false
	sc := bufio.NewScanner(strings.NewReader(claudeMD))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if !in {
			m := inlineMilestoneRE.FindStringSubmatch(line)
			if m != nil && m[1] == num {
				in = true
				buf.WriteString(line)
				buf.WriteByte('\n')
			}
			continue
		}
		if inlineHeadingRE.MatchString(line) {
			break
		}
		buf.WriteString(line)
		buf.WriteByte('\n')
	}
	return strings.TrimRight(buf.String(), "\n")
}

func insertAfterMetaBlock(body, dateStr string) string {
	lines := strings.Split(body, "\n")
	out := make([]string, 0, len(lines)+1)
	inserted := false
	for _, line := range lines {
		out = append(out, line)
		if !inserted && line == "-->" {
			out = append(out, fmt.Sprintf("<!-- PM-tweaked: %s -->", dateStr))
			inserted = true
		}
	}
	if !inserted {
		// Fall back to first-line insertion if no terminator was found.
		return insertAfterFirstLine(body, dateStr)
	}
	return strings.Join(out, "\n")
}

func insertAfterFirstLine(body, dateStr string) string {
	idx := strings.Index(body, "\n")
	if idx < 0 {
		return body + "\n<!-- PM-tweaked: " + dateStr + " -->"
	}
	return body[:idx+1] + "<!-- PM-tweaked: " + dateStr + " -->\n" + body[idx+1:]
}

func atomicWrite(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".intake.*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, path)
}

func stripSpace(r rune) rune {
	switch r {
	case ' ', '\t', '\n', '\r':
		return -1
	}
	return r
}

func countLines(b []byte) int {
	if len(b) == 0 {
		return 0
	}
	// Bash `wc -l` counts newline-terminated lines. Match that exactly so
	// the size-guard math agrees with the bash version.
	n := 0
	for _, c := range b {
		if c == '\n' {
			n++
		}
	}
	return n
}

func ensureTrailingNL(s string) string {
	if strings.HasSuffix(s, "\n") {
		return s
	}
	return s + "\n"
}

// dateProvider returns YYYY-MM-DD for AddPMMetadata. Defaults to
// time.Now().Format; tests override it to pin the date.
var dateProvider = defaultDateProvider
