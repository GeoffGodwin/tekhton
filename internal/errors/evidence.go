package errors

import "regexp"

// Evidence regexes — the small set of match-evidence patterns the m32.2
// diagnose rules consume. Lives in internal/errors so the rule files in
// internal/diagnose/rules/ can stay free of `import "regexp"` per the
// m32.2 boundary (enforced by scripts/wedge-audit.sh).
//
// These are NOT build-error classifier patterns (those are in patterns.go);
// they are confirmatory match patterns used by the diagnose rules to attach
// confidence to a route they already suspect from structured signals.

//nolint:gochecknoglobals // compiled regex registry; intentionally process-wide.
var (
	// uiGateInteractiveHTML matches Playwright's serve-and-wait stderr line
	// ("Serving HTML report at http://...") — only the live runner emits the
	// URL on that line, so this anchor avoids false positives on agent-authored
	// markdown that merely quotes the marker text. Used by
	// _rule_ui_gate_interactive_reporter source 3.
	uiGateInteractiveHTML = regexp.MustCompile(`Serving HTML report at https?://`)

	// htmlReporterCIGuard matches the CI-guarded reporter form
	// (`process.env.CI ? <something> : 'html'`) inside a Playwright config.
	// Used by _rule_ui_gate_interactive_reporter to detect when the suggested
	// fix is already in place and adjust suggestion text accordingly.
	htmlReporterCIGuard = regexp.MustCompile(`process\.env\.CI[^?]*\?[^:]*:[^,}]*['"]html['"]`)

	// preflightReportFailWord matches "fail" or "FAIL" as a whole word in a
	// PREFLIGHT_REPORT.md cell (case-insensitive). Used by
	// _rule_preflight_interactive_config source 2.
	preflightReportFailWord = regexp.MustCompile(`(^|[^a-zA-Z])(fail|FAIL)([^a-zA-Z]|$)`)

	// runSummarySignalRe / runSummaryRouteRe / runSummaryBoolRe /
	// runSummaryStrRe extract typed values from RUN_SUMMARY.json nested
	// sections. Plain Contains() can't carry the substring->key binding
	// reliably, so the rules call the helpers below instead.
	runSummaryPrimarySignalRe       = regexp.MustCompile(`"primary_signal"\s*:\s*"([^"]*)"`)
	runSummaryRouteTakenRe          = regexp.MustCompile(`"route_taken"\s*:\s*"([^"]*)"`)
	runSummaryInteractiveDetectedRe = regexp.MustCompile(`"interactive_config_detected"\s*:\s*(true|false)`)
	runSummaryReporterPatchedRe     = regexp.MustCompile(`"reporter_auto_patched"\s*:\s*(true|false)`)
	runSummaryInteractiveCfgFileRe  = regexp.MustCompile(`"interactive_config_file"\s*:\s*"([^"]*)"`)
	runSummaryBuildFixOutcomeRe     = regexp.MustCompile(`"outcome"\s*:\s*"([^"]*)"`)
	runSummaryBuildFixAttemptsRe    = regexp.MustCompile(`"attempts"\s*:\s*(\d+)`)
	failureCtxClassificationRe      = regexp.MustCompile(`"classification"\s*:\s*"([^"]+)"`)
	failureCtxMigrationFromRe       = regexp.MustCompile(`"migration_from"\s*:\s*"([^"]+)"`)
	failureCtxMigrationToRe         = regexp.MustCompile(`"migration_to"\s*:\s*"([^"]+)"`)
	failureCtxMixedSignalRe         = regexp.MustCompile(`"signal"\s*:\s*"mixed_uncertain_classification"`)
	summaryMixedPrimarySignalRe     = regexp.MustCompile(`"primary_signal"\s*:\s*"mixed_uncertain_classification"`)
	failureCtxPreflightCfgRe        = regexp.MustCompile(`"classification"\s*:\s*"PREFLIGHT_INTERACTIVE_CONFIG"`)
	pipelineConfigVersionPinnedRe   = regexp.MustCompile(`(?m)^TEKHTON_CONFIG_VERSION=`)
	buildFixReportAttemptRe         = regexp.MustCompile(`(?m)^## Attempt `)
	buildFixReportProgressLineRe    = regexp.MustCompile(`(?m)^- Progress signal:.*$`)
	buildFixProgressNoProgressRe    = regexp.MustCompile(`(unchanged|worsened)`)
)

// MatchUIGateInteractiveHTML returns true when the text contains a
// Playwright "Serving HTML report at https?://" line.
func MatchUIGateInteractiveHTML(text string) bool {
	return uiGateInteractiveHTML.MatchString(text)
}

// MatchHTMLReporterCIGuard returns true when the text already wires
// `process.env.CI ? ... : 'html'`-style guard around the html reporter.
func MatchHTMLReporterCIGuard(text string) bool {
	return htmlReporterCIGuard.MatchString(text)
}

