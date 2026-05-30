// parse_security.go — SECURITY_REPORT.md parser. Ports
// lib/dashboard_parsers.sh:_parse_security_report.
//
// Extracts bullet-list findings under any `## Findings` header (case-
// insensitive match on "findings" in any ## heading). Severity is detected
// by case-insensitive substring match against CRITICAL/HIGH/MEDIUM/LOW;
// anything else is INFO. Category is the first OWASP `Axx` token in the
// line.
//
// Multiple `## Findings`-style sections aggregate (the bash state machine
// re-enters in_findings on each match) so a report with both "## Resolved
// Findings" and "## New Findings" surfaces both.

package dashboard

import (
	"bufio"
	"os"
	"regexp"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

var owaspRE = regexp.MustCompile(`A\d{2}`)

// ParseSecurity reads SECURITY_REPORT.md at the given path and returns the
// findings payload. Empty path or unreadable file → empty findings slice
// (matches bash echo "[]" path).
func (r *StatusReader) ParseSecurity(path string) (proto.DashboardSecurityV1, error) {
	out := proto.DashboardSecurityV1{Findings: []proto.DashboardFinding{}}
	if path == "" {
		return out, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return out, nil //nolint:nilerr // bash echoes [] when file is unreadable; not an error
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	inFindings := false
	for scanner.Scan() {
		line := scanner.Text()
		lower := strings.ToLower(line)
		trimmedHeading := strings.TrimLeft(line, " \t")
		if strings.HasPrefix(trimmedHeading, "## ") {
			if strings.Contains(lower, "findings") {
				inFindings = true
				continue
			}
			inFindings = false
			continue
		}
		if !inFindings {
			continue
		}
		trimmed := strings.TrimLeft(line, " \t")
		if !(strings.HasPrefix(trimmed, "- ") || strings.HasPrefix(trimmed, "* ")) {
			continue
		}
		out.Findings = append(out.Findings, proto.DashboardFinding{
			Severity: detectSeverity(line),
			Category: owaspRE.FindString(line),
			Detail:   line,
		})
	}
	return out, nil
}

// detectSeverity returns CRITICAL/HIGH/MEDIUM/LOW (case-insensitive substring
// match) or INFO when no match. Order matters: CRITICAL is tested before HIGH
// because a line containing both words ("CRITICAL+HIGH") would otherwise
// resolve to HIGH.
func detectSeverity(line string) string {
	upper := strings.ToUpper(line)
	for _, s := range []string{"CRITICAL", "HIGH", "MEDIUM", "LOW"} {
		if strings.Contains(upper, s) {
			return s
		}
	}
	return "INFO"
}
