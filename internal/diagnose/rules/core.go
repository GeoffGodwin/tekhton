// core.go — Go port of lib/diagnose_rules.sh primary rules.
//
// Each rule is a zero-value struct implementing diagnose.Rule. Match() is a
// byte-for-byte port of the bash function body — same source-priority
// order, same confidence calibration, same suggestion-text wording.
// Modifying any user-facing string here breaks the m32.2 baseline parity
// test; treat the suggestion blocks as frozen contract.

package rules

import (
	"fmt"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/diagnose"
)

// BuildFailure — port of _rule_build_failure.
// Fires when ${BUILD_ERRORS_FILE} is non-empty. Suggestion text branches
// on whether the causal log carries a `"type":"build_fix"` event (i.e. the
// build-fix loop already attempted a repair).
type BuildFailure struct{}

func (BuildFailure) Name() string { return "_rule_build_failure" }

func (BuildFailure) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	rel := envOr("BUILD_ERRORS_FILE", ".tekhton/BUILD_ERRORS.md")
	if !projectFileNonEmpty(c, rel) {
		return diagnose.Diagnosis{}, false
	}

	task := taskOrFallback(c)
	buildFixAttempted := strings.Contains(c.CausalEvents, `"type":"build_fix"`)

	suggestions := []string{
		fmt.Sprintf("Build failed. Errors in %s.", rel),
	}
	if buildFixAttempted {
		suggestions = append(suggestions,
			"Automatic build fix was attempted and failed.",
			fmt.Sprintf("The errors may require manual intervention. See %s.", rel),
		)
	} else {
		suggestions = append(suggestions,
			"Options:",
			"  1. Fix the build errors manually, then:",
			fmt.Sprintf("     tekhton --complete --milestone --start-at coder %s", quoteTask(task)),
			"  2. Or let Tekhton retry (auto build-fix):",
			fmt.Sprintf("     tekhton --complete --milestone %s", quoteTask(task)),
		)
	}
	suggestions = append(suggestions, fmt.Sprintf("See details: cat %s", rel))

	return diagnose.Diagnosis{
		Classification: "BUILD_FAILURE",
		Confidence:     diagnose.ConfidenceHigh,
		Stage:          c.Stage,
		Suggestions:    suggestions,
	}, true
}

// MaxTurns — port of _rule_max_turns. Two emit paths:
//   - MAX_TURNS_ENV_ROOT when schema_version >= 2 and the M133 primary cause
//     is non-AGENT_SCOPE (the cascading-symptom path).
//   - MAX_TURNS_EXHAUSTED otherwise.
type MaxTurns struct{}

func (MaxTurns) Name() string { return "_rule_max_turns" }

