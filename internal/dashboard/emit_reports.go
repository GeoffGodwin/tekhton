// emit_reports.go — reports.js emit. Ports
// lib/dashboard_emitters.sh:emit_dashboard_reports. The per-stage parser
// bodies (intake, coder, reviewer) live in parse_*.go behind the
// StatusReader after m33.2; test_audit parsing stays here since the bash
// equivalent was inline in the emitter.

package dashboard

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

var (
	severityHighRE = regexp.MustCompile(`Severity:\s*HIGH`)
	severityMedRE  = regexp.MustCompile(`Severity:\s*MEDIUM`)
	verdictAuditRE = regexp.MustCompile(`(?i)Verdict:\s*(NEEDS_WORK|PASS|CONCERNS)`)
)

// EmitReports parses the four stage reports and writes data/reports.js.
func (e *Emitter) EmitReports() error {
	if !e.Enabled || !e.dataDirExists() {
		return nil
	}
	sr := e.statusReader()
	intake, err := sr.ParseIntake(e.IntakeReportFile)
	if err != nil {
		return err
	}
	coder, err := sr.ParseCoder(e.CoderSummaryFile)
	if err != nil {
		return err
	}
	reviewer, err := sr.ParseReviewer(e.ReviewerReportFile)
	if err != nil {
		return err
	}
	payload := proto.DashboardReportsV1{
		Intake:    intake,
		Coder:     coder,
		Reviewer:  reviewer,
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
	sr := e.statusReader()
	for _, team := range e.ParallelTeams {
		if team == "" {
			continue
		}
		suffix := "_" + team
		intake, _ := sr.ParseIntake(suffixPath(e.IntakeReportFile, suffix))
		coder, _ := sr.ParseCoder(suffixPath(e.CoderSummaryFile, suffix))
		reviewer, _ := sr.ParseReviewer(suffixPath(e.ReviewerReportFile, suffix))
		out[team] = proto.DashboardTeamReports{
			Intake:   intake,
			Coder:    coder,
			Reviewer: reviewer,
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

// parseTestAudit reads TEST_AUDIT_REPORT.md and counts severity-tagged
// findings. The bash equivalent was inline grep counters in
// emit_dashboard_reports; not lifted into a StatusReader method because the
// per-line shape is simpler than the other parsers.
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
