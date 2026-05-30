// parse_intake.go — INTAKE_REPORT.md parser. Ports
// lib/dashboard_parsers.sh:_parse_intake_report.
//
// Two-format support:
//   - Inline:  "Verdict: PASS"          / "Confidence: 82"
//   - Header:  "## Verdict\nPASS"        / "## Confidence\n82"
//
// Task text comes from the "## Tweaked Content" section: read up to 5
// non-blank lines, collapse newlines + runs of whitespace to a single space.

package dashboard

import (
	"bufio"
	"os"
	"regexp"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

var (
	verdictInlineRE    = regexp.MustCompile(`(?m)^[#]* *[Vv]erdict[: ]+(.+?)\s*$`)
	confidenceInlineRE = regexp.MustCompile(`(?m)^[#]* *[Cc]onfidence[: ]+.*?(\d+)`)
	statusInlineRE     = regexp.MustCompile(`(?m)^[#]* *Status[: ]+(.+?)\s*$`)
	verdictHeaderRE    = regexp.MustCompile(`(?m)^##? *[Vv]erdict\s*$`)
	confidenceHeadRE   = regexp.MustCompile(`(?m)^##? *[Cc]onfidence\s*$`)
	digitsRE           = regexp.MustCompile(`\d+`)
)

// ParseIntake reads INTAKE_REPORT.md and returns the parsed verdict +
// confidence + extracted Tweaked Content. Missing file → defaults
// (verdict="unknown", confidence=0, task_text="").
func (r *StatusReader) ParseIntake(path string) (proto.DashboardIntakeReport, error) {
	out := proto.DashboardIntakeReport{Verdict: "unknown", Confidence: 0}
	data, err := os.ReadFile(path)
	if err != nil {
		return out, nil //nolint:nilerr // bash echoes "null" verdict=unknown when file is missing
	}
	content := string(data)
	if m := verdictInlineRE.FindStringSubmatch(content); len(m) > 1 {
		out.Verdict = strings.TrimSpace(m[1])
	} else if v := extractAfterHeader(content, verdictHeaderRE); v != "" {
		out.Verdict = v
	}
	if m := confidenceInlineRE.FindStringSubmatch(content); len(m) > 1 {
		out.Confidence = atoiSafe(m[1])
	} else if v := extractAfterHeader(content, confidenceHeadRE); v != "" {
		if m := digitsRE.FindString(v); m != "" {
			out.Confidence = atoiSafe(m)
		}
	}
	out.TaskText = extractTweakedContent(content)
	return out, nil
}

// extractAfterHeader returns the trimmed first non-empty line that follows a
// regex-matched header line. Mirrors the bash `awk '/.../{getline; ...; exit}'`
// idiom.
func extractAfterHeader(content string, headerRE *regexp.Regexp) string {
	loc := headerRE.FindStringIndex(content)
	if loc == nil {
		return ""
	}
	rest := content[loc[1]:]
	scanner := bufio.NewScanner(strings.NewReader(rest))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		return line
	}
	return ""
}

// extractTweakedContent reads up to 5 non-blank lines from the "## Tweaked
// Content" section, joins with a single space, and collapses runs of
// whitespace.
func extractTweakedContent(content string) string {
	scanner := bufio.NewScanner(strings.NewReader(content))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	found := false
	var lines []string
	for scanner.Scan() {
		line := scanner.Text()
		if !found {
			if strings.HasPrefix(line, "## Tweaked Content") {
				found = true
			}
			continue
		}
		if strings.HasPrefix(line, "## ") || strings.HasPrefix(line, "### ") {
			break
		}
		if strings.TrimSpace(line) == "" {
			continue
		}
		lines = append(lines, line)
		if len(lines) >= 5 {
			break
		}
	}
	joined := strings.Join(lines, " ")
	return strings.Join(strings.Fields(joined), " ")
}

func atoiSafe(s string) int {
	n := 0
	for _, ch := range s {
		if ch < '0' || ch > '9' {
			break
		}
		n = n*10 + int(ch-'0')
	}
	return n
}
