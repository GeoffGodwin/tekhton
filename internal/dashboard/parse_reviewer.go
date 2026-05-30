// parse_reviewer.go — REVIEWER_REPORT.md parser. Ports
// lib/dashboard_parsers.sh:_parse_reviewer_report.
//
// Extracts a single verdict value from the line following "## Verdict".

package dashboard

import (
	"bufio"
	"os"
	"regexp"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// mustCompileAnchored is a small helper so parser files can declare anchored
// regexes inline next to their callers.
func mustCompileAnchored(pat string) *regexp.Regexp {
	return regexp.MustCompile(pat)
}

// ParseReviewer reads REVIEWER_REPORT.md and returns the verdict line that
// follows "## Verdict". Missing file → verdict="unknown".
func (r *StatusReader) ParseReviewer(path string) (proto.DashboardReviewerReport, error) {
	out := proto.DashboardReviewerReport{Verdict: "unknown"}
	data, err := os.ReadFile(path)
	if err != nil {
		return out, nil //nolint:nilerr // bash echoes "null"/unknown when file is missing
	}
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	captureNext := false
	for scanner.Scan() {
		line := scanner.Text()
		if captureNext {
			v := strings.TrimSpace(line)
			if v != "" {
				out.Verdict = v
				return out, nil
			}
			continue
		}
		if strings.HasPrefix(line, "## Verdict") {
			captureNext = true
		}
	}
	return out, nil
}
