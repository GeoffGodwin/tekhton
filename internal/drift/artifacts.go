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

// adrPreamble is the initial body of ARCHITECTURE_DECISION_LOG.md.
// Mirrors the bash _ensure_adl heredoc.
const adrPreamble = `# Architecture Decision Log

Accepted Architecture Change Proposals are recorded here for institutional memory.
Each entry captures why a structural change was made, preventing future developers
(or agents) from reverting to the old approach without understanding the context.
`

// humanActionPreamble is the initial body of HUMAN_ACTION_REQUIRED.md.
const humanActionPreamble = `# Human Action Required

The pipeline identified items that need your attention. Review each item
and check it off when addressed. The pipeline will display a banner until
all items are resolved.

## Action Items
`

// ADR represents the ARCHITECTURE_DECISION_LOG.md file at a known
// path. Like Log, no in-memory cache — reads/writes hit the file.
type ADR struct {
	Path string
	Now  func() time.Time
}

// NewADR returns an ADR bound to path.
func NewADR(path string) *ADR {
	return &ADR{Path: path, Now: time.Now}
}

// EnsureFile creates the ADR file with the preamble if missing.
func (a *ADR) EnsureFile() error {
	if _, err := os.Stat(a.Path); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(a.Path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(a.Path, []byte(adrPreamble), 0o644)
}

// NextNumber returns the next sequential ADL number by scanning for
// the highest existing `ADL-NNNN` token in the file. Returns 1 when
// the file is missing or no number is found.
//
// Bash equivalent: get_next_adl_number.
func (a *ADR) NextNumber() (int, error) {
	content, err := os.ReadFile(a.Path)
	if os.IsNotExist(err) {
		return 1, nil
	}
	if err != nil {
		return 0, err
	}
	re := regexp.MustCompile(`ADL-(\d+)`)
	max := 0
	for _, m := range re.FindAllStringSubmatch(string(content), -1) {
		var n int
		_, _ = fmt.Sscanf(m[1], "%d", &n)
		if n > max {
			max = n
		}
	}
	return max + 1, nil
}

// AppendDecision appends one ADR entry for each accepted ACP. The
// acpLines slice is the parsed body of the reviewer report's accepted
// ACP section — each line is parsed for the ACP name and rationale.
// task is the user-facing task description recorded with the entry.
func (a *ADR) AppendDecision(task string, acpLines []string) error {
	if len(acpLines) == 0 {
		return nil
	}
	if task == "" {
		task = "unknown"
	}
	if err := a.EnsureFile(); err != nil {
		return err
	}
	date := a.now().Format("2006-01-02")

	f, err := os.OpenFile(a.Path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	w := bufio.NewWriter(f)

	for _, line := range acpLines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		name, rationale := parseACPLine(line)
		n, err := a.NextNumber()
		if err != nil {
			return err
		}
		entry := fmt.Sprintf("\n## ADL-%d: %s (Task: %q)\n- **Date**: %s\n- **Rationale**: %s\n- **Source**: Accepted ACP from pipeline run\n",
			n, name, task, date, rationale)
		if _, err := w.WriteString(entry); err != nil {
			return err
		}
		if err := w.Flush(); err != nil {
			return err
		}
	}
	return nil
}

func (a *ADR) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}

// parseACPLine extracts the ACP name and rationale from a single
// "- ACP: <name> — ACCEPT — <rationale>" line. Mirrors the bash sed
// chain in append_architecture_decision.
func parseACPLine(line string) (name, rationale string) {
	// Strip everything before "ACP: ".
	if i := strings.Index(line, "ACP: "); i >= 0 {
		line = line[i+len("ACP: "):]
	} else {
		// No "ACP: " marker — treat the whole line as the name.
		name = clip(line, 80)
		return name, ""
	}
	if i := strings.Index(line, " — "); i >= 0 {
		name = strings.TrimSpace(line[:i])
		rest := line[i+len(" — "):]
		// rest may be "ACCEPT — <rationale>" — pop the verdict.
		if j := strings.Index(rest, "ACCEPT"); j >= 0 {
			rest = rest[j+len("ACCEPT"):]
			rest = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(rest), "—"))
		}
		rationale = clip(strings.TrimSpace(rest), 200)
		return clip(name, 80), rationale
	}
	return clip(strings.TrimSpace(line), 80), ""
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// HumanAction represents the HUMAN_ACTION_REQUIRED.md file.
type HumanAction struct {
	Path string
	Now  func() time.Time
}

