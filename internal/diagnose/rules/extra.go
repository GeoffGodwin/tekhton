// extra.go — Go port of lib/diagnose_rules_extra.sh secondary rules.
// _rule_quota_exhausted and _rule_unknown ported to core.go because they
// share the build/core priority bucket in the registry.

package rules

import (
	"fmt"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/diagnose"
	terr "github.com/geoffgodwin/tekhton/internal/errors"
)

// MixedClassification — port of _rule_mixed_classification.
//
// M133 low-confidence rule: the system itself was uncertain about a single
// cause, so this rule intentionally stays low-confidence and biases toward
// inspection. Sources (any-match):
//
//  1. _DIAG_LAST_CLASSIFICATION == "MIXED_UNCERTAIN"
//  2. _DIAG_PRIMARY_SIGNAL == "mixed_uncertain_classification"
//  3. LAST_FAILURE_CONTEXT.json contains
//     `"signal":"mixed_uncertain_classification"`
//  4. RUN_SUMMARY.json contains
//     `"primary_signal":"mixed_uncertain_classification"`
type MixedClassification struct{}

func (MixedClassification) Name() string { return "_rule_mixed_classification" }

func (MixedClassification) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	matched := false
	if c.Classification == "MIXED_UNCERTAIN" {
		matched = true
	}
	if !matched && c.PrimarySignal == "mixed_uncertain_classification" {
		matched = true
	}
	if !matched && projectFileExists(c, ".claude/LAST_FAILURE_CONTEXT.json") {
		body := readProjectFile(c, ".claude/LAST_FAILURE_CONTEXT.json")
		if terr.MatchFailureCtxMixedSignal(body) {
			matched = true
		}
	}
	if !matched && projectFileExists(c, ".claude/logs/RUN_SUMMARY.json") {
		body := readProjectFile(c, ".claude/logs/RUN_SUMMARY.json")
		if terr.MatchSummaryMixedPrimarySignal(body) {
			matched = true
		}
	}
	if !matched {
		return diagnose.Diagnosis{}, false
	}

	rawPath := envOr("BUILD_RAW_ERRORS_FILE",
		fmt.Sprintf("%s/BUILD_RAW_ERRORS.txt", envOr("TEKHTON_DIR", ".tekhton")))

	return diagnose.Diagnosis{
		Classification: "MIXED_UNCERTAIN_CLASSIFICATION",
		Confidence:     diagnose.ConfidenceLow,
		Stage:          c.Stage,
		Suggestions: []string{
			"The build classifier could not confidently identify a single cause.",
			"Some signals looked like code errors; others looked environmental.",
			"Inspect the raw error stream first — root cause likely sits at the top:",
			fmt.Sprintf("  cat %s", rawPath),
			"Look for the FIRST causal error, not the last cascade.",
			"If the first failure looks environmental, re-run preflight:",
			"  tekhton --preflight",
		},
	}, true
}

// TurnExhaustion — port of _rule_turn_exhaustion.
// Pre-M93 compatibility fallback for runs without LAST_FAILURE_CONTEXT.json.
type TurnExhaustion struct{}

func (TurnExhaustion) Name() string { return "_rule_turn_exhaustion" }

func (TurnExhaustion) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	if c.AgentErrorCategory != "AGENT_SCOPE" || c.AgentErrorSubcategory != "max_turns" {
		return diagnose.Diagnosis{}, false
	}
	exitStage := c.Stage
	stageUpper := strings.ToUpper(exitStage)
	task := taskOrFallback(c)
	return diagnose.Diagnosis{
		Classification: "TURN_EXHAUSTION",
		Confidence:     diagnose.ConfidenceHigh,
		Stage:          c.Stage,
		Suggestions: []string{
			fmt.Sprintf("The %s agent exhausted its turn budget.", exitStage),
			"Options:",
			fmt.Sprintf("  1. Increase %s_MAX_TURNS in pipeline.conf, then:", stageUpper),
			fmt.Sprintf("     tekhton --complete --milestone %s", quoteTask(task)),
			"  2. Simplify the task scope",
			"  3. Check if continuation is enabled (CONTINUATION_ENABLED=true)",
		},
	}, true
}

// SplitDepth — port of _rule_split_depth.
type SplitDepth struct{}