func (MaxTurns) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	// M129: prefer secondary cause from v2 schema, fall back to the top-level
	// alias category/subcategory (writer compatibility layer). ReadContext
	// already populated SecondaryCategory and Classification's siblings; for
	// the alias-category path we re-derive from LAST_FAILURE_CONTEXT.json by
	// reading the file freshly when SecondaryCategory is empty.
	cat := c.SecondaryCategory
	sub := c.SecondarySubcategory

	matched := false
	if cat == "AGENT_SCOPE" && sub == "max_turns" {
		matched = true
	} else if strings.Contains(c.ExitReason, "complete_loop_max_attempts") {
		matched = true
	} else if strings.Contains(c.Notes, "max_turns") {
		matched = true
	}
	if !matched {
		return diagnose.Diagnosis{}, false
	}

	stage := c.Stage
	if stage == "" {
		stage = "coder"
	}
	task := taskOrFallback(c)
	limit := envOr("CODER_MAX_TURNS", "80")
	bumped := bumpTurnLimit(limit)

	// M133 cascading-symptom branch: schema_version >= 2 and primary is
	// non-AGENT_SCOPE → emit MAX_TURNS_ENV_ROOT instead of EXHAUSTED.
	if c.SchemaVersion >= 2 && c.PrimaryCategory != "" && c.PrimaryCategory != "AGENT_SCOPE" {
		primarySub := c.PrimarySubcategory
		if primarySub == "" {
			primarySub = "?"
		}
		primarySig := c.PrimarySignal
		if primarySig == "" {
			primarySig = "unknown signal"
		}
		return diagnose.Diagnosis{
			Classification: "MAX_TURNS_ENV_ROOT",
			Confidence:     diagnose.ConfidenceHigh,
			Stage:          stage,
			Suggestions: []string{
				fmt.Sprintf("The %s agent hit its turn limit (%s turns) — but max_turns was the secondary symptom.", stage, limit),
				fmt.Sprintf("Primary cause: %s/%s (%s).", c.PrimaryCategory, primarySub, primarySig),
				"Adding more turns or splitting scope is unlikely to help until the root cause is fixed.",
				"Read the root-cause artifact:",
				"  cat .claude/LAST_FAILURE_CONTEXT.json",
				"Re-run preflight if the failure looks environmental:",
				"  tekhton --preflight",
				"Then resume from coder once the root cause is resolved:",
				fmt.Sprintf("  tekhton --complete --milestone --start-at coder %s", quoteTask(task)),
			},
		}, true
	}

	return diagnose.Diagnosis{
		Classification: "MAX_TURNS_EXHAUSTED",
		Confidence:     diagnose.ConfidenceHigh,
		Stage:          stage,
		Suggestions: []string{
			fmt.Sprintf("The %s agent hit its turn limit (%s turns) on consecutive attempts.", stage, limit),
			"The task scope is likely too large for the current turn budget.",
			"Options:",
			"  1. Resume from test (if reviewer report is already present):",
			fmt.Sprintf("     tekhton --complete --milestone --start-at test %s", quoteTask(task)),
			fmt.Sprintf("  2. Retry with more turns (edit pipeline.conf: CODER_MAX_TURNS=%s):", bumped),
			fmt.Sprintf("     tekhton --complete --milestone %s", quoteTask(task)),
			"  3. Split the milestone into smaller chunks (auto-split if MILESTONE_SPLIT_ENABLED=true):",
			fmt.Sprintf("     tekhton --complete --milestone %s", quoteTask(task)),
		},
	}, true
}

// ReviewLoop — port of _rule_review_loop. Fires when the review stage was
// the exit stage (or 3+ reviewer rejections in the causal log) AND the
// REVIEWER_REPORT.md still records a CHANGES_REQUIRED / REJECTED verdict.
type ReviewLoop struct{}

func (ReviewLoop) Name() string { return "_rule_review_loop" }

func (ReviewLoop) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	exitStage := c.Stage
	reviewRejections := 0
	if exitStage != "review" {
		if c.CausalEvents == "" {
			return diagnose.Diagnosis{}, false
		}
		for _, line := range strings.Split(c.CausalEvents, "\n") {
			if !strings.Contains(line, `"type":"verdict"`) {
				continue
			}
			if !strings.Contains(line, `"stage":"reviewer"`) {
				continue
			}
			if strings.Contains(line, "CHANGES_REQUIRED") || strings.Contains(line, "REJECTED") {
				reviewRejections++
			}
		}
		if reviewRejections < 3 {
			return diagnose.Diagnosis{}, false
		}
	}

	reviewerRel := envOr("REVIEWER_REPORT_FILE", ".tekhton/REVIEWER_REPORT.md")
	if projectFileExists(c, reviewerRel) {
		body := readProjectFile(c, reviewerRel)
		if !strings.Contains(body, "CHANGES_REQUIRED") && !strings.Contains(body, "REJECTED") {
			return diagnose.Diagnosis{}, false
		}
	}

	cycleCount := c.ReviewCycles
	if cycleCount == 0 {
		if reviewRejections > 0 {
			cycleCount = reviewRejections
		} else {
			cycleCount = 3
		}
	}

	task := taskOrFallback(c)
	return diagnose.Diagnosis{
		Classification: "REVIEW_REJECTION_LOOP",
		Confidence:     diagnose.ConfidenceHigh,
		Stage:          c.Stage,
		Suggestions: []string{
			fmt.Sprintf("Reviewer rejected the code %d times. The coder may be unable to address the feedback within the turn budget.", cycleCount),
			"Options:",
			"  1. Increase MAX_REVIEW_CYCLES in pipeline.conf, then:",
			fmt.Sprintf("     tekhton --complete --milestone %s", quoteTask(task)),
			fmt.Sprintf("  2. Read %s and fix the issues manually, then:", reviewerRel),
			fmt.Sprintf("     tekhton --complete --milestone --start-at review %s", quoteTask(task)),
			"  3. Retry review only:",
			fmt.Sprintf("     tekhton --complete --milestone --start-at review %s", quoteTask(task)),
		},
	}, true
}

