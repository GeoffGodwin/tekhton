package errors

import (
	"regexp"
	"strings"
)

// AgentClassifyOptions carries the inputs lib/errors.sh::classify_error
// consumed positionally. The Go version uses named fields so callers can
// omit values without juggling empty-string positional args.
type AgentClassifyOptions struct {
	ExitCode    int
	Stderr      string
	LastOutput  string
	FileChanges int
	Turns       int
	HasSummary  bool
}

// AgentClassification is the structured form of the legacy pipe-delimited
// CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE record.
type AgentClassification struct {
	Category    string
	Subcategory string
	Transient   bool
	Message     string
}

// FormatLegacy renders the classification in the V3 wire format.
func (a AgentClassification) FormatLegacy() string {
	t := "false"
	if a.Transient {
		t = "true"
	}
	return a.Category + "|" + a.Subcategory + "|" + t + "|" + a.Message
}

// matchAny reports whether any of the patterns matches s. All patterns are
// pre-compiled at init() time.
func matchAny(s string, res ...*regexp.Regexp) bool {
	for _, re := range res {
		if re.MatchString(s) {
			return true
		}
	}
	return false
}

// Pattern set ported from classify_error in lib/errors.sh — we keep the
// tests in tests/test_errors.sh as the parity oracle.
var (
	reAPIErrorJSON   = regexp.MustCompile(`(?i)"type"[[:space:]]*:[[:space:]]*"error"`)
	reAPIErrorObj    = regexp.MustCompile(`(?i)"error"[[:space:]]*:[[:space:]]*\{`)
	reAPIRateLimit   = regexp.MustCompile(`(?i)rate_limit`)
	reAPIRateLimitS  = regexp.MustCompile(`(?i)rate.limit`)
	reHTTP429        = regexp.MustCompile(`(?i)"status"[[:space:]]*:[[:space:]]*429`)
	reHTTP529        = regexp.MustCompile(`(?i)"status"[[:space:]]*:[[:space:]]*529`)
	reOverloaded     = regexp.MustCompile(`(?i)overloaded`)
	reOverloadedErr  = regexp.MustCompile(`(?i)overloaded_error`)
	reServerError    = regexp.MustCompile(`(?i)server_error`)
	reHTTP5xx        = regexp.MustCompile(`(?i)"status"[[:space:]]*:[[:space:]]*50[023]`)
	reAuthError      = regexp.MustCompile(`(?i)authentication_error`)
	reInvalidAPIKey  = regexp.MustCompile(`(?i)invalid.api.key`)
	reInvalidXAPIKey = regexp.MustCompile(`(?i)invalid.*x-api-key`)
	reConnTimedOut   = regexp.MustCompile(`(?i)connection.*timed?[[:space:]]*out`)
	reETimedout      = regexp.MustCompile(`(?i)ETIMEDOUT`)
	reEConnReset     = regexp.MustCompile(`(?i)ECONNRESET`)
	reReqTimeout     = regexp.MustCompile(`(?i)request.*timeout`)
	reNoSpace        = regexp.MustCompile(`(?i)No space left on device`)
	reENOSPC         = regexp.MustCompile(`(?i)ENOSPC`)
	reENOTFOUND      = regexp.MustCompile(`(?i)ENOTFOUND`)
	reEAIAGAIN       = regexp.MustCompile(`(?i)EAI_AGAIN`)
	reGetAddrInfo    = regexp.MustCompile(`(?i)getaddrinfo.*failed`)
	reDNSFailed      = regexp.MustCompile(`(?i)DNS.*resolution.*failed`)
	reNetUnreach     = regexp.MustCompile(`(?i)network.*unreachable`)
	reCmdNotFound    = regexp.MustCompile(`(?i)command not found`)
	reNotInPath      = regexp.MustCompile(`(?i)not found in PATH`)
	reReqCmdNotFound = regexp.MustCompile(`(?i)Required command not found`)
	rePermDenied     = regexp.MustCompile(`(?i)Permission denied`)
	reEACCES         = regexp.MustCompile(`(?i)EACCES`)
	rePipelineState  = regexp.MustCompile(`(?i)PIPELINE_STATE`)
	reCorruptInvalid = regexp.MustCompile(`(?i)corrupt|invalid|malformed`)
	rePipelineConf   = regexp.MustCompile(`(?i)pipeline\.conf`)
	reConfigReject   = regexp.MustCompile(`(?i)REJECTED|missing required|not found`)
	reTemplate       = regexp.MustCompile(`(?i)render_prompt|template.*not found|\.prompt\.md`)
	reExpectedFile   = regexp.MustCompile(`(?i)Expected output file.*not found`)
	reReqFileMissing = regexp.MustCompile(`(?i)Required.*file.*not found`)
	reAnthropicHint  = regexp.MustCompile(`(?i)anthropic|claude|api\.anthropic`)
)

