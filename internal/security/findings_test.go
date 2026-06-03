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
	if !ok {
		t.Fatalf("empty file list must return true (nothing to scan), got false")
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
