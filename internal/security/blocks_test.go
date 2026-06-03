package security

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestBlocks_Goldens replays the 6 SECURITY_REPORT.md fixtures × 3 blocks
// against the bash-captured baselines under testdata/baselines/. Bash uses
// the default SECURITY_BLOCK_SEVERITY=HIGH for every block call.
func TestBlocks_Goldens(t *testing.T) {
	fixtures := []string{
		"01-empty",
		"02-no-findings-header",
		"03-all-low",
		"04-mixed-fixable",
		"05-malformed-severity",
		"06-truncated-section",
	}
	kinds := []struct {
		name string
		fn   func([]Finding, Severity) string
	}{
		{"fixable", BuildFixableBlock},
		{"unfixable", BuildUnfixableBlock},
		{"notes", BuildNotesBlock},
	}
	for _, fx := range fixtures {
		fs, err := ParseReport(filepath.Join("testdata/reports", fx+".md"))
		if err != nil {
			t.Fatalf("%s: parse err: %v", fx, err)
		}
		for _, k := range kinds {
			want, err := os.ReadFile(filepath.Join("testdata/baselines", fx+"-"+k.name+".txt"))
			if err != nil {
				t.Fatalf("%s-%s: baseline read err: %v", fx, k.name, err)
			}
			got := k.fn(fs, SeverityHigh)
			if got != string(want) {
				t.Errorf("%s-%s mismatch:\n got  %q\n want %q", fx, k.name, got, string(want))
			}
		}
	}
}

func TestBuildFixableBlock_Threshold(t *testing.T) {
	fs := []Finding{
		{SeverityCritical, "yes", "Critical fixable"},
		{SeverityHigh, "yes", "High fixable"},
		{SeverityMedium, "yes", "Medium fixable"},
		{SeverityLow, "yes", "Low fixable"},
	}
	// Threshold CRITICAL: only CRITICAL row included.
	got := BuildFixableBlock(fs, SeverityCritical)
	if !strings.Contains(got, "[CRITICAL]") || strings.Contains(got, "[HIGH]") {
		t.Errorf("threshold CRITICAL output unexpected: %q", got)
	}
	// Threshold MEDIUM: CRITICAL+HIGH+MEDIUM included.
	got = BuildFixableBlock(fs, SeverityMedium)
	for _, want := range []string{"[CRITICAL]", "[HIGH]", "[MEDIUM]"} {
		if !strings.Contains(got, want) {
			t.Errorf("threshold MEDIUM missing %s: %q", want, got)
		}
	}
	if strings.Contains(got, "[LOW]") {
		t.Errorf("threshold MEDIUM should exclude LOW: %q", got)
	}
}

func TestBuildUnfixableBlock_ExcludesYes(t *testing.T) {
	fs := []Finding{
		{SeverityHigh, "yes", "the-yes-row"},
		{SeverityHigh, "no", "the-no-row"},
		{SeverityHigh, "unknown", "the-unknown-row"},
	}
	got := BuildUnfixableBlock(fs, SeverityHigh)
	if strings.Contains(got, "the-yes-row") {
		t.Errorf("unfixable block must exclude fixable:yes rows: %q", got)
	}
	for _, want := range []string{"the-no-row", "the-unknown-row"} {
		if !strings.Contains(got, want) {
			t.Errorf("unfixable block missing %s: %q", want, got)
		}
	}
}

func TestBuildNotesBlock_OnlyBelowThreshold(t *testing.T) {
	fs := []Finding{
		{SeverityHigh, "yes", "above threshold"},
		{SeverityMedium, "yes", "below threshold m"},
		{SeverityLow, "no", "below threshold l"},
	}
	got := BuildNotesBlock(fs, SeverityHigh)
	if strings.Contains(got, "above threshold") {
		t.Errorf("notes block must exclude >= threshold rows: %q", got)
	}
	for _, want := range []string{"below threshold m", "below threshold l"} {
		if !strings.Contains(got, want) {
			t.Errorf("notes block missing %s: %q", want, got)
		}
	}
}

func TestHasBlocking(t *testing.T) {
	if HasBlocking(nil, SeverityHigh) {
		t.Errorf("HasBlocking(nil, HIGH) = true, want false")
	}
	fs := []Finding{{SeverityMedium, "yes", "m"}, {SeverityLow, "no", "l"}}
	if HasBlocking(fs, SeverityHigh) {
		t.Errorf("HasBlocking with only M/L vs HIGH = true, want false")
	}
	fs = append(fs, Finding{SeverityHigh, "no", "h"})
	if !HasBlocking(fs, SeverityHigh) {
		t.Errorf("HasBlocking with HIGH vs HIGH = false, want true")
	}
}