// MatchPreflightReportFailWord returns true when the text contains the
// whole word "fail" (case-insensitive) — used to detect a fail entry in
// PREFLIGHT_REPORT.md.
func MatchPreflightReportFailWord(text string) bool {
	return preflightReportFailWord.MatchString(text)
}

// ExtractRunSummaryPrimarySignal returns the first `"primary_signal":"..."` value.
func ExtractRunSummaryPrimarySignal(text string) string {
	return firstSubmatch(runSummaryPrimarySignalRe, text)
}

// ExtractRunSummaryRouteTaken returns the first `"route_taken":"..."` value.
func ExtractRunSummaryRouteTaken(text string) string {
	return firstSubmatch(runSummaryRouteTakenRe, text)
}

// ExtractRunSummaryInteractiveDetected returns "true" / "false" or "".
func ExtractRunSummaryInteractiveDetected(text string) string {
	return firstSubmatch(runSummaryInteractiveDetectedRe, text)
}

// ExtractRunSummaryReporterPatched returns "true" / "false" or "".
func ExtractRunSummaryReporterPatched(text string) string {
	return firstSubmatch(runSummaryReporterPatchedRe, text)
}

// ExtractRunSummaryInteractiveConfigFile returns the detected interactive
// Playwright config filename, or "".
func ExtractRunSummaryInteractiveConfigFile(text string) string {
	return firstSubmatch(runSummaryInteractiveCfgFileRe, text)
}

// ExtractBuildFixOutcome returns the first `"outcome":"..."` value.
func ExtractBuildFixOutcome(text string) string {
	return firstSubmatch(runSummaryBuildFixOutcomeRe, text)
}

// ExtractBuildFixAttempts returns the first `"attempts":N` integer-as-string
// value, or "".
func ExtractBuildFixAttempts(text string) string {
	return firstSubmatch(runSummaryBuildFixAttemptsRe, text)
}

// ExtractFailureCtxClassification returns the first
// `"classification":"..."` value.
func ExtractFailureCtxClassification(text string) string {
	return firstSubmatch(failureCtxClassificationRe, text)
}

// ExtractFailureCtxMigrationFrom returns the first `"migration_from":"..."`.
func ExtractFailureCtxMigrationFrom(text string) string {
	return firstSubmatch(failureCtxMigrationFromRe, text)
}

// ExtractFailureCtxMigrationTo returns the first `"migration_to":"..."`.
func ExtractFailureCtxMigrationTo(text string) string {
	return firstSubmatch(failureCtxMigrationToRe, text)
}

// MatchFailureCtxMixedSignal returns true when the failure-context JSON
// contains `"signal":"mixed_uncertain_classification"`.
func MatchFailureCtxMixedSignal(text string) bool {
	return failureCtxMixedSignalRe.MatchString(text)
}

// MatchSummaryMixedPrimarySignal returns true when the RUN_SUMMARY JSON
// contains `"primary_signal":"mixed_uncertain_classification"`.
func MatchSummaryMixedPrimarySignal(text string) bool {
	return summaryMixedPrimarySignalRe.MatchString(text)
}

// MatchFailureCtxPreflightConfig returns true when the failure-context JSON
// has `"classification":"PREFLIGHT_INTERACTIVE_CONFIG"`.
func MatchFailureCtxPreflightConfig(text string) bool {
	return failureCtxPreflightCfgRe.MatchString(text)
}

// MatchPipelineConfigVersionPin returns true when the pipeline.conf body
// contains a `TEKHTON_CONFIG_VERSION=` line at the start of any line.
func MatchPipelineConfigVersionPin(text string) bool {
	return pipelineConfigVersionPinnedRe.MatchString(text)
}

// CountBuildFixReportAttempts returns the number of `^## Attempt ` lines.
func CountBuildFixReportAttempts(text string) int {
	matches := buildFixReportAttemptRe.FindAllStringIndex(text, -1)
	return len(matches)
}

// LastBuildFixProgressLineNoProgress returns true when the LAST
// `^- Progress signal:` line in the text contains "unchanged" or
// "worsened" — mirrors the bash `grep ... | tail -1` semantics.
func LastBuildFixProgressLineNoProgress(text string) bool {
	all := buildFixReportProgressLineRe.FindAllString(text, -1)
	if len(all) == 0 {
		return false
	}
	last := all[len(all)-1]
	return buildFixProgressNoProgressRe.MatchString(last)
}

func firstSubmatch(re *regexp.Regexp, text string) string {
	m := re.FindStringSubmatch(text)
	if len(m) < 2 {
		return ""
	}
	return m[1]
}

// ScanFiles walks the supplied root, opening each file whose name passes
// `accept`, reading its body, and returning true at the first file whose
// body matches `match`. Walk errors are ignored (best-effort scan).
//
// The accept predicate lets diagnose rules restrict scans to .log and
// .jsonl files when the rule needs to avoid agent-authored markdown that
// quotes diagnostic markers as documentation. Kept here to give rules a
// regex-free way to do a recursive grep equivalent.
func ScanFiles(root string, accept func(name string) bool, match func(body string) bool) bool {
	return scanFilesImpl(root, accept, match)
}
