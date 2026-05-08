package errors_test

import (
	"strings"
	"testing"

	terr "github.com/geoffgodwin/tekhton/internal/errors"
)

func TestIsNonDiagnosticLine_AllowList(t *testing.T) {
	t.Parallel()
	keep := []string{
		"npm warn: TS2304: Cannot find name 'foo'",
		"[1/8] timeout while connecting",
		"Serving HTML report at http://h: error TS2345",
		"ECONNREFUSED 127.0.0.1:5432",
		"Test failed: assertion mismatch",
	}
	for _, l := range keep {
		if terr.IsNonDiagnosticLine(l) {
			t.Errorf("allow-list precedence: %q must NOT be filtered", l)
		}
	}
	drop := []string{
		"npm warn config production Use --omit=dev instead",
		"Serving HTML report at http://localhost:9323",
		"Press Ctrl+C to quit.",
		"[3/8] Resolving dependencies",
		"    ",
		"",
	}
	for _, l := range drop {
		if !terr.IsNonDiagnosticLine(l) {
			t.Errorf("deny-list: %q must be filtered", l)
		}
	}
}

func TestHasExplicitCodeErrors(t *testing.T) {
	t.Parallel()
	if !terr.HasExplicitCodeErrors("error TS2304: Cannot find name 'foo'") {
		t.Error("TS2304 should be code")
	}
	if terr.HasExplicitCodeErrors("ECONNREFUSED 127.0.0.1:5432") {
		t.Error("ECONNREFUSED is service_dep, not code")
	}
	if terr.HasExplicitCodeErrors("some completely unknown blob with no recognized signature") {
		t.Error("unmatched lines must not count as code (M127 fix)")
	}
	if terr.HasExplicitCodeErrors("") {
		t.Error("empty input must return false")
	}
}

func TestClassifyRoutingDecision(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name, in, want string
	}{
		{"empty", "", terr.RouteUnknownOnly},
		{"pure code", "error TS2304: Cannot find name 'foo'", terr.RouteCodeDominant},
		{"code+noise", "error TS2345: Type mismatch\nerror TS2304: Cannot find name 'bar'\nnpm warn deprecated foo\nsome unmatched banner\n[1/8] running", terr.RouteCodeDominant},
		{"pure multi-noncode", "ECONNREFUSED 127.0.0.1:5432\nECONNREFUSED 127.0.0.1:6379\nCannot find module 'express'", terr.RouteNoncodeDominant},
		{"mixed_uncertain", "error TS2304: Cannot find name 'foo'\nECONNREFUSED 127.0.0.1:5432\nECONNREFUSED 127.0.0.1:6379", terr.RouteMixedUncertain},
		{"unknown_only", "completely unrecognised banner one\nanother mystery line\nyet another unknown phrase", terr.RouteUnknownOnly},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := terr.ClassifyRoutingDecision(tc.in)
			if got != tc.want {
				t.Fatalf("input=%q want=%s got=%s", tc.in, tc.want, got)
			}
		})
	}
}

func TestClassifyRoutingDecision_RestrictedVocab(t *testing.T) {
	t.Parallel()
	for _, in := range []string{"", "error TS2345", "ECONNREFUSED 127.0.0.1:5432", "unknown banner"} {
		got := terr.ClassifyRoutingDecision(in)
		switch got {
		case terr.RouteCodeDominant, terr.RouteNoncodeDominant, terr.RouteMixedUncertain, terr.RouteUnknownOnly:
		default:
			t.Errorf("token %q not in restricted vocabulary for input %q", got, in)
		}
	}
}

func TestClassifyWithStats_StatsRecord(t *testing.T) {
	t.Parallel()
	stats := terr.ClassifyWithStats("ECONNREFUSED 127.0.0.1:5432")
	if len(stats) != 1 {
		t.Fatalf("want 1 record, got %d", len(stats))
	}
	if stats[0].Category != "service_dep" {
		t.Errorf("want service_dep, got %s", stats[0].Category)
	}

	stats = terr.ClassifyWithStats("ECONNREFUSED 127.0.0.1:5432\nsome unknown line with no signature\nanother unknown phrase here")
	if len(stats) != 1 {
		t.Fatalf("expected 1 record (service_dep), got %d", len(stats))
	}
	if stats[0].UnmatchedLines != 2 {
		t.Errorf("want unmatched=2, got %d", stats[0].UnmatchedLines)
	}
	for _, r := range stats {
		if r.Category == "code" {
			t.Errorf("M127 invariant: stats must not emit code record for unmatched, got %+v", r)
		}
	}
}

func TestClassifyWithStats_LegacyFormat(t *testing.T) {
	t.Parallel()
	stats := terr.ClassifyWithStats("ECONNREFUSED 127.0.0.1:5432")
	line := stats[0].FormatStatsLegacy()
	if got, want := strings.Count(line, "|"), 7; got != want {
		t.Fatalf("legacy format must have 8 fields (7 pipes), got %d in %q", got, line)
	}
}