// ClassifyAgent ports lib/errors.sh::classify_error. The decision tree mirrors
// the bash version one-for-one so existing tests/test_errors.sh remains the
// authoritative parity oracle.
func ClassifyAgent(opts AgentClassifyOptions) AgentClassification {
	const cap65k = 65536
	stderr := capHead(opts.Stderr, cap65k)
	output := capHead(opts.LastOutput, cap65k)
	combined := stderr + output

	// UPSTREAM block (priority).
	if reAPIErrorJSON.MatchString(combined) && reAPIRateLimit.MatchString(combined) {
		return AgentClassification{"UPSTREAM", "api_rate_limit", true, "API rate limit (HTTP 429)"}
	}
	if reHTTP429.MatchString(combined) || reAPIRateLimitS.MatchString(combined) {
		return AgentClassification{"UPSTREAM", "api_rate_limit", true, "API rate limit (HTTP 429)"}
	}
	if reAPIErrorJSON.MatchString(combined) && reOverloaded.MatchString(combined) {
		return AgentClassification{"UPSTREAM", "api_overloaded", true, "API overloaded (HTTP 529)"}
	}
	if reHTTP529.MatchString(combined) || reOverloadedErr.MatchString(combined) {
		return AgentClassification{"UPSTREAM", "api_overloaded", true, "API overloaded (HTTP 529)"}
	}
	if reAPIErrorJSON.MatchString(combined) && reServerError.MatchString(combined) {
		return AgentClassification{"UPSTREAM", "api_500", true, "API server error (HTTP 500)"}
	}
	if reHTTP5xx.MatchString(combined) {
		return AgentClassification{"UPSTREAM", "api_500", true, "API server error (HTTP 5xx)"}
	}
	if matchAny(combined, reAuthError, reInvalidAPIKey, reInvalidXAPIKey) {
		return AgentClassification{"UPSTREAM", "api_auth", false, "API authentication error"}
	}
	if matchAny(combined, reConnTimedOut, reETimedout, reEConnReset, reReqTimeout) {
		return AgentClassification{"UPSTREAM", "api_timeout", true, "API connection timeout"}
	}
	if reAPIErrorJSON.MatchString(combined) && reAPIErrorObj.MatchString(combined) {
		return AgentClassification{"UPSTREAM", "api_unknown", true, "Unrecognized API error"}
	}

	// ENVIRONMENT block.
	if opts.ExitCode == 137 || opts.ExitCode == 9 {
		return AgentClassification{"ENVIRONMENT", "oom", true, "Process killed (signal 9) — likely OOM"}
	}
	if matchAny(combined, reNoSpace, reENOSPC) {
		return AgentClassification{"ENVIRONMENT", "disk_full", false, "No space left on device"}
	}
	if matchAny(combined, reENOTFOUND, reEAIAGAIN, reGetAddrInfo, reDNSFailed, reNetUnreach) {
		return AgentClassification{"ENVIRONMENT", "network", true, "Network connectivity failure"}
	}
	if matchAny(combined, reCmdNotFound, reNotInPath, reReqCmdNotFound) {
		return AgentClassification{"ENVIRONMENT", "missing_dep", false, "Required command not found"}
	}
	if matchAny(combined, rePermDenied, reEACCES) {
		return AgentClassification{"ENVIRONMENT", "permissions", false, "Permission denied"}
	}

	// PIPELINE block.
	if rePipelineState.MatchString(combined) && reCorruptInvalid.MatchString(combined) {
		return AgentClassification{"PIPELINE", "state_corrupt", false, "Pipeline state file is corrupt or invalid"}
	}
	if rePipelineConf.MatchString(combined) && reConfigReject.MatchString(combined) {
		return AgentClassification{"PIPELINE", "config_error", false, "Pipeline configuration error"}
	}
	if reTemplate.MatchString(combined) {
		return AgentClassification{"PIPELINE", "template_error", false, "Prompt template render failure"}
	}
	if matchAny(combined, reExpectedFile, reReqFileMissing) {
		return AgentClassification{"PIPELINE", "missing_file", false, "Required artifact file not found"}
	}

	// AGENT_SCOPE block.
	if opts.ExitCode == 124 {
		if opts.Turns == 0 {
			return AgentClassification{"AGENT_SCOPE", "null_activity_timeout", false, "Agent never produced output before activity timeout (likely upstream quota/auth)"}
		}
		return AgentClassification{"AGENT_SCOPE", "activity_timeout", false, "Agent activity timeout after " + itoa(opts.Turns) + " turn(s) — went silent mid-run"}
	}

	// Null run: low turns + no file changes (non-zero exit, or zero turns regardless).
	if opts.Turns <= 2 && opts.FileChanges == 0 &&
		(opts.ExitCode != 0 || opts.Turns == 0) {
		return AgentClassification{"AGENT_SCOPE", "null_run", false, "Agent completed without meaningful work"}
	}
	if opts.ExitCode != 0 && opts.Turns > 2 {
		return AgentClassification{"AGENT_SCOPE", "max_turns", false, "Agent exhausted turn budget (" + itoa(opts.Turns) + " turns used)"}
	}
	if opts.ExitCode == 0 && opts.Turns > 0 && !opts.HasSummary {
		return AgentClassification{"AGENT_SCOPE", "no_summary", false, "Agent completed but produced no summary"}
	}

	// Fallback.
	if opts.ExitCode != 0 {
		if opts.ExitCode == 139 {
			return AgentClassification{"ENVIRONMENT", "env_unknown", false, "Process crashed (SIGSEGV, exit 139)"}
		}
		if reAnthropicHint.MatchString(combined) {
			return AgentClassification{"UPSTREAM", "api_unknown", true, "Unrecognized API-related error (exit " + itoa(opts.ExitCode) + ")"}
		}
		return AgentClassification{"PIPELINE", "internal", false, "Unexpected error (exit " + itoa(opts.ExitCode) + ")"}
	}
	return AgentClassification{"AGENT_SCOPE", "scope_unknown", false, "No error detected (exit 0)"}
}

