package errors

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Routing tokens. The four-token vocabulary is the cross-milestone contract
// M128's build-fix continuation loop and M130's recovery dispatch consume.
// Do not extend without coordinating with both downstream consumers.
const (
	RouteCodeDominant    = "code_dominant"
	RouteNoncodeDominant = "noncode_dominant"
	RouteMixedUncertain  = "mixed_uncertain"
	RouteUnknownOnly     = "unknown_only"
)

// NoncodeConfidenceThreshold is the percentage of total lines that must match
// non-code patterns before classifyRoutingDecision routes a code-free log to
// noncode_dominant. Below this, we fall through to unknown_only so the build-
// fix loop still gets a chance to run with low-confidence guidance.
const NoncodeConfidenceThreshold = 60

// Failure-term allow-list: lines containing any of these terms are always
// treated as diagnostic, regardless of denylist matches. Keep narrow — adding
// common words inflates the noncode signal and breaks routing.
var failureTermRE = regexp.MustCompile(`(?i)error|failed|timeout|ECONNREFUSED|TS[0-9]+`)

// Patterns whose lines should be excluded from classification statistics
// UNLESS the line also contains a failure term (allow-list precedence).
var noiseLineREs = []*regexp.Regexp{
	regexp.MustCompile(`(?i)^[[:space:]]*npm[[:space:]]+warn`),
	regexp.MustCompile(`(?i)^[[:space:]]*npm[[:space:]]+notice`),
	regexp.MustCompile(`(?i)^[[:space:]]*pnpm[[:space:]]+warn`),
	regexp.MustCompile(`(?i)^[[:space:]]*pnpm[[:space:]]+notice`),
	regexp.MustCompile(`(?i)^[[:space:]]*yarn[[:space:]]+warn`),
	regexp.MustCompile(`(?i)^[[:space:]]*yarn[[:space:]]+notice`),
	regexp.MustCompile(`^[[:space:]]*\[[0-9]+/[0-9]+\]`),
	regexp.MustCompile(`^[[:space:]]*[0-9]+%[[:space:]]`),
	regexp.MustCompile(`(?i)serving html report at`),
	regexp.MustCompile(`(?i)press[[:space:]]+ctrl[+-]?c[[:space:]]+to[[:space:]]+quit`),
	regexp.MustCompile(`(?i)audit[[:space:]]+hint`),
	regexp.MustCompile(`^[[:space:]]*\([0-9]+/[0-9]+\)`),
	regexp.MustCompile(`(?i)progress:[[:space:]]*[0-9]+%`),
	regexp.MustCompile(`(?i)reporter:[[:space:]]+`),
}

// ansiCSI matches the CSI portion of ANSI escape sequences so we can detect
// "ANSI-only" lines after stripping.
var ansiCSI = regexp.MustCompile("\x1b\\[[0-9;]*[a-zA-Z]")

// IsNonDiagnosticLine reports whether the given line should be excluded from
// classification statistics. Allow-list (failure terms) runs before deny-list
// so a "[1/8] timeout" or "npm warn TS2304: ..." line is never silently
// dropped. Pure whitespace and ANSI-only lines are noise.
func IsNonDiagnosticLine(line string) bool {
	if strings.TrimSpace(line) == "" {
		return true
	}
	if failureTermRE.MatchString(line) {
		return false
	}
	stripped := ansiCSI.ReplaceAllString(line, "")
	if strings.TrimSpace(stripped) == "" {
		return true
	}
	for _, re := range noiseLineREs {
		if re.MatchString(line) {
			return true
		}
	}
	return false
}

// matchPattern scans the registry for the first pattern that matches line.
// Returns the match index (-1 when none).
func matchPattern(line string) int {
	for i, p := range Patterns() {
		if p.Regex.MatchString(line) {
			return i
		}
	}
	return -1
}

// HasExplicitCodeErrors returns true only when at least one diagnostic line
// matched an explicit code-category pattern. Unmatched/unknown lines do NOT
// count as code evidence — that is the M127 fix.
func HasExplicitCodeErrors(raw string) bool {
	if raw == "" {
		return false
	}
	for _, line := range strings.Split(raw, "\n") {
		if line == "" || IsNonDiagnosticLine(line) {
			continue
		}
		if i := matchPattern(line); i >= 0 && Patterns()[i].Category == "code" {
			return true
		}
	}
	return false
}

// HasOnlyNoncodeErrors mirrors the legacy bypass predicate
// has_only_noncode_errors. Returns true when the raw output contains at least
// one non-code match AND no explicit code-pattern matches.
func HasOnlyNoncodeErrors(raw string) bool {
	if raw == "" {
		return false
	}
	if HasExplicitCodeErrors(raw) {
		return false
	}
	stats := ClassifyWithStats(raw)
	return len(stats) > 0
}

