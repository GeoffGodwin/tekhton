package security

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestParseReport_Missing(t *testing.T) {
	got, err := ParseReport(filepath.Join(t.TempDir(), "does-not-exist.md"))
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got != nil {
		t.Fatalf("got %v, want nil for missing file", got)
	}
}

func TestParseReport_Fixtures(t *testing.T) {
	cases := []struct {
		fixture string
		want    []Finding
	}{
		{"01-empty.md", nil},
		{"02-no-findings-header.md", nil},
		{"03-all-low.md", []Finding{
			{SeverityLow, "yes", "[fixable:yes] Hardcoded debug flag in auth handler"},
			{SeverityLow, "no", "[fixable:no] Cookie missing Secure attribute"},
			{SeverityLow, "unknown", "[fixable:unknown] Log line includes username"},
		}},
		{"04-mixed-fixable.md", []Finding{
			{SeverityCritical, "yes", "[fixable:yes] Hardcoded API token in config loader"},
			{SeverityHigh, "no", "[fixable:no] Outdated openssl dependency requires upstream patch"},
			{SeverityMedium, "yes", "[fixable:yes] Input validation missing on /api/users"},
			{SeverityLow, "unknown", "[fixable:unknown] Verbose error response includes stack trace"},
		}},
		{"05-malformed-severity.md", []Finding{
			{SeverityHigh, "no", "[fixable:no] Genuine high-severity finding"},
		}},
		{"06-truncated-section.md", nil},
	}
	for _, c := range cases {
		got, err := ParseReport(filepath.Join("testdata/reports", c.fixture))
		if err != nil {
			t.Fatalf("%s: unexpected err: %v", c.fixture, err)
		}
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s:\n got  %#v\n want %#v", c.fixture, got, c.want)
		}
	}
}

func TestParseReport_DefaultsFixableToUnknown(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "no-fixable.md")
	body := "# Report\n\n## Findings\n- [HIGH] Missing fixable token entirely\n\n## Summary\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ParseReport(path)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(got) != 1 || got[0].Fixable != "unknown" {
		t.Fatalf("expected one finding with Fixable=\"unknown\", got %#v", got)
	}
}

func TestIsDocsOnly_MissingSummary(t *testing.T) {
	ok, err := IsDocsOnly(filepath.Join(t.TempDir(), "does-not-exist.md"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if ok {
		t.Fatalf("missing summary must return false (scan anyway), got true")
	}
}

// TestIsDocsOnly_EmptyFileList — m49 flipped the empty-list default from
// (true, nil) to (false, nil). The fail-closed semantic is "scan when
// uncertain": an empty extracted list means the extractor couldn't classify
// the changeset, and a silent skip is the wrong default for a security gate.
func TestIsDocsOnly_EmptyFileList(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "summary.md")
	if err := os.WriteFile(path, []byte("# Coder Summary\n\n## Files Modified\nNone\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	ok, err := IsDocsOnly(path)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if ok {
		t.Fatalf("m49: empty file list must return false (fail-closed — scan anyway), got true")
	}
}

func TestIsDocsOnly_AllDocs(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "summary.md")
	body := `# Coder Summary

## Files Modified
- README.md
- docs/api.json
- assets/logo.png
- config.yaml
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	ok, err := IsDocsOnly(path)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !ok {
		t.Fatalf("expected true for all-docs summary, got false")
	}
}

func TestIsDocsOnly_HasCodeFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "summary.md")
	body := `# Coder Summary

## Files Modified
- README.md
- internal/security/findings.go
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	ok, err := IsDocsOnly(path)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if ok {
		t.Fatalf("expected false when a .go file is present, got true")
	}
}

func TestIsDocsOnly_CoversSecondaryExtensions(t *testing.T) {
	// Smoke-test the full docsExt allowlist: every extension should be
	// recognized as a docs/config/asset file (i.e., IsDocsOnly returns true).
	for ext := range docsExt {
		dir := t.TempDir()
		path := filepath.Join(dir, "summary.md")
		body := "# Coder Summary\n\n## Files Modified\n- asset." + ext + "\n"
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		ok, err := IsDocsOnly(path)
		if err != nil {
			t.Fatalf(".%s: err: %v", ext, err)
		}
		if !ok {
			t.Errorf(".%s: expected true, got false", ext)
		}
	}
}

func TestExtractFilesFromCoderSummary_CleansBackticksAndAnnotations(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "summary.md")
	body := "# Coder Summary\n\n## Files Modified\n- `internal/security/severity.go` — new helper\n- `lib/security_helpers.sh` (rewritten as shim)\n- (fill in as you go)\n- None\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := extractFilesFromCoderSummary(path)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	want := []string{"internal/security/severity.go", "lib/security_helpers.sh"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %#v\nwant %#v", got, want)
	}
}