func (SplitDepth) Name() string { return "_rule_split_depth" }

func (SplitDepth) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	if !projectFileExists(c, ".claude/logs/RUN_SUMMARY.json") {
		return diagnose.Diagnosis{}, false
	}
	maxDepth := atoiOr(envOr("MILESTONE_MAX_SPLIT_DEPTH", "3"), 3)
	if c.SplitDepth < maxDepth {
		return diagnose.Diagnosis{}, false
	}
	task := taskOrFallback(c)
	return diagnose.Diagnosis{
		Classification: "MILESTONE_SPLIT_DEPTH",
		Confidence:     diagnose.ConfidenceHigh,
		Stage:          c.Stage,
		Suggestions: []string{
			fmt.Sprintf("Milestone was split %d times and still couldn't complete.", c.SplitDepth),
			"The task may be fundamentally too complex for automated splitting.",
			"Options:",
			"  1. Manually break it into smaller milestones:",
			"     tekhton --add-milestone \"<smaller scope>\"",
			fmt.Sprintf("  2. Increase MILESTONE_MAX_SPLIT_DEPTH (currently %d) then:", maxDepth),
			fmt.Sprintf("     tekhton --complete --milestone %s", quoteTask(task)),
		},
	}, true
}

// TransientError — port of _rule_transient_error.
type TransientError struct{}

func (TransientError) Name() string { return "_rule_transient_error" }

func (TransientError) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	if c.AgentErrorCategory != "UPSTREAM" && c.AgentErrorTransient != "true" {
		return diagnose.Diagnosis{}, false
	}
	task := taskOrFallback(c)
	return diagnose.Diagnosis{
		Classification: "TRANSIENT_ERROR",
		Confidence:     diagnose.ConfidenceMedium,
		Stage:          c.Stage,
		Suggestions: []string{
			"Claude API returned transient errors (server error, timeout).",
			"This is usually temporary. Re-run to resume:",
			fmt.Sprintf("  tekhton --complete --milestone %s", quoteTask(task)),
			"If persistent, check Claude API status: status.anthropic.com",
		},
	}, true
}

// TestAuditFailure — port of _rule_test_audit_failure.
type TestAuditFailure struct{}

func (TestAuditFailure) Name() string { return "_rule_test_audit_failure" }

func (TestAuditFailure) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	rel := envOr("TEST_AUDIT_REPORT_FILE", "")
	if rel == "" {
		return diagnose.Diagnosis{}, false
	}
	if !projectFileExists(c, rel) {
		return diagnose.Diagnosis{}, false
	}
	body := readProjectFile(c, rel)
	if !lineMatchesVerdictNeedsWork(body) {
		return diagnose.Diagnosis{}, false
	}
	task := taskOrFallback(c)
	displayRel := envOr("TEST_AUDIT_REPORT_FILE", ".tekhton/TEST_AUDIT_REPORT.md")
	return diagnose.Diagnosis{
		Classification: "TEST_AUDIT_FAILURE",
		Confidence:     diagnose.ConfidenceHigh,
		Stage:          c.Stage,
		Suggestions: []string{
			"Test audit found integrity issues the tester couldn't fix.",
			fmt.Sprintf("Review %s for specific findings.", displayRel),
			"Options:",
			"  1. Fix flagged tests manually (see HIGH severity findings), then:",
			fmt.Sprintf("     tekhton --complete --milestone %s", quoteTask(task)),
			"  2. Remove orphaned tests that import deleted modules",
			"  3. Increase TEST_AUDIT_MAX_REWORK_CYCLES if more auto-fix attempts are warranted",
		},
	}, true
}

// lineMatchesVerdictNeedsWork ports `grep -qi 'Verdict:.*NEEDS_WORK'`:
// scan line-by-line for a line that case-insensitively contains "Verdict:"
// followed (anywhere on the same line) by "NEEDS_WORK".
func lineMatchesVerdictNeedsWork(body string) bool {
	for _, line := range strings.Split(body, "\n") {
		lower := strings.ToLower(line)
		v := strings.Index(lower, "verdict:")
		if v < 0 {
			continue
		}
		if strings.Contains(strings.ToLower(line[v:]), "needs_work") {
			return true
		}
	}
	return false
}