// StatsRecord is one row of ClassifyWithStats output. Each record carries the
// matched category metadata and the run-wide totals so a single record gives
// the full classification picture.
type StatsRecord struct {
	Category       string
	Safety         string
	Remediation    string
	Diagnosis      string
	MatchCount     int
	TotalMatched   int
	TotalLines     int
	UnmatchedLines int
}

// FormatStatsLegacy renders r in the legacy 8-field pipe-delimited shell
// format used by classify_build_errors_with_stats:
//
//	CAT|SAFETY|REMED|DIAG|MATCH_COUNT|TOTAL_MATCHED|TOTAL_LINES|UNMATCHED.
func (r StatsRecord) FormatStatsLegacy() string {
	return fmt.Sprintf("%s|%s|%s|%s|%d|%d|%d|%d",
		r.Category, r.Safety, r.Remediation, r.Diagnosis,
		r.MatchCount, r.TotalMatched, r.TotalLines, r.UnmatchedLines)
}

// ClassifyWithStats walks raw line-by-line, dedupes by category+diagnosis,
// and returns one record per unique match plus the run-wide counters. Order
// of records mirrors the bash implementation: first-seen wins.
func ClassifyWithStats(raw string) []StatsRecord {
	if raw == "" {
		return nil
	}
	type bucket struct {
		idx   int // pattern index (also the iteration order key)
		count int
	}
	buckets := map[string]*bucket{}
	var keys []string

	totalLines, totalMatched, unmatched := 0, 0, 0
	for _, line := range strings.Split(raw, "\n") {
		if IsNonDiagnosticLine(line) {
			continue
		}
		totalLines++
		i := matchPattern(line)
		if i < 0 {
			unmatched++
			continue
		}
		totalMatched++
		key := Patterns()[i].Category + "|" + Patterns()[i].Diagnosis
		if b, ok := buckets[key]; ok {
			b.count++
		} else {
			buckets[key] = &bucket{idx: i, count: 1}
			keys = append(keys, key)
		}
	}

	records := make([]StatsRecord, 0, len(keys))
	for _, k := range keys {
		b := buckets[k]
		p := Patterns()[b.idx]
		records = append(records, StatsRecord{
			Category:       p.Category,
			Safety:         p.Safety,
			Remediation:    p.Remediation,
			Diagnosis:      p.Diagnosis,
			MatchCount:     b.count,
			TotalMatched:   totalMatched,
			TotalLines:     totalLines,
			UnmatchedLines: unmatched,
		})
	}
	return records
}

// ClassifyAll mirrors classify_build_errors_all: returns one record per unique
// CAT|DIAG match across all lines, in first-seen order. Unmatched lines, if
// any, fold into a single sentinel "code|code||Unclassified build error"
// record at most once. Use ClassifyWithStats when you need totals.
func ClassifyAll(raw string) []StatsRecord {
	if raw == "" {
		return nil
	}
	type bucket struct {
		idx   int
		count int
	}
	buckets := map[string]*bucket{}
	var keys []string
	const unmatchedKey = "code|Unclassified build error"
	const unmatchedSentinelIdx = -1

	for _, line := range strings.Split(raw, "\n") {
		if line == "" {
			continue
		}
		i := matchPattern(line)
		if i < 0 {
			if _, ok := buckets[unmatchedKey]; !ok {
				buckets[unmatchedKey] = &bucket{idx: unmatchedSentinelIdx, count: 1}
				keys = append(keys, unmatchedKey)
			} else {
				buckets[unmatchedKey].count++
			}
			continue
		}
		key := Patterns()[i].Category + "|" + Patterns()[i].Diagnosis
		if b, ok := buckets[key]; ok {
			b.count++
		} else {
			buckets[key] = &bucket{idx: i, count: 1}
			keys = append(keys, key)
		}
	}

	out := make([]StatsRecord, 0, len(keys))
	for _, k := range keys {
		b := buckets[k]
		if b.idx == unmatchedSentinelIdx {
			out = append(out, StatsRecord{
				Category: "code", Safety: "code", Remediation: "",
				Diagnosis: "Unclassified build error", MatchCount: b.count,
			})
			continue
		}
		p := Patterns()[b.idx]
		out = append(out, StatsRecord{
			Category:    p.Category,
			Safety:      p.Safety,
			Remediation: p.Remediation,
			Diagnosis:   p.Diagnosis,
			MatchCount:  b.count,
		})
	}
	return out
}

// FormatAllLegacy renders the 4-field legacy line CAT|SAFETY|REMED|DIAG.
func (r StatsRecord) FormatAllLegacy() string {
	return fmt.Sprintf("%s|%s|%s|%s", r.Category, r.Safety, r.Remediation, r.Diagnosis)
}

