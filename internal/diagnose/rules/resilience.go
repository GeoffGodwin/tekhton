// resilience.go — Go port of lib/diagnose_rules_resilience.sh.
//
// M133 resilience-arc primary rules. These are the highest-stakes parity
// surface in m32.2 — their classification vocabulary and suggestion text
// is operator-facing and consumed by CI hooks. Source-ordering inside each
// rule is load-bearing — the FIRST matching source wins, even if a later
// source would have produced a different confidence.

package rules

import (
	"fmt"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/diagnose"
	terr "github.com/geoffgodwin/tekhton/internal/errors"
)

// UIGateInteractiveReporter — port of _rule_ui_gate_interactive_reporter.
// Sources (highest-confidence first):
//
//  1. LAST_FAILURE_CONTEXT primary_cause.signal "ui_timeout_interactive_report" → high
//  2. LAST_FAILURE_CONTEXT classification "UI_INTERACTIVE_REPORTER"             → high
//  3. Raw log evidence anywhere in BUILD_RAW_ERRORS_FILE or .claude/logs/       → medium
//  4. RUN_SUMMARY primary_signal + route_taken correlation                      → medium
type UIGateInteractiveReporter struct{}

func (UIGateInteractiveReporter) Name() string { return "_rule_ui_gate_interactive_reporter" }

func (UIGateInteractiveReporter) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	matched := false
	confidence := diagnose.ConfidenceMedium

	if c.PrimarySignal == "ui_timeout_interactive_report" {
		matched = true
		confidence = diagnose.ConfidenceHigh
	}
	if !matched && c.Classification == "UI_INTERACTIVE_REPORTER" {
		matched = true
		confidence = diagnose.ConfidenceHigh
	}
	// Source 3 (a): raw error stream from the current run.
	if !matched {
		rawRel := envOr("BUILD_RAW_ERRORS_FILE",
			fmt.Sprintf("%s/BUILD_RAW_ERRORS.txt", envOr("TEKHTON_DIR", ".tekhton")))
		if projectFileNonEmpty(c, rawRel) {
			body := readProjectFile(c, rawRel)
			if terr.MatchUIGateInteractiveHTML(body) {
				matched = true
				confidence = diagnose.ConfidenceMedium
			}
		}
	}
	// Source 3 (b): recursive scan of .claude/logs/*.{log,jsonl}.
	if !matched {
		logsDir := projectPath(c, ".claude/logs")
		hit := terr.ScanFiles(
			logsDir,
			func(name string) bool {
				return strings.HasSuffix(name, ".log") || strings.HasSuffix(name, ".jsonl")
			},
			terr.MatchUIGateInteractiveHTML,
		)
		if hit {
			matched = true
			confidence = diagnose.ConfidenceMedium
		}
	}
	// Source 4: RUN_SUMMARY correlation.
	if !matched && projectFileExists(c, ".claude/logs/RUN_SUMMARY.json") {
		body := readProjectFile(c, ".claude/logs/RUN_SUMMARY.json")
		sig := terr.ExtractRunSummaryPrimarySignal(body)
		route := terr.ExtractRunSummaryRouteTaken(body)
		if sig == "ui_timeout_interactive_report" && route == "retry_ui_gate_env" {
			matched = true
			confidence = diagnose.ConfidenceMedium
		}
	}

	if !matched {
		return diagnose.Diagnosis{}, false
	}

	task := taskOrFallback(c)

	// Locate Playwright config in priority order.
	cfg := ""
	for _, name := range []string{
		"playwright.config.ts",
		"playwright.config.js",
		"playwright.config.mjs",
		"playwright.config.cjs",
	} {
		if projectFileExists(c, name) {
			cfg = name
			break
		}
	}
	ciGuarded := false
	if cfg != "" {
		body := readProjectFile(c, cfg)
		if terr.MatchHTMLReporterCIGuard(body) {
			ciGuarded = true
		}
	}

	suggestions := []string{
		"The UI gate timed out because Playwright opened an interactive HTML reporter.",
		"Reporter 'html' starts a serve-and-wait loop that never returns to the gate.",
	}
	switch {
	case ciGuarded && cfg != "":
		suggestions = append(suggestions,
			fmt.Sprintf("Note: %s already appears CI-guarded (process.env.CI ? ... : 'html').", cfg),
			"The failure may have come from stale artifacts or an alternate config surface.",
		)
	case cfg != "":
		suggestions = append(suggestions,
			fmt.Sprintf("Fix in %s:", cfg),
			"  Change:  reporter: 'html'",
			"  To:      reporter: process.env.CI ? 'dot' : 'html'",
		)
	default:
		suggestions = append(suggestions,
			"No playwright.config.{ts,js,mjs,cjs} found at the repo root.",
			"Search the test runner config and replace reporter: 'html' with a CI-guarded form.",
		)
	}
	suggestions = append(suggestions,
		"Workaround without source edits:",
		fmt.Sprintf("  CI=1 tekhton --complete --milestone %s", quoteTask(task)),
		"Then re-run normally:",
		fmt.Sprintf("  tekhton --complete --milestone %s", quoteTask(task)),
	)

	return diagnose.Diagnosis{
		Classification: "UI_GATE_INTERACTIVE_REPORTER",
		Confidence:     confidence,
		Stage:          c.Stage,
		Suggestions:    suggestions,
	}, true
}