// SecurityHalt — port of _rule_security_halt.
type SecurityHalt struct{}

func (SecurityHalt) Name() string { return "_rule_security_halt" }

func (SecurityHalt) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	rel := envOr("SECURITY_REPORT_FILE", ".tekhton/SECURITY_REPORT.md")
	if !projectFileExists(c, rel) {
		return diagnose.Diagnosis{}, false
	}
	body := readProjectFile(c, rel)
	if !strings.Contains(body, "HALT") && !strings.Contains(body, "halt") {
		return diagnose.Diagnosis{}, false
	}
	task := taskOrFallback(c)
	return diagnose.Diagnosis{
		Classification: "SECURITY_HALT",
		Confidence:     diagnose.ConfidenceHigh,
		Stage:          c.Stage,
		Suggestions: []string{
			"Security scan found CRITICAL unfixable vulnerabilities.",
			"Options:",
			"  1. Add waivers to SECURITY_WAIVER_FILE for known-accepted risks, then:",
			fmt.Sprintf("     tekhton --complete --milestone %s", quoteTask(task)),
			"  2. Fix the vulnerabilities manually and re-run:",
			fmt.Sprintf("     tekhton --complete --milestone %s", quoteTask(task)),
			"  3. Change SECURITY_UNFIXABLE_POLICY to 'escalate' in pipeline.conf",
		},
	}, true
}

// IntakeClarity — port of _rule_intake_clarity. Triggers on:
//
//   - CLARIFICATIONS.md present and non-empty
//   - body has a `- [ ]` unchecked line
//   - PIPELINE_STATE exit_stage is "intake" (if state file exists)
type IntakeClarity struct{}

func (IntakeClarity) Name() string { return "_rule_intake_clarity" }

func (IntakeClarity) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	rel := envOr("CLARIFICATIONS_FILE", ".tekhton/CLARIFICATIONS.md")
	if !projectFileNonEmpty(c, rel) {
		return diagnose.Diagnosis{}, false
	}
	body := readProjectFile(c, rel)
	if !containsUnchecked(body) {
		return diagnose.Diagnosis{}, false
	}
	// When PIPELINE_STATE exists, the exit_stage must be "intake".
	if c.Stage != "" && c.Stage != "intake" {
		return diagnose.Diagnosis{}, false
	}
	task := taskOrFallback(c)
	return diagnose.Diagnosis{
		Classification: "INTAKE_NEEDS_CLARITY",
		Confidence:     diagnose.ConfidenceHigh,
		Stage:          c.Stage,
		Suggestions: []string{
			"The PM agent needs clarification on this milestone.",
			fmt.Sprintf("Questions are in %s.", rel),
			"Options:",
			fmt.Sprintf("  1. Answer the questions in %s, then:", rel),
			fmt.Sprintf("     tekhton --complete --milestone %s", quoteTask(task)),
			"  2. Lower INTAKE_CLARITY_THRESHOLD in pipeline.conf if the gate is too aggressive",
		},
	}, true
}