// IsTransient ports lib/errors_helpers.sh::is_transient. Returns true for
// retryable error classes.
func IsTransient(category, subcategory string) bool {
	switch category {
	case "UPSTREAM":
		return subcategory != "api_auth"
	case "ENVIRONMENT":
		switch subcategory {
		case "network", "oom":
			return true
		}
		return false
	}
	return false
}

func capHead(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// itoa avoids importing strconv just for this helper.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := false
	if n < 0 {
		neg = true
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

// IsKnownAgentSubcategory reports whether (category, subcategory) is one of
// the canonical pairs the classifier emits. Useful for table-driven tests.
func IsKnownAgentSubcategory(category, subcategory string) bool {
	for _, c := range knownAgentSubcategories[category] {
		if c == subcategory {
			return true
		}
	}
	return false
}

var knownAgentSubcategories = map[string][]string{
	"UPSTREAM":    {"api_500", "api_rate_limit", "api_overloaded", "api_auth", "api_timeout", "api_unknown"},
	"ENVIRONMENT": {"disk_full", "network", "missing_dep", "permissions", "oom", "env_unknown", "env_setup", "service_dep", "toolchain", "resource", "test_infra"},
	"AGENT_SCOPE": {"null_run", "max_turns", "activity_timeout", "null_activity_timeout", "no_summary", "scope_unknown"},
	"PIPELINE":    {"state_corrupt", "config_error", "missing_file", "template_error", "internal"},
}

// trimAll strips whitespace and surrounding quotes — small helpers exposed for
// the diagnose CLI shim.
func trimAll(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && (s[0] == '"' && s[len(s)-1] == '"' || s[0] == '\'' && s[len(s)-1] == '\'') {
		s = s[1 : len(s)-1]
	}
	return s
}