// TestIsDocsOnly_TableDriven (m49) — covers H2/H3 recognition + fail-closed
// empty-list default against frozen fixtures under testdata/docs_only/.
//
//   - H2 with code file       → false (canonical happy path / regression guard)
//   - H3 with code file       → false (m49 — H3 BEGIN marker recognized)
//   - Mixed H2 parent + H3    → false (m49 — H3 inside section is not END)
//   - No Files section        → false (m49 — fail-closed default)
//   - Section present, empty  → false (m49 — fail-closed default)
//   - H2 with docs only       → true  (canonical skip path / regression guard)
//   - H3 with docs only       → true  (m49 — H3 docs-only still skips)
func TestIsDocsOnly_TableDriven(t *testing.T) {
	cases := []struct {
		fixture string
		want    bool
	}{
		{"h2_with_files.md", false},
		{"h3_with_files.md", false},
		{"h2_h3_mixed.md", false},
		{"no_section.md", false},
		{"empty_section.md", false},
		{"h2_with_docs_only.md", true},
		{"h3_with_docs_only.md", true},
	}
	for _, c := range cases {
		t.Run(c.fixture, func(t *testing.T) {
			path := filepath.Join("testdata", "docs_only", c.fixture)
			got, err := IsDocsOnly(path)
			if err != nil {
				t.Fatalf("IsDocsOnly(%q): %v", c.fixture, err)
			}
			if got != c.want {
				t.Errorf("IsDocsOnly(%q) = %v, want %v", c.fixture, got, c.want)
			}
		})
	}
}

// TestExtractFilesFromCoderSummary_H3MixedExtractsBothSubsections (m49) —
// the mixed H2/H3 fixture must surface bullets from BOTH H3 subsections
// (`### Modified` AND `### Created`). Pre-m49 the second H3 terminated the
// scan because `strings.HasPrefix(line, "##")` matched H3 too.
func TestExtractFilesFromCoderSummary_H3MixedExtractsBothSubsections(t *testing.T) {
	got, err := extractFilesFromCoderSummary(filepath.Join("testdata", "docs_only", "h2_h3_mixed.md"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	want := []string{
		"internal/example/foo.go",
		"internal/example/bar.go",
		"internal/example/foo_test.go",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("mixed H2/H3 fixture\n got  %#v\n want %#v", got, want)
	}
}

// TestExtractFilesFromCoderSummary_H2CanonicalWithH3SubsCollectsBoth covers
// the belt-and-suspenders overlap the reviewer flagged: the canonical H2
// `## Files Modified` fires as the BEGIN marker (sets in=true), then H3
// subheadings `### Modified` and `### Created` appear inside the already-open
// section. The isFilesSectionHeading hits on the H3 lines are no-ops (in is
// already true); isH2Heading correctly ignores them, so the scan stays open
// until the true H2 boundary. Bullets from both H3 subsections must be present.
func TestExtractFilesFromCoderSummary_H2CanonicalWithH3SubsCollectsBoth(t *testing.T) {
	got, err := extractFilesFromCoderSummary(filepath.Join("testdata", "docs_only", "h2_canonical_with_h3_subs.md"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	want := []string{
		"internal/example/alpha.go",
		"internal/example/beta.go",
		"internal/example/beta_test.go",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("H2 canonical + H3 subs fixture\n got  %#v\n want %#v", got, want)
	}
	// Belt-and-suspenders: IsDocsOnly must also return false (code files present).
	ok, err := IsDocsOnly(filepath.Join("testdata", "docs_only", "h2_canonical_with_h3_subs.md"))
	if err != nil {
		t.Fatalf("IsDocsOnly err: %v", err)
	}
	if ok {
		t.Errorf("IsDocsOnly: expected false (code files present), got true")
	}
}