// QuotaExhausted — port of _rule_quota_exhausted. Detects the
// `.claude/QUOTA_PAUSED` marker file produced by `enter_quota_pause`.
type QuotaExhausted struct{}

func (QuotaExhausted) Name() string { return "_rule_quota_exhausted" }

func (QuotaExhausted) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	if !projectFileExists(c, ".claude/QUOTA_PAUSED") {
		return diagnose.Diagnosis{}, false
	}
	return diagnose.Diagnosis{
		Classification: "QUOTA_EXHAUSTED",
		Confidence:     diagnose.ConfidenceHigh,
		Stage:          c.Stage,
		Suggestions: []string{
			"Pipeline paused waiting for quota refresh.",
			"It will resume automatically. No action needed.",
			"If you need it sooner, wait for your 5-hour window to refresh.",
		},
	}, true
}

// StuckLoop — port of _rule_stuck_loop.
type StuckLoop struct{}

func (StuckLoop) Name() string { return "_rule_stuck_loop" }

func (StuckLoop) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	if c == nil {
		return diagnose.Diagnosis{}, false
	}
	maxAttempts := atoiOr(envOr("MAX_PIPELINE_ATTEMPTS", "5"), 5)
	if c.PipelineAttempt < maxAttempts {
		return diagnose.Diagnosis{}, false
	}
	task := taskOrFallback(c)
	return diagnose.Diagnosis{
		Classification: "STUCK_LOOP",
		Confidence:     diagnose.ConfidenceHigh,
		Stage:          c.Stage,
		Suggestions: []string{
			fmt.Sprintf("Pipeline completed %d attempts with no forward progress.", c.PipelineAttempt),
			"This usually means the task is too complex for automatic resolution.",
			"Options:",
			"  1. Simplify the milestone and re-run:",
			fmt.Sprintf("     tekhton --complete --milestone %s", quoteTask(task)),
			"  2. Break it into smaller milestones:",
			"     tekhton --add-milestone \"<smaller scope>\"",
			"  3. Check the scout report for scope issues",
		},
	}, true
}

// Unknown — port of _rule_unknown. Always matches; the engine relies on
// this as the final fallback when no other rule fires.
type Unknown struct{}

func (Unknown) Name() string { return "_rule_unknown" }

func (Unknown) Match(c *diagnose.Context) (diagnose.Diagnosis, bool) {
	stage := ""
	if c != nil {
		stage = c.Stage
	}
	return diagnose.Diagnosis{
		Classification: "UNKNOWN",
		Confidence:     diagnose.ConfidenceLow,
		Stage:          stage,
		Suggestions: []string{
			"No specific failure pattern identified.",
			"Check the latest agent output in .claude/logs/",
			"Re-run with DASHBOARD_VERBOSITY=verbose for more detail",
		},
	}, true
}

// --- shared helpers ---------------------------------------------------------

// containsUnchecked reports whether `body` contains a `- [ ]` line — bash
// `grep -q '^\- \[ \]'`. Anchored to start-of-line for parity.
func containsUnchecked(body string) bool {
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "- [ ]") {
			return true
		}
	}
	return false
}

// bumpTurnLimit ports the bash `_bumped=$(( _limit + 40 ))` expansion. Falls
// back to the literal `<limit>+40` form when the limit isn't numeric so the
// emit text never references "+40" arithmetic that didn't happen.
func bumpTurnLimit(limit string) string {
	n, ok := tryAtoi(limit)
	if !ok {
		return limit
	}
	return fmt.Sprintf("%d", n+40)
}

func atoiOr(s string, fallback int) int {
	n, ok := tryAtoi(s)
	if !ok {
		return fallback
	}
	return n
}

func tryAtoi(s string) (int, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, false
	}
	n := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0, false
		}
		n = n*10 + int(r-'0')
	}
	return n, true
}
