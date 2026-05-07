package errors

import "regexp"

// Redact strips sensitive patterns from text while preserving Anthropic
// request IDs (req_…). Mirrors lib/errors_helpers.sh::redact_sensitive.
//
// The bash version used a temporary placeholder around req_ matches so the
// later x-api-key/Authorization regexes wouldn't eat them. The Go version
// uses ordered substitutions and skips the placeholder dance: req_ patterns
// are matched first and bracketed in a way the later substitutions ignore.
func Redact(input string) string {
	// Anthropic request IDs (req_ + ≥8 alnum/_-) → no-op replacement that
	// rewrites them back literally. This isn't a placeholder dance — it
	// simply ensures req_ matches are accepted before the other rules run.
	out := input
	out = redactReqIDPreserveRE.ReplaceAllString(out, "${1}")

	// x-api-key: header → x-api-key: [REDACTED]
	out = redactXAPIKeyRE.ReplaceAllString(out, "x-api-key: [REDACTED]")
	// Authorization: header → Authorization: [REDACTED]
	out = redactAuthHeaderRE.ReplaceAllString(out, "Authorization: [REDACTED]")
	// sk-ant-… literal API keys
	out = redactSKAntRE.ReplaceAllString(out, "[REDACTED_API_KEY]")
	// ANTHROPIC_API_KEY=value (no spaces in value)
	out = redactAnthropicEnvRE.ReplaceAllString(out, "ANTHROPIC_API_KEY=[REDACTED]")
	// api_key=value or api-key=value (no spaces in value)
	out = redactAPIKeyAssignRE.ReplaceAllString(out, "api_key=[REDACTED]")
	// Bearer tokens
	out = redactBearerRE.ReplaceAllString(out, "bearer [REDACTED]")
	return out
}

// Pattern set ported one-for-one from the sed pipeline in
// lib/errors_helpers.sh::redact_sensitive. Each regex is anchored to behave
// identically to GNU sed -E on a single-line input.
var (
	redactReqIDPreserveRE = regexp.MustCompile(`(req_[A-Za-z0-9_-]{8,})`)
	redactXAPIKeyRE       = regexp.MustCompile(`(?i)x-api-key[[:space:]]*:[[:space:]]*[^\r\n]*`)
	redactAuthHeaderRE    = regexp.MustCompile(`(?i)Authorization[[:space:]]*:[[:space:]]*[^\r\n]*`)
	redactSKAntRE         = regexp.MustCompile(`sk-ant-[A-Za-z0-9_-]*`)
	redactAnthropicEnvRE  = regexp.MustCompile(`ANTHROPIC_API_KEY=[^ \r\n]*`)
	// Case-sensitive on purpose — the V3 sed pipeline used a case-sensitive
	// pattern, so ANTHROPIC_API_KEY=... is left alone here (the env-var rule
	// above redacts it first; this rule must not lowercase the literal text
	// the env-var rule already produced).
	redactAPIKeyAssignRE = regexp.MustCompile(`api[_-]key[[:space:]]*=[[:space:]]*[^ \r\n]*`)
	redactBearerRE       = regexp.MustCompile(`(?i)Bearer [A-Za-z0-9_.-]*`)
)
