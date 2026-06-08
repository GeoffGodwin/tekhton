package scout

import (
	"bufio"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// ParseEstimate reads the scout report at path, extracts the Complexity
// Estimate section, and returns the parsed fields. Returns nil estimate
// on missing file / missing section / parse failure — mirrors bash
// parse_scout_complexity's return-code-1 semantics. Other read errors
// propagate.
//
// The parser is markdown-formatting-tolerant: leading bullets ("- "),
// **bold** field names, and range values ("25-30") all decode to the
// numeric prefix exactly as the bash version did via its grep/sed
// pipeline.
func ParseEstimate(path string) (*Estimate, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()

	section := extractComplexitySection(f)
	if section == "" {
		return nil, nil
	}

	est := &Estimate{
		Interconnected: "unknown",
	}
	est.FilesToModify = matchInt(section, `(?i)^Files to modify:`)
	est.EstimatedLines = matchInt(section, `(?i)^Estimated lines`)
	est.Interconnected = matchString(section, `(?i)^Interconnected`)
	if est.Interconnected == "" {
		est.Interconnected = "unknown"
	}
	est.RecommendedCoder = matchInt(section, `(?i)^Recommended coder`)
	est.RecommendedReviewer = matchInt(section, `(?i)^Recommended reviewer`)
	est.RecommendedTester = matchInt(section, `(?i)^Recommended tester`)

	// Validation: at least RecommendedCoder must be non-zero. Mirrors
	// the bash parse_scout_complexity tail validation.
	if est.RecommendedCoder <= 0 {
		return nil, nil
	}
	return est, nil
}

// extractComplexitySection scans the scout report for the
// "## Complexity Estimate" header and returns the section body up to the
// next "## " heading. Empty when the section is absent.
func extractComplexitySection(f *os.File) string {
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 4096), 1<<20)

	var out []string
	inSection := false
	headerRE := regexp.MustCompile(`(?i)^##\s+Complexity Estimate\b`)
	subSectionRE := regexp.MustCompile(`^##\s+`)
	for scanner.Scan() {
		line := scanner.Text()
		if headerRE.MatchString(line) {
			inSection = true
			continue
		}
		if inSection && subSectionRE.MatchString(line) {
			break
		}
		if inSection {
			out = append(out, normalizeSectionLine(line))
		}
	}
	return strings.Join(out, "\n")
}

// normalizeSectionLine strips leading bullets ("- ", "* ") and **bold**
// markers so the per-field regex anchors line up with the raw text.
// Mirrors the sed pipeline in bash parse_scout_complexity at line 66.
func normalizeSectionLine(s string) string {
	// Strip leading whitespace + bullet chars.
	s = strings.TrimLeft(s, " \t")
	for strings.HasPrefix(s, "- ") || strings.HasPrefix(s, "* ") {
		s = s[2:]
	}
	// Strip **bold** markers anywhere.
	s = strings.ReplaceAll(s, "**", "")
	return s
}

// matchInt finds the first line matching pattern (case-insensitive),
// extracts the substring after ':' and returns the first integer found.
// Returns 0 when no match or no integer found.
func matchInt(section, pattern string) int {
	re := regexp.MustCompile(pattern)
	intRE := regexp.MustCompile(`[0-9]+`)
	for _, line := range strings.Split(section, "\n") {
		if !re.MatchString(line) {
			continue
		}
		idx := strings.Index(line, ":")
		if idx < 0 {
			return 0
		}
		val := intRE.FindString(line[idx+1:])
		if val == "" {
			return 0
		}
		n, err := strconv.Atoi(val)
		if err != nil {
			return 0
		}
		return n
	}
	return 0
}

// matchString finds the first line matching pattern (case-insensitive),
// extracts the value after ':', trims whitespace, and returns it.
// Returns "" when no match.
func matchString(section, pattern string) string {
	re := regexp.MustCompile(pattern)
	for _, line := range strings.Split(section, "\n") {
		if !re.MatchString(line) {
			continue
		}
		idx := strings.Index(line, ":")
		if idx < 0 {
			return ""
		}
		val := strings.TrimSpace(line[idx+1:])
		return val
	}
	return ""
}
