// Package security holds the Go port of the bash security-stage helpers.
// m35.1 ports the severity classifier, finding parser, block builders, and
// escalation writer. The bash stage (stages/security.sh) continues to call
// these helpers through a thin shim (lib/security_helpers.sh) until m35.2
// ports the stage itself.
package security

// Severity is the bash-format severity token from a SECURITY_REPORT.md row.
// Empty string represents an unknown / unrecognized severity — Rank returns 0
// for it, mirroring the bash `${severity_rank[$severity]:-0}` fallback.
type Severity string

const (
	SeverityCritical Severity = "CRITICAL"
	SeverityHigh     Severity = "HIGH"
	SeverityMedium   Severity = "MEDIUM"
	SeverityLow      Severity = "LOW"
)

// severityRank mirrors the bash associative array at
// lib/security_helpers.sh:118. Unknown severities map to 0.
var severityRank = map[Severity]int{
	SeverityCritical: 4,
	SeverityHigh:     3,
	SeverityMedium:   2,
	SeverityLow:      1,
}

// Rank returns the ordering value for s. Unknown severities (including the
// empty string) return 0 — matches the bash `:-0` fallback.
func Rank(s Severity) int { return severityRank[s] }

// MeetsThreshold reports whether s is at least threshold. Mirrors
// _severity_meets_threshold: `[[ "$sev_val" -ge "$thr_val" ]]`. Unknown
// values rank as 0, so unknown threshold is met by any severity (including
// unknown), and an unknown severity fails any LOW-or-stricter threshold.
func MeetsThreshold(s, threshold Severity) bool {
	return Rank(s) >= Rank(threshold)
}