func TestHasOnlyNoncodeErrors_BiflShape(t *testing.T) {
	t.Parallel()
	bifl := "ECONNREFUSED 127.0.0.1:5432\nsome unrecognized banner\nanother unknown phrase"
	if !terr.HasOnlyNoncodeErrors(bifl) {
		t.Error("M127 fix: env-only failure plus noise should bypass (return true)")
	}
}

func TestHasOnlyNoncodeErrors_EmptyAndCode(t *testing.T) {
	t.Parallel()
	if terr.HasOnlyNoncodeErrors("") {
		t.Error("empty input must return false")
	}
	if terr.HasOnlyNoncodeErrors("error TS2304: Cannot find name 'foo'") {
		t.Error("input with explicit code errors must return false")
	}
}

func TestFilterCodeErrors(t *testing.T) {
	t.Parallel()
	in := "error TS2345: Type mismatch\nECONNREFUSED 127.0.0.1:5432\nerror TS2304: Cannot find name 'bar'"
	out := terr.FilterCodeErrors(in)
	if !strings.Contains(out, "## Code Errors to Fix") {
		t.Errorf("want code-errors header in:\n%s", out)
	}
	if !strings.Contains(out, "## Already Handled (not code errors)") {
		t.Errorf("want noncode header in:\n%s", out)
	}
	if !strings.Contains(out, "service_dep") {
		t.Errorf("want service_dep summary in:\n%s", out)
	}
}

func TestAnnotateBuildErrors(t *testing.T) {
	t.Parallel()
	out := terr.AnnotateBuildErrors("error TS2304: foo\nECONNREFUSED 127.0.0.1:5432", "compile", "2026-05-07 00:00:00")
	if !strings.HasPrefix(out, "# Build Errors — 2026-05-07 00:00:00\n") {
		t.Errorf("missing header: %s", out)
	}
	if !strings.Contains(out, "## Stage\ncompile\n") {
		t.Errorf("missing stage: %s", out)
	}
	if !strings.Contains(out, "## Error Classification") {
		t.Errorf("missing classification: %s", out)
	}
}

func TestPatterns_Indexed(t *testing.T) {
	t.Parallel()
	if len(terr.Patterns()) == 0 {
		t.Fatal("registry empty")
	}
}

func TestClassifyAll_Empty(t *testing.T) {
	t.Parallel()
	if got := terr.ClassifyAll(""); got != nil {
		t.Fatalf("empty input must return nil, got %v", got)
	}
}

func TestClassifyAll_UnmatchedSentinel(t *testing.T) {
	t.Parallel()
	// Unmatched lines that are not empty fold into the "Unclassified build error"
	// sentinel record. ClassifyAll (unlike ClassifyWithStats) does NOT call
	// IsNonDiagnosticLine — every non-empty line that fails matchPattern is
	// treated as unmatched.
	in := "completely unrecognised banner one\nanother mystery line"
	recs := terr.ClassifyAll(in)
	if len(recs) != 1 {
		t.Fatalf("want 1 unmatched sentinel record, got %d: %+v", len(recs), recs)
	}
	r := recs[0]
	if r.Category != "code" {
		t.Errorf("sentinel category: want code, got %s", r.Category)
	}
	if r.Diagnosis != "Unclassified build error" {
		t.Errorf("sentinel diagnosis: want 'Unclassified build error', got %q", r.Diagnosis)
	}
	if r.MatchCount != 2 {
		t.Errorf("sentinel count: want 2 (two unmatched lines), got %d", r.MatchCount)
	}
}

func TestClassifyAll_MixedMatchedAndUnmatched(t *testing.T) {
	t.Parallel()
	// A matched pattern and an unmatched line both appear → two records.
	in := "error TS2304: Cannot find name 'foo'\ncompletely unrecognised banner one"
	recs := terr.ClassifyAll(in)
	found := map[string]bool{}
	for _, r := range recs {
		found[r.Diagnosis] = true
	}
	if !found["Unclassified build error"] {
		t.Error("want Unclassified build error record for unmatched line")
	}
	if len(recs) != 2 {
		t.Fatalf("want 2 records (one matched, one sentinel), got %d: %+v", len(recs), recs)
	}
}

func TestClassifyAll_FormatAllLegacy(t *testing.T) {
	t.Parallel()
	recs := terr.ClassifyAll("ECONNREFUSED 127.0.0.1:5432")
	if len(recs) != 1 {
		t.Fatalf("want 1 record, got %d", len(recs))
	}
	line := recs[0].FormatAllLegacy()
	if got, want := strings.Count(line, "|"), 3; got != want {
		t.Fatalf("FormatAllLegacy must have 4 fields (3 pipes), got %d in %q", got, line)
	}
	if !strings.HasPrefix(line, "service_dep|") {
		t.Errorf("FormatAllLegacy: want service_dep prefix, got %q", line)
	}
}

