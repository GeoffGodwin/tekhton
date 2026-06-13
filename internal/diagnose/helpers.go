// Helpers — pure functions ported from lib/diagnose_helpers.sh.
//
// The bash helpers consume and mutate _DIAG_* module-state globals.
// The Go ports accept their inputs explicitly and either return a value
// (CollapseCauseChain) or read a Context field (DetectRecurring,
// CollectAgentLogTails) — no implicit globals, no engine coupling.

package diagnose

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Helpers groups the three pure helper functions ported from
// lib/diagnose_helpers.sh. The fields are tunable but default to the bash
// constants (5 / 5) so callers can construct a zero-value Helpers and get
// behavior identical to v4.31.x.
type Helpers struct {
	// MaxChainLinks caps CollapseCauseChain output (default 5, matches bash).
	MaxChainLinks int
	// RecurringThreshold is the count at or above which DetectRecurring
	// attaches a Note (default 3, matches bash).
	RecurringThreshold int
}

// DefaultHelpers returns a Helpers populated with the bash defaults.
func DefaultHelpers() *Helpers {
	return &Helpers{MaxChainLinks: 5, RecurringThreshold: 3}
}

// CollapseCauseChain takes the raw cause chain text (space-separated
// "id1 <- id2.type <- id3.type ..." form bash produces via
// cause_chain_summary) and returns the collapsed short form for the
// terminal display.
//
// Bash semantics ported verbatim:
//
//   - Tokens equal to "<-" are separators (skipped).
//   - Each remaining token has the shape "id.type"; the suffix after the
//     final "." is the event type. A token with no "." has type "event".
//   - Consecutive tokens of the same type are grouped as "Nx <type>".
//   - The result is truncated to MaxChainLinks links joined with " -> ".
//   - When the chain has more than MaxChainLinks links, " -> ... (N total)"
//     is appended where N is the full pre-truncation link count.
func (h *Helpers) CollapseCauseChain(raw string) string {
	max := h.MaxChainLinks
	if max <= 0 {
		max = 5
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}

	parts := strings.Fields(raw)
	var links []string
	prevType := ""
	typeCount := 0
	for _, part := range parts {
		if part == "<-" {
			continue
		}
		var etype string
		if idx := strings.LastIndex(part, "."); idx >= 0 {
			etype = part[idx+1:]
		} else {
			etype = "event"
		}

		if etype == prevType {
			typeCount++
		} else {
			if prevType != "" && typeCount > 1 {
				links[len(links)-1] = fmt.Sprintf("%dx %s", typeCount, prevType)
			}
			links = append(links, etype)
			prevType = etype
			typeCount = 1
		}
	}
	// Final group.
	if typeCount > 1 && len(links) > 0 {
		links[len(links)-1] = fmt.Sprintf("%dx %s", typeCount, prevType)
	}

	if len(links) == 0 {
		return ""
	}

	count := max
	if len(links) < count {
		count = len(links)
	}
	result := strings.Join(links[:count], " -> ")
	if len(links) > max {
		result += fmt.Sprintf(" -> ... (%d total)", len(links))
	}
	return result
}

// recurringClassificationFile reads "classification" and "consecutive_count"
// from a LAST_FAILURE_CONTEXT.json file via line scan. Mirrors the bash
// grep -oP fallback in _detect_recurring_failures.
var (
	classificationRe     = regexp.MustCompile(`"classification"\s*:\s*"([^"]+)"`)
	consecutiveCountRe   = regexp.MustCompile(`"consecutive_count"\s*:\s*(\d+)`)
	numericOnlyDigitsRe  = regexp.MustCompile(`\d+`)
	logFileBasenameRe    = regexp.MustCompile(`\.log$`)
	agentLogTailMaxLines = 20
)

