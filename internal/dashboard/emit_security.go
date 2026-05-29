// emit_security.go — security.js emit. Ports
// lib/dashboard_emitters.sh:emit_dashboard_security +
// lib/dashboard_parsers.sh:_parse_security_report.
//
// Note: m33.1 inlines the parser body. The milestone spec described a
// "transition seam" that would shell out to the bash parser; that turns
// out to be more complicated than just porting the small parser. Inlining
// keeps the dashboard package self-contained and avoids a permanent bash
// dependency in the Go critical path. m33.2 may move this body to
// internal/dashboard/parse_security.go but the result is identical.

package dashboard

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitSecurity reads SECURITY_REPORT.md (path from env), extracts findings
// from any `## Findings` section, and writes data/security.js.
func (e *Emitter) EmitSecurity() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	payload := proto.DashboardSecurityV1{
		Findings: parseSecurityReport(e.SecurityReportFile),
	}
	return WriteJSFile(filepath.Join(e.DashDir, "data", "security.js"),
		proto.DashboardVarSecurity, &payload, e.nowFn())
}

var owaspRE = regexp.MustCompile(`A\d{2}`)

// parseSecurityReport extracts bullet-list findings under a `## Findings`
// header. Severity is detected by case-insensitive substring match;
// category is the first `Axx` token. Bash returns an empty array when no
// file is present.
func parseSecurityReport(path string) []proto.DashboardFinding {
	out := []proto.DashboardFinding{}
	if path == "" {
		return out
	}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	inFindings := false
	for scanner.Scan() {
		line := scanner.Text()
		lower := strings.ToLower(line)
		if strings.HasPrefix(strings.TrimLeft(line, " \t"), "## ") {
			if strings.Contains(lower, "findings") {
				inFindings = true
				continue
			}
			if inFindings {
				inFindings = false
			}
			continue
		}
		if !inFindings {
			continue
		}
		trimmed := strings.TrimLeft(line, " \t")
		if !(strings.HasPrefix(trimmed, "- ") || strings.HasPrefix(trimmed, "* ")) {
			continue
		}
		out = append(out, proto.DashboardFinding{
			Severity: detectSeverity(line),
			Category: owaspRE.FindString(line),
			Detail:   line,
		})
	}
	return out
}

func detectSeverity(line string) string {
	upper := strings.ToUpper(line)
	for _, s := range []string{"CRITICAL", "HIGH", "MEDIUM", "LOW"} {
		if strings.Contains(upper, s) {
			return s
		}
	}
	return "INFO"
}
