package security

import "strings"

// BuildFixableBlock returns findings >= threshold AND Fixable == "yes" as a
// newline-joined list of `- [SEV] desc\n` rows. Empty string when no rows
// match. Mirrors lib/security_helpers.sh::_build_fixable_block.
func BuildFixableBlock(fs []Finding, threshold Severity) string {
	var b strings.Builder
	for _, f := range fs {
		if MeetsThreshold(f.Severity, threshold) && f.Fixable == "yes" {
			writeRow(&b, f)
		}
	}
	return b.String()
}

// BuildUnfixableBlock returns findings >= threshold AND Fixable != "yes".
// Mirrors lib/security_helpers.sh::_build_unfixable_block.
func BuildUnfixableBlock(fs []Finding, threshold Severity) string {
	var b strings.Builder
	for _, f := range fs {
		if MeetsThreshold(f.Severity, threshold) && f.Fixable != "yes" {
			writeRow(&b, f)
		}
	}
	return b.String()
}

// BuildNotesBlock returns findings < threshold. Mirrors
// lib/security_helpers.sh::_build_notes_block.
func BuildNotesBlock(fs []Finding, threshold Severity) string {
	var b strings.Builder
	for _, f := range fs {
		if !MeetsThreshold(f.Severity, threshold) {
			writeRow(&b, f)
		}
	}
	return b.String()
}

// HasBlocking reports whether any Finding meets or exceeds threshold.
// Mirrors lib/security_helpers.sh::_has_blocking_findings.
func HasBlocking(fs []Finding, threshold Severity) bool {
	for _, f := range fs {
		if MeetsThreshold(f.Severity, threshold) {
			return true
		}
	}
	return false
}

func writeRow(b *strings.Builder, f Finding) {
	b.WriteString("- [")
	b.WriteString(string(f.Severity))
	b.WriteString("] ")
	b.WriteString(f.Description)
	b.WriteByte('\n')
}