// ClassifyRoutingDecision emits one of four routing tokens. The bash side
// also exports LAST_BUILD_CLASSIFICATION; the CLI shim in lib/errors.sh is
// responsible for that side-effect, not this function.
//
// Decision rules (order matters — see the m127 Watch For):
//  1. matched_code > 0 AND matched_code >= matched_noncode → code_dominant
//  2. matched_code == 0 AND matched_noncode > 0 AND
//     matched_noncode/total >= 60%                          → noncode_dominant
//  3. matched_code > 0 AND matched_noncode > 0              → mixed_uncertain
//  4. all other shapes (no signal, low-confidence noncode)  → unknown_only
func ClassifyRoutingDecision(raw string) string {
	if raw == "" {
		return RouteUnknownOnly
	}
	matchedCode, matchedNon, unmatched := 0, 0, 0
	for _, line := range strings.Split(raw, "\n") {
		if IsNonDiagnosticLine(line) {
			continue
		}
		i := matchPattern(line)
		if i < 0 {
			unmatched++
			continue
		}
		if Patterns()[i].Category == "code" {
			matchedCode++
		} else {
			matchedNon++
		}
	}
	total := matchedCode + matchedNon + unmatched
	switch {
	case matchedCode > 0 && matchedCode >= matchedNon:
		return RouteCodeDominant
	case matchedCode == 0 && matchedNon > 0 && total > 0 &&
		matchedNon*100/total >= NoncodeConfidenceThreshold:
		return RouteNoncodeDominant
	case matchedCode > 0 && matchedNon > 0:
		return RouteMixedUncertain
	default:
		return RouteUnknownOnly
	}
}

// FilterCodeErrors mirrors lib/error_patterns.sh::filter_code_errors. It
// emits a markdown block separating non-code error summaries from raw code
// error lines.
func FilterCodeErrors(content string) string {
	if content == "" {
		return ""
	}
	var codeLines, nonCodeSummaries []string
	seenSummary := map[string]struct{}{}
	for _, line := range strings.Split(content, "\n") {
		if line == "" {
			continue
		}
		i := matchPattern(line)
		if i >= 0 && Patterns()[i].Category != "code" {
			summary := fmt.Sprintf("- %s: %s", Patterns()[i].Category, Patterns()[i].Diagnosis)
			if _, ok := seenSummary[summary]; !ok {
				seenSummary[summary] = struct{}{}
				nonCodeSummaries = append(nonCodeSummaries, summary)
			}
			continue
		}
		codeLines = append(codeLines, line)
	}
	var out strings.Builder
	if len(nonCodeSummaries) > 0 {
		sort.Strings(nonCodeSummaries) // bash uses sort -u
		out.WriteString("## Already Handled (not code errors)\n")
		for _, s := range nonCodeSummaries {
			out.WriteString(s + "\n")
		}
		out.WriteString("\n")
	}
	if len(codeLines) > 0 {
		out.WriteString("## Code Errors to Fix\n")
		for _, l := range codeLines {
			out.WriteString(l + "\n")
		}
	}
	return out.String()
}

// AnnotateBuildErrors mirrors lib/error_patterns.sh::annotate_build_errors.
// Emits the BUILD_ERRORS.md content with classification headers. The raw
// error text is intentionally NOT included; callers write it separately.
func AnnotateBuildErrors(raw, stage, timestamp string) string {
	if timestamp == "" {
		timestamp = time.Now().Format("2006-01-02 15:04:05")
	}
	classifications := ClassifyAll(raw)
	envCount, codeCount := 0, 0
	var classifyBlock strings.Builder
	for _, r := range classifications {
		if r.Category == "code" {
			codeCount++
			fmt.Fprintf(&classifyBlock, "- **%s** (%s): %s\n", r.Category, r.Safety, r.Diagnosis)
		} else {
			envCount++
			if r.Remediation != "" {
				fmt.Fprintf(&classifyBlock, "- **%s** (%s): %s\n", r.Category, r.Safety, r.Diagnosis)
				fmt.Fprintf(&classifyBlock, "  -> Auto-fix: `%s`\n", r.Remediation)
			} else {
				fmt.Fprintf(&classifyBlock, "- **%s** (%s): %s\n", r.Category, r.Safety, r.Diagnosis)
			}
		}
	}
	var out strings.Builder
	fmt.Fprintf(&out, "# Build Errors — %s\n", timestamp)
	out.WriteString("## Stage\n")
	out.WriteString(stage + "\n\n")
	if classifyBlock.Len() > 0 {
		out.WriteString("## Error Classification\n")
		out.WriteString(classifyBlock.String())
		out.WriteString("\n")
	}
	if envCount > 0 {
		fmt.Fprintf(&out, "## Classified as Environment/Setup (%d issue(s))\n", envCount)
	}
	if codeCount > 0 {
		fmt.Fprintf(&out, "## Classified as Code Error (%d issue(s))\n", codeCount)
	}
	return out.String()
}