// BuildFixExhausted — port of _rule_build_fix_exhausted.
//
// Required guard: current run must still have build-error artifacts.
// Sources:
//
//  1. RUN_SUMMARY.json build_fix_stats.outcome ∈ {exhausted, no_progress}
//     AND attempts >= 2 — most reliable.
//  2. BUILD_FIX_REPORT.md with ≥2 `## Attempt ` lines — infer no_progress
//     when the last `- Progress signal:` line says unchanged/worsened,
//     otherwise exhausted.
//  3. LAST_FAILURE_CONTEXT secondary signal "build_fix_budget_exhausted".
type BuildFixExhausted struct{}

func (BuildFixExhausted) Name() string { return "_rule_build_fix_exhausted" }

func (BuildFixExhausted) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}

	errorsRel := envOr("BUILD_ERRORS_FILE",
		fmt.Sprintf("%s/BUILD_ERRORS.md", envOr("TEKHTON_DIR", ".tekhton")))
	rawRel := envOr("BUILD_RAW_ERRORS_FILE",
		fmt.Sprintf("%s/BUILD_RAW_ERRORS.txt", envOr("TEKHTON_DIR", ".tekhton")))
	reportRel := envOr("BUILD_FIX_REPORT_FILE",
		fmt.Sprintf("%s/BUILD_FIX_REPORT.md", envOr("TEKHTON_DIR", ".tekhton")))

	hasArtifacts := projectFileNonEmpty(c, errorsRel) || projectFileNonEmpty(c, rawRel)
	if !hasArtifacts {
		return diagnose.Diagnosis{}, false
	}

	outcome := ""
	attempts := 0

	// Source 1: RUN_SUMMARY build_fix_stats.
	summaryRel := ".claude/logs/RUN_SUMMARY.json"
	if projectFileExists(c, summaryRel) {
		body := readProjectFile(c, summaryRel)
		section := extractJSONSection(body, "build_fix_stats")
		if section != "" {
			oc := terr.ExtractBuildFixOutcome(section)
			attStr := terr.ExtractBuildFixAttempts(section)
			n, _ := tryAtoi(attStr)
			if (oc == "exhausted" || oc == "no_progress") && n >= 2 {
				outcome = oc
				attempts = n
			}
		}
	}

	// Source 2: BUILD_FIX_REPORT.md — count `## Attempt ` headings.
	if outcome == "" && projectFileExists(c, reportRel) {
		body := readProjectFile(c, reportRel)
		count := terr.CountBuildFixReportAttempts(body)
		if count >= 2 {
			attempts = count
			if terr.LastBuildFixProgressLineNoProgress(body) {
				outcome = "no_progress"
			} else {
				outcome = "exhausted"
			}
		}
	}

	// Source 3: M129 secondary signal.
	if outcome == "" && c.SecondarySignal == "build_fix_budget_exhausted" {
		outcome = "exhausted"
		if attempts == 0 {
			attempts = atoiOr(envOr("BUILD_FIX_MAX_ATTEMPTS", "3"), 3)
		}
	}

	if outcome == "" {
		return diagnose.Diagnosis{}, false
	}

	task := taskOrFallback(c)
	errorsPath := envOr("BUILD_ERRORS_FILE",
		fmt.Sprintf("%s/BUILD_ERRORS.md", envOr("TEKHTON_DIR", ".tekhton")))
	reportPath := envOr("BUILD_FIX_REPORT_FILE",
		fmt.Sprintf("%s/BUILD_FIX_REPORT.md", envOr("TEKHTON_DIR", ".tekhton")))

	var suggestions []string
	if outcome == "no_progress" {
		suggestions = []string{
			fmt.Sprintf("Build-fix loop halted after %d attempt(s) with no measurable progress.", attempts),
			"The agent's edits did not reduce the build-error count between attempts.",
		}
	} else {
		suggestions = []string{
			fmt.Sprintf("Build-fix loop exhausted its budget after %d attempt(s).", attempts),
			"The continuation loop reached BUILD_FIX_MAX_ATTEMPTS without a passing gate.",
		}
	}
	suggestions = append(suggestions,
		fmt.Sprintf("Read the per-attempt postmortem: cat %s", reportPath),
		fmt.Sprintf("Read the underlying errors: cat %s", errorsPath),
		"Options:",
		"  1. Fix manually then resume from coder:",
		fmt.Sprintf("     tekhton --complete --milestone --start-at coder %s", quoteTask(task)),
		"  2. Allow more attempts (pipeline.conf: BUILD_FIX_MAX_ATTEMPTS=N) and retry:",
		fmt.Sprintf("     tekhton --complete --milestone %s", quoteTask(task)),
		"  3. Raise the cumulative cap (pipeline.conf: BUILD_FIX_TOTAL_TURN_CAP) for harder bugs.",
	)

	return diagnose.Diagnosis{
		Classification: "BUILD_FIX_EXHAUSTED",
		Confidence:     diagnose.ConfidenceHigh,
		Stage:          c.Stage,
		Suggestions:    suggestions,
	}, true
}

