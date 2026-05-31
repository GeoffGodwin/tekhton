// resilience_preflight.go — Go port of
// lib/diagnose_rules_resilience_preflight.sh::_rule_preflight_interactive_config.
//
// Detects the case where preflight already flagged an interactive Playwright
// reporter configuration but the gate-level evidence isn't strong enough for
// _rule_ui_gate_interactive_reporter to fire. Fallback by design — ordered
// AFTER the gate-level rule in the registry.

package rules

import (
	"fmt"

	"github.com/geoffgodwin/tekhton/internal/diagnose"
	terr "github.com/geoffgodwin/tekhton/internal/errors"
)

// PreflightInteractiveConfig — port of _rule_preflight_interactive_config.
type PreflightInteractiveConfig struct{}

func (PreflightInteractiveConfig) Name() string { return "_rule_preflight_interactive_config" }

func (PreflightInteractiveConfig) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}

	matched := false
	cfgFile := ""

	// Source 1: RUN_SUMMARY.preflight_ui section.
	summaryRel := ".claude/logs/RUN_SUMMARY.json"
	if projectFileExists(c, summaryRel) {
		body := readProjectFile(c, summaryRel)
		section := extractJSONSection(body, "preflight_ui")
		if section != "" {
			detected := terr.ExtractRunSummaryInteractiveDetected(section)
			patched := terr.ExtractRunSummaryReporterPatched(section)
			cfgFile = terr.ExtractRunSummaryInteractiveConfigFile(section)
			if detected == "true" && patched == "false" {
				matched = true
			}
		}
	}

	// Source 2: PREFLIGHT_REPORT.md fail entry.
	tekhtonDir := envOr("TEKHTON_DIR", ".tekhton")
	preflightRel := fmt.Sprintf("%s/PREFLIGHT_REPORT.md", tekhtonDir)
	if !matched && projectFileExists(c, preflightRel) {
		body := readProjectFile(c, preflightRel)
		// Bash uses `grep -qF 'UI Config (Playwright) — html reporter'` AND
		// `grep -qiE '(^|[^a-z])(fail|FAIL)([^a-z]|$)'` — both must hit, but
		// they don't need to be on the same line.
		hasHeader := false
		for _, line := range splitLines(body) {
			if matchPreflightUIHeader(line) {
				hasHeader = true
				break
			}
		}
		if hasHeader && terr.MatchPreflightReportFailWord(body) {
			matched = true
		}
	}

	// Source 3a: explicit primary signal.
	if !matched && c.PrimarySignal == "ui_interactive_config_preflight" {
		matched = true
	}
	// Source 3b: explicit classification in LAST_FAILURE_CONTEXT.json.
	if !matched && projectFileExists(c, ".claude/LAST_FAILURE_CONTEXT.json") {
		body := readProjectFile(c, ".claude/LAST_FAILURE_CONTEXT.json")
		if terr.MatchFailureCtxPreflightConfig(body) {
			matched = true
		}
	}

	if !matched {
		return diagnose.Diagnosis{}, false
	}

	task := taskOrFallback(c)
	cfgLabel := cfgFile
	if cfgLabel == "" {
		cfgLabel = "playwright.config.ts"
	}

	return diagnose.Diagnosis{
		Classification: "PREFLIGHT_INTERACTIVE_CONFIG",
		Confidence:     diagnose.ConfidenceHigh,
		Stage:          c.Stage,
		Suggestions: []string{
			"Preflight detected an interactive Playwright reporter configuration.",
			fmt.Sprintf("%s sets reporter: 'html', which would hang the UI gate.", cfgLabel),
			fmt.Sprintf("Manual fix in %s:", cfgLabel),
			"  Change:  reporter: 'html'",
			"  To:      reporter: process.env.CI ? 'dot' : 'html'",
			"Or enable auto-fix (pipeline.conf):",
			"  PREFLIGHT_UI_CONFIG_AUTO_FIX=true",
			"Then re-run:",
			fmt.Sprintf("  tekhton --complete --milestone %s", quoteTask(task)),
		},
	}, true
}

// matchPreflightUIHeader ports the bash `grep -qF 'UI Config (Playwright) —
// html reporter'` predicate. We do a fixed-string comparison rather than a
// regex to mirror -F.
func matchPreflightUIHeader(line string) bool {
	const needle = "UI Config (Playwright) — html reporter"
	return containsExact(line, needle)
}

// containsExact is `strings.Contains`-by-rune. Same semantics; kept as a
// tiny shim so the rule-level call reads as the bash predicate.
func containsExact(line, needle string) bool {
	return indexOfExact(line, needle) >= 0
}

func indexOfExact(line, needle string) int {
	if needle == "" {
		return 0
	}
	for i := 0; i+len(needle) <= len(line); i++ {
		if line[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
}

// splitLines splits body on '\n'. Kept distinct from extra.go's helper so
// the resilience rules can stay self-contained at review time.
func splitLines(body string) []string {
	if body == "" {
		return nil
	}
	out := make([]string, 0, 8)
	start := 0
	for i := 0; i < len(body); i++ {
		if body[i] == '\n' {
			out = append(out, body[start:i])
			start = i + 1
		}
	}
	if start < len(body) {
		out = append(out, body[start:])
	}
	return out
}