// DetectRecurring counts how many runs in a row produced the same
// Classification. Mirrors _detect_recurring_failures fallback path
// (the bash primary path uses recurring_pattern() from causality.sh; the
// adapter-mode m32.1 engine emits causal-log events through the Context's
// CausalEvents field so a future Go-native recurrence helper can be added
// without changing this signature).
//
// Returns an empty RecurringInfo when:
//   - classification is empty (engine should still call DetectRecurring
//     after every match for parity with bash);
//   - LAST_FAILURE_CONTEXT.json does not exist or does not contain the
//     same classification as the current verdict.
//
// When the same classification appears in LAST_FAILURE_CONTEXT.json with
// consecutive_count = N, the return is RecurringInfo{Count: N + 1, Note: ...}
// where Note is populated only when Count >= RecurringThreshold.
func (h *Helpers) DetectRecurring(c *Context, classification string) RecurringInfo {
	if c == nil || classification == "" {
		return RecurringInfo{}
	}
	threshold := h.RecurringThreshold
	if threshold <= 0 {
		threshold = 3
	}

	failureCtx := filepath.Join(projectOrDot(c.ProjectDir), ".claude", "LAST_FAILURE_CONTEXT.json")
	body, err := os.ReadFile(failureCtx)
	if err != nil {
		return RecurringInfo{}
	}
	text := string(body)
	matchClass := classificationRe.FindStringSubmatch(text)
	if len(matchClass) < 2 || matchClass[1] != classification {
		return RecurringInfo{}
	}

	prev := 0
	matchCount := consecutiveCountRe.FindStringSubmatch(text)
	if len(matchCount) >= 2 {
		// Strip any non-digit just like the bash `${prev_count//[!0-9]/}`
		// even though the regex already constrained to \d+.
		digits := numericOnlyDigitsRe.FindString(matchCount[1])
		if digits != "" {
			if n, err := strconv.Atoi(digits); err == nil {
				prev = n
			}
		}
	}

	count := prev + 1
	out := RecurringInfo{Count: count}
	if count >= threshold {
		out.Note = fmt.Sprintf(
			"This is the %dth consecutive %s — consider manual intervention.",
			count, classification,
		)
	}
	return out
}

// CollectAgentLogTails reads the last ~20 lines of each agent log under
// ${PROJECT_DIR}/.claude/logs/*.log. Mirrors _collect_agent_log_tails:
//   - non-recursive (maxdepth 1 in bash);
//   - capped at 5 files (bash `head -5`);
//   - each entry keyed by basename; value is the joined tail content.
//
// The Go port sorts files by name so its output is deterministic; bash
// uses `find` which depends on filesystem iteration order — the parity
// gate's normalize step strips that ordering, so the deterministic Go
// ordering does not break byte-identical assertions.
func (h *Helpers) CollectAgentLogTails(c *Context) map[string]string {
	out := map[string]string{}
	if c == nil {
		return out
	}
	logDir := filepath.Join(projectOrDot(c.ProjectDir), ".claude", "logs")
	st, err := os.Stat(logDir)
	if err != nil || !st.IsDir() {
		return out
	}
	entries, err := os.ReadDir(logDir)
	if err != nil {
		return out
	}
	var logs []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if !logFileBasenameRe.MatchString(e.Name()) {
			continue
		}
		logs = append(logs, e.Name())
	}
	sort.Strings(logs)
	if len(logs) > 5 {
		logs = logs[:5]
	}

	for _, name := range logs {
		body, err := os.ReadFile(filepath.Join(logDir, name))
		if err != nil {
			continue
		}
		out[name] = tailLines(string(body), agentLogTailMaxLines)
	}
	return out
}

// projectOrDot mirrors the bash `${PROJECT_DIR:-.}` default.
func projectOrDot(p string) string {
	if p == "" {
		return "."
	}
	return p
}

// tailLines returns the last n newline-delimited lines of body, preserving
// the trailing newline shape bash `tail -n` produces.
func tailLines(body string, n int) string {
	if body == "" || n <= 0 {
		return ""
	}
	// Drop the trailing newline so the split count matches `tail -n N`
	// behavior (which treats a missing trailing newline as still being
	// the final line).
	trimmed := strings.TrimRight(body, "\n")
	lines := strings.Split(trimmed, "\n")
	if len(lines) <= n {
		return strings.Join(lines, "\n")
	}
	return strings.Join(lines[len(lines)-n:], "\n")
}
