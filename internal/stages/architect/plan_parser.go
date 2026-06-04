// Package architect implements the Tekhton architect pre-stage gate (m36.1
// port). The package mirrors stages/architect.sh — agent dispatch, plan
// parsing, sr/jr remediation routing, post-remediation build + expedited
// review, drift resolution, design-doc observation surfacing, audit-counter
// reset, and plan archival.
package architect

import (
	"bufio"
	"io"
	"regexp"
	"strings"
)

// parsedPlan is the typed result of parsing ARCHITECT_PLAN.md. Each field
// holds the post-multiline-join bullet bodies for the named section. The
// `*Raw` fields hold the pre-filter bodies — callers route through the
// OutOfScope / DesignDocObservations methods to apply the filter chain.
type parsedPlan struct {
	Simplification      []string
	StalenessFixes      []string
	DeadCodeRemoval     []string
	NamingNormalization []string
	OutOfScopeRaw       []string // post-multiline join, pre-filter (bash 295-303)
	DesignDocRaw        []string // post-multiline join, pre-filter (bash 363-377)
}

// HasSimplification mirrors the bash check at architect.sh:131-133. The
// section counts as "present" when at least one non-placeholder bullet is
// recorded.
func (p *parsedPlan) HasSimplification() bool {
	return hasActionableBullets(p.Simplification)
}

// HasJrWork mirrors the bash check at architect.sh:135-144 — fan out over
// the three jr sections and return true if ANY of them has actionable
// content.
func (p *parsedPlan) HasJrWork() bool {
	return hasActionableBullets(p.StalenessFixes) ||
		hasActionableBullets(p.DeadCodeRemoval) ||
		hasActionableBullets(p.NamingNormalization)
}

// OutOfScope returns the OOS items after applying the placeholder filter
// chain from architect.sh:295-303. These items are re-added to the drift
// log after `drift resolve-all` zeroes the unresolved set.
func (p *parsedPlan) OutOfScope() []string {
	return filterEntries(p.OutOfScopeRaw, oosFilters)
}

// DesignDocObservations returns the design-doc items after applying the
// long boilerplate filter chain from architect.sh:363-377. These items
// are surfaced to HUMAN_ACTION_REQUIRED.md via drift.HumanAction.Append.
func (p *parsedPlan) DesignDocObservations() []string {
	return filterEntries(p.DesignDocRaw, designDocFilters)
}

// Section headers we scan for, in canonical case.
var sectionHeaders = map[string]string{
	"simplification":            "Simplification",
	"staleness fixes":           "StalenessFixes",
	"dead code removal":         "DeadCodeRemoval",
	"naming normalization":      "NamingNormalization",
	"out of scope":              "OutOfScope",
	"design doc observations":   "DesignDocObservations",
}

var headerRe = regexp.MustCompile(`^##\s+(.+?)\s*$`)
var bulletRe = regexp.MustCompile(`^[-*][[:space:]]+(.*)$`)

// parsePlan reads an ARCHITECT_PLAN.md document and returns the per-section
// bullet bodies with multi-line bullets joined into a single string. Returns
// an empty parsedPlan + nil error on empty input (matches the bash
// `[ -n "$X" ]` empty-section short-circuit).
func parsePlan(r io.Reader) (parsedPlan, error) {
	var p parsedPlan
	if r == nil {
		return p, nil
	}

	current := ""
	var bullets []string
	var pendingBullet strings.Builder

	flush := func() {
		if pendingBullet.Len() > 0 {
			bullets = append(bullets, pendingBullet.String())
			pendingBullet.Reset()
		}
	}

	assign := func(section string, items []string) {
		switch section {
		case "Simplification":
			p.Simplification = append(p.Simplification, items...)
		case "StalenessFixes":
			p.StalenessFixes = append(p.StalenessFixes, items...)
		case "DeadCodeRemoval":
			p.DeadCodeRemoval = append(p.DeadCodeRemoval, items...)
		case "NamingNormalization":
			p.NamingNormalization = append(p.NamingNormalization, items...)
		case "OutOfScope":
			p.OutOfScopeRaw = append(p.OutOfScopeRaw, items...)
		case "DesignDocObservations":
			p.DesignDocRaw = append(p.DesignDocRaw, items...)
		}
	}

	closeSection := func() {
		flush()
		if current != "" && len(bullets) > 0 {
			assign(current, bullets)
		}
		bullets = nil
	}

	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if m := headerRe.FindStringSubmatch(line); m != nil {
			closeSection()
			heading := strings.ToLower(strings.TrimSpace(m[1]))
			matched := ""
			for key, canonical := range sectionHeaders {
				if strings.Contains(heading, key) {
					matched = canonical
					break
				}
			}
			current = matched
			continue
		}
		if current == "" {
			continue
		}
		trimmed := strings.TrimLeft(line, " \t")
		if trimmed == "" {
			continue
		}
		if bm := bulletRe.FindStringSubmatch(trimmed); bm != nil {
			flush()
			pendingBullet.WriteString(bm[1])
			continue
		}
		// Continuation line — append to current bullet, space-separated.
		if pendingBullet.Len() > 0 {
			pendingBullet.WriteString(" ")
			pendingBullet.WriteString(trimmed)
		} else {
			pendingBullet.WriteString(trimmed)
		}
	}
	closeSection()
	if err := scanner.Err(); err != nil {
		return p, err
	}
	return p, nil
}