// NewHumanAction returns a HumanAction bound to path.
func NewHumanAction(path string) *HumanAction {
	return &HumanAction{Path: path, Now: time.Now}
}

// EnsureFile creates the file with its preamble when missing.
func (h *HumanAction) EnsureFile() error {
	if _, err := os.Stat(h.Path); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(h.Path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(h.Path, []byte(humanActionPreamble), 0o644)
}

// Append adds one action item with the supplied source label and
// description. Mirrors the bash append_human_action.
func (h *HumanAction) Append(source, description string) error {
	if err := h.EnsureFile(); err != nil {
		return err
	}
	date := h.now().Format("2006-01-02")
	line := fmt.Sprintf("- [ ] [%s | Source: %s] %s\n", date, source, description)
	f, err := os.OpenFile(h.Path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(line)
	return err
}

// CountUnchecked returns the number of unchecked `- [ ]` items in the
// file. Used to drive the banner shown at run start.
func (h *HumanAction) CountUnchecked() (int, error) {
	content, err := os.ReadFile(h.Path)
	if os.IsNotExist(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	count := 0
	for _, line := range strings.Split(string(content), "\n") {
		if strings.HasPrefix(line, "- [ ]") {
			count++
		}
	}
	return count, nil
}

// HasUnchecked is the common "should we show the banner?" predicate.
func (h *HumanAction) HasUnchecked() (bool, error) {
	n, err := h.CountUnchecked()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// ConsolidateLegacyHumanAction merges a stale legacy human-action file
// (legacyPath) into the canonical path the HumanAction is bound to.
// If legacyPath does not exist or equals h.Path, this is a no-op.
// Mirrors the bash consolidate_legacy_human_action helper.
//
// Returns the count of items merged.
func (h *HumanAction) ConsolidateLegacy(legacyPath string) (int, error) {
	if legacyPath == "" || legacyPath == h.Path {
		return 0, nil
	}
	if _, err := os.Stat(legacyPath); os.IsNotExist(err) {
		return 0, nil
	} else if err != nil {
		return 0, err
	}
	if _, err := os.Stat(h.Path); os.IsNotExist(err) {
		// No canonical file — just move legacy into place.
		if err := os.MkdirAll(filepath.Dir(h.Path), 0o755); err != nil {
			return 0, err
		}
		if err := os.Rename(legacyPath, h.Path); err != nil {
			return 0, err
		}
		return 0, nil
	}
	legacyBytes, err := os.ReadFile(legacyPath)
	if err != nil {
		return 0, err
	}
	existingBytes, err := os.ReadFile(h.Path)
	if err != nil {
		return 0, err
	}
	existing := strings.Split(string(existingBytes), "\n")
	existingSet := make(map[string]struct{}, len(existing))
	for _, e := range existing {
		existingSet[e] = struct{}{}
	}
	f, err := os.OpenFile(h.Path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	merged := 0
	for _, line := range strings.Split(string(legacyBytes), "\n") {
		if !strings.HasPrefix(line, "- [ ]") {
			continue
		}
		if _, dup := existingSet[line]; dup {
			continue
		}
		if _, err := f.WriteString(line + "\n"); err != nil {
			return merged, err
		}
		merged++
		existingSet[line] = struct{}{}
	}
	if err := os.Remove(legacyPath); err != nil {
		return merged, err
	}
	return merged, nil
}

func (h *HumanAction) now() time.Time {
	if h.Now != nil {
		return h.Now()
	}
	return time.Now()
}
