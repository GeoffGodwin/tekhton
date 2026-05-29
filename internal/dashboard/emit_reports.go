// emit_reports.go — reports.js emit. Ports
// lib/dashboard_emitters.sh:emit_dashboard_reports plus the lightweight
// parsers (_parse_intake_report, _parse_coder_summary, _parse_reviewer_report).

package dashboard

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitReports parses the four stage reports and writes data/reports.js.
func (e *Emitter) EmitReports() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	payload := proto.DashboardReportsV1{
		Intake:    parseIntakeReport(e.IntakeReportFile),
		Coder:     parseCoderSummary(e.CoderSummaryFile),
		Reviewer:  parseReviewerReport(e.ReviewerReportFile),
		TestAudit: parseTestAudit(e.TestAuditReportFile),
		Backlog:   proto.DashboardNotesBacklog{}, // zero-init when no notes module
		Teams:     e.buildTeamsReports(),
	}
	return WriteJSFile(filepath.Join(e.DashDir, "data", "reports.js"),
		proto.DashboardVarReports, &payload, e.nowFn())
}

func (e *Emitter) buildTeamsReports() map[string]proto.DashboardTeamReports {
	out := make(map[string]proto.DashboardTeamReports, len(e.ParallelTeams))
	if len(e.ParallelTeams) == 0 {
		return out
	}
	for _, team := range e.ParallelTeams {
		if team == "" {
			continue
		}
		suffix := "_" + team
		out[team] = proto.DashboardTeamReports{
			Intake:   parseIntakeReport(suffixPath(e.IntakeReportFile, suffix)),
			Coder:    parseCoderSummary(suffixPath(e.CoderSummaryFile, suffix)),
			Reviewer: parseReviewerReport(suffixPath(e.ReviewerReportFile, suffix)),
		}
	}
	return out
}

// suffixPath inserts suffix before the .md extension. Bash form:
// `${file%.md}${suffix}.md`.
func suffixPath(path, suffix string) string {
	base := strings.TrimSuffix(path, ".md")
	return base + suffix + ".md"
}

// --- Parsers ----------------------------------------------------------------

var (
	verdictInlineRE    = regexp.MustCompile(`(?m)^[#]* *[Vv]erdict[: ]*(.+?)\s*$`)
	confidenceInlineRE = regexp.MustCompile(`(?m)^[#]* *[Cc]onfidence[: ]*.*?(\d+)`)
	statusInlineRE     = regexp.MustCompile(`(?m)^[#]* *Status[: ]*(.+?)\s*$`)
	severityHighRE     = regexp.MustCompile(`Severity:\s*HIGH`)
	severityMedRE      = regexp.MustCompile(`Severity:\s*MEDIUM`)
	verdictAuditRE     = regexp.MustCompile(`(?i)Verdict:\s*(NEEDS_WORK|PASS|CONCERNS)`)
)

func parseIntakeReport(path string) proto.DashboardIntakeReport {
	out := proto.DashboardIntakeReport{Verdict: "unknown", Confidence: 0}
	data, err := os.ReadFile(path)
	if err != nil {
		out.Verdict = "unknown"
		return out
	}
	if m := verdictInlineRE.FindStringSubmatch(string(data)); len(m) > 1 {
		out.Verdict = strings.TrimSpace(m[1])
	}
	if m := confidenceInlineRE.FindStringSubmatch(string(data)); len(m) > 1 {
		if n, err := strconv.Atoi(m[1]); err == nil {
			out.Confidence = n
		}
	}
	out.TaskText = extractTweakedContent(string(data))
	return out
}

func extractTweakedContent(content string) string {
	scanner := bufio.NewScanner(strings.NewReader(content))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	found := false
	var lines []string
	for scanner.Scan() && len(lines) < 5 {
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
	}
	joined := strings.Join(lines, " ")
	return strings.Join(strings.Fields(joined), " ")
}

func parseCoderSummary(path string) proto.DashboardCoderReport {
	out := proto.DashboardCoderReport{Status: "unknown"}
	data, err := os.ReadFile(path)
	if err != nil {
		return out
	}
	if m := statusInlineRE.FindStringSubmatch(string(data)); len(m) > 1 {
		out.Status = strings.TrimSpace(m[1])
	}
	out.FilesModified = countFilesModified(string(data))
	return out
}

func countFilesModified(content string) int {
	scanner := bufio.NewScanner(strings.NewReader(content))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	inSection := false
	count := 0
	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimLeft(line, " \t")
		if strings.HasPrefix(trimmed, "## Files Created") || strings.HasPrefix(trimmed, "## Files Modified") ||
			strings.HasPrefix(trimmed, "## Files created") || strings.HasPrefix(trimmed, "## Files modified") {
			inSection = true
			continue
		}
		if inSection && strings.HasPrefix(trimmed, "##") {
			break
		}
		if !inSection {
			continue
		}
		if strings.HasPrefix(trimmed, "- ") || strings.HasPrefix(trimmed, "* ") {
			count++
		}
	}
	return count
}

func parseReviewerReport(path string) proto.DashboardReviewerReport {
	out := proto.DashboardReviewerReport{Verdict: "unknown"}
	data, err := os.ReadFile(path)
	if err != nil {
		return out
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
				return out
			}
			continue
		}
		if strings.HasPrefix(line, "## Verdict") {
			captureNext = true
		}
	}
	return out
}

func parseTestAudit(path string) proto.DashboardTestAudit {
	out := proto.DashboardTestAudit{Verdict: "skipped"}
	data, err := os.ReadFile(path)
	if err != nil {
		return out
	}
	content := string(data)
	if m := verdictAuditRE.FindStringSubmatch(content); len(m) > 1 {
		out.Verdict = strings.ToUpper(m[1])
	}
	out.HighFindings = countMatches(severityHighRE, content)
	out.MediumFindings = countMatches(severityMedRE, content)
	return out
}

func countMatches(re *regexp.Regexp, s string) int {
	return len(re.FindAllString(s, -1))
}