func TestClassifyRoutingDecision_NoncodeJustBelowThreshold(t *testing.T) {
	t.Parallel()
	// 2 noncode + 2 unmatched = total 4; 2/4 = 50% < 60% threshold → unknown_only.
	in := "ECONNREFUSED 127.0.0.1:5432\nCannot find module 'express'\nunknown line alpha\nunknown line beta"
	got := terr.ClassifyRoutingDecision(in)
	if got != terr.RouteUnknownOnly {
		t.Errorf("50%% noncode (below 60%% threshold) must route to unknown_only, got %q", got)
	}
}

func TestClassifyRoutingDecision_NoncodeAtThreshold(t *testing.T) {
	t.Parallel()
	// 3 noncode + 2 unmatched = total 5; 3/5 = 60% exactly → noncode_dominant.
	in := "ECONNREFUSED 127.0.0.1:5432\nCannot find module 'express'\nECONNREFUSED 127.0.0.1:6379\nunknown line alpha\nunknown line beta"
	got := terr.ClassifyRoutingDecision(in)
	if got != terr.RouteNoncodeDominant {
		t.Errorf("60%% noncode (at threshold) must route to noncode_dominant, got %q", got)
	}
}

// TestIsNonDiagnosticLine_PnpmYarnNotice verifies that the pnpm notice and
// yarn notice entries added in m17 are correctly treated as noise. These
// entries mirror the existing npm notice/warn coverage and prevent silent
// regression if the regex is accidentally removed from noiseLineREs.
func TestIsNonDiagnosticLine_PnpmYarnNotice(t *testing.T) {
	t.Parallel()
	cases := []struct {
		line string
		want bool // true = should be filtered (IsNonDiagnosticLine returns true)
		desc string
	}{
		// Happy-path: pnpm notice lines are filtered.
		{"pnpm notice: downloading some-package", true, "pnpm notice bare"},
		{"pnpm notice cli v9.0.0", true, "pnpm notice no colon"},
		{"  pnpm notice: resolving dependencies", true, "pnpm notice leading spaces"},
		{"PNPM NOTICE: uppercase variant", true, "pnpm notice uppercase"},

		// Happy-path: yarn notice lines are filtered.
		{"yarn notice: xxx", true, "yarn notice with colon"},
		{"yarn notice [1/4] Resolving packages", true, "yarn notice bracket format"},
		{"  yarn notice: some metadata", true, "yarn notice leading spaces"},
		{"YARN NOTICE: uppercase variant", true, "yarn notice uppercase"},

		// Allow-list precedence: failure terms override the noise deny-list.
		// A pnpm/yarn notice that also contains "error" must NOT be filtered.
		{"pnpm notice: error: peer dep resolution failed", false, "pnpm notice + error term"},
		{"yarn notice: TS2304: Cannot find name 'foo'", false, "yarn notice + TS error term"},
		{"pnpm notice: ECONNREFUSED 127.0.0.1:4873", false, "pnpm notice + ECONNREFUSED"},

		// Existing npm warn/notice still filtered (regression guard).
		{"npm notice created a lockfile", true, "npm notice still filtered"},
		{"npm warn deprecated lodash@3.0.0", true, "npm warn still filtered"},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.desc, func(t *testing.T) {
			t.Parallel()
			got := terr.IsNonDiagnosticLine(tc.line)
			if got != tc.want {
				if tc.want {
					t.Errorf("expected %q to be filtered (noise), but IsNonDiagnosticLine returned false", tc.line)
				} else {
					t.Errorf("expected %q NOT to be filtered (allow-list precedence), but IsNonDiagnosticLine returned true", tc.line)
				}
			}
		})
	}
}

// TestIsNonDiagnosticLine_PnpmYarnNotice_ClassifyWithStats verifies the
// end-to-end effect: pnpm/yarn notice lines in a raw build log are excluded
// from ClassifyWithStats totals so they don't inflate the line count or skew
// routing decisions.
func TestIsNonDiagnosticLine_PnpmYarnNotice_ClassifyWithStats(t *testing.T) {
	t.Parallel()
	// Mix: one real code error + several pnpm/yarn notice lines.
	// The noise lines must not appear in stats.TotalLines.
	raw := "error TS2304: Cannot find name 'foo'\n" +
		"pnpm notice: downloading typescript@5.0.0\n" +
		"yarn notice: some progress info\n" +
		"pnpm notice: resolving peer deps\n"

	stats := terr.ClassifyWithStats(raw)
	if len(stats) == 0 {
		t.Fatal("expected at least one record for the code error")
	}
	// Only the TS error line is diagnostic; the three notice lines are noise.
	for _, r := range stats {
		if r.TotalLines != 1 {
			t.Errorf("TotalLines=%d, expected 1 (noise lines must be excluded from totals)", r.TotalLines)
		}
	}
}