// extractJSONSection mimics the bash `awk '/"key"[[:space:]]*:/{f=1} f{print;
// if(/\}/){exit}}'` snippet — returns the substring from the first line that
// contains `"<key>":` through the first line that contains `}`. Includes
// both bounding lines. Returns "" when the key is absent.
func extractJSONSection(body, key string) string {
	needle := fmt.Sprintf("\"%s\"", key)
	lines := strings.Split(body, "\n")
	in := false
	var b strings.Builder
	for _, line := range lines {
		if !in {
			if !strings.Contains(line, needle) {
				continue
			}
			// Bash awk pattern requires `"key":` so check for the trailing
			// colon after the key.
			if !sectionLineMatches(line, key) {
				continue
			}
			in = true
		}
		if b.Len() > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(line)
		if strings.Contains(line, "}") {
			break
		}
	}
	return b.String()
}

// sectionLineMatches enforces the bash awk regex `"key"[[:space:]]*:`:
// the substring `"<key>"` followed by optional whitespace and `:`.
func sectionLineMatches(line, key string) bool {
	needle := fmt.Sprintf("\"%s\"", key)
	idx := strings.Index(line, needle)
	if idx < 0 {
		return false
	}
	rest := line[idx+len(needle):]
	rest = strings.TrimLeft(rest, " \t")
	return strings.HasPrefix(rest, ":")
}