// hasActionableBullets mirrors the bash `! echo "$x" | grep -qiE
// '^\s*-?\s*None\s*$'` check — any bullet whose body isn't the lone token
// "None" counts as actionable.
func hasActionableBullets(bullets []string) bool {
	for _, b := range bullets {
		if !nonePlaceholderRe.MatchString(strings.TrimSpace(b)) {
			return true
		}
	}
	return false
}

// nonePlaceholderRe matches bullets whose body is the lone token "None"
// (case-insensitive, with optional leading dash from the bash regex).
var nonePlaceholderRe = regexp.MustCompile(`(?i)^-?\s*None\s*$`)

// filterEntries applies a chain of "exclude" regexes; a bullet is dropped
// when any pattern matches. Mirrors the per-line `grep -qiE '...' && continue`
// chains in the bash source.
func filterEntries(entries []string, patterns []*regexp.Regexp) []string {
	if len(entries) == 0 {
		return nil
	}
	out := make([]string, 0, len(entries))
entries:
	for _, e := range entries {
		body := strings.TrimSpace(e)
		if body == "" {
			continue
		}
		for _, re := range patterns {
			if re.MatchString(body) {
				continue entries
			}
		}
		out = append(out, e)
	}
	return out
}

// oosFilters are the architect.sh:295-303 placeholder patterns for the
// Out of Scope section.
var oosFilters = []*regexp.Regexp{
	regexp.MustCompile(`(?i)^None\b`),
	regexp.MustCompile(`(?i)^N/?A\b`),
	regexp.MustCompile(`(?i)^No (items?|observations?)\b`),
	regexp.MustCompile(`^-+\s*$`),
}

// designDocFilters are the architect.sh:363-377 boilerplate patterns for
// the Design Doc Observations section. Each entry ports one bash
// `grep -qiE '...' && continue` line.
var designDocFilters = []*regexp.Regexp{
	regexp.MustCompile(`(?i)^None\b`),
	regexp.MustCompile(`(?i)^N/?A\b`),
	regexp.MustCompile(`(?i)^No (design|doc|observations?|issues?|action|items?)\b`),
	regexp.MustCompile(`(?i)^(All|No) (drift |design )?(observations?|items?) (are|have been|were)\b`),
	regexp.MustCompile(`(?i)^Nothing (to|requiring|needs)\b`),
	regexp.MustCompile(`^-+\s*$`),
	regexp.MustCompile(`(?i)^\*?\(route to human`),
	regexp.MustCompile(`(?i)(HUMAN_ACTION|action.required|action.items?\.md)`),
	regexp.MustCompile(`(?i)^(Design (doc )?observations?|Items?|Observations?) (have been |were |are |)(documented|recorded|noted|flagged|generated|created|added|updated)`),
	regexp.MustCompile(`(?i)^(Updated|Generated|Created|Documented|Recorded|Flagged|Added|Wrote)\b.*(observations?|action|items?|file|review|human)`),
	regexp.MustCompile(`(?i)(aligns? with|consistent with|no contradictions?|no conflicts?|matches?).*(design|GDD|architecture)`),
	regexp.MustCompile(`(?i)^(See|Refer to) (the )?(design|GDD|architecture)`),
}
