package test_audit

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseAuditVerdict_MissingReportIsPASS(t *testing.T) {
	got := ParseAuditVerdict(filepath.Join(t.TempDir(), "does_not_exist.md"))
	if got != VerdictPASS {
		t.Fatalf("missing report should map to PASS, got %v", got)
	}
}

func TestParseAuditVerdict_EmptyPathIsPASS(t *testing.T) {
	if got := ParseAuditVerdict(""); got != VerdictPASS {
		t.Fatalf("empty path should map to PASS, got %v", got)
	}
}

func TestParseAuditVerdict_TableDrive(t *testing.T) {
	cases := []struct {
		name string
		path string
		want Verdict
	}{
		{"pass", "testdata/verdict/pass.md", VerdictPASS},
		{"concerns", "testdata/verdict/concerns.md", VerdictCONCERNS},
		{"needs_work", "testdata/verdict/needs_work.md", VerdictNEEDS_WORK},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ParseAuditVerdict(tc.path)
			if got != tc.want {
				t.Fatalf("%s: want %v, got %v", tc.name, tc.want, got)
			}
		})
	}
}

func TestParseAuditVerdict_CaseInsensitive(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rep.md")
	if err := os.WriteFile(path, []byte("# header\n\nverdict:  needs_work\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := ParseAuditVerdict(path); got != VerdictNEEDS_WORK {
		t.Fatalf("lowercase verdict should still parse to NEEDS_WORK, got %v", got)
	}
}

func TestParseAuditVerdict_GarbageDefaultsToPASS(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rep.md")
	if err := os.WriteFile(path, []byte("This report has no verdict line.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := ParseAuditVerdict(path); got != VerdictPASS {
		t.Fatalf("unparseable should default to PASS, got %v", got)
	}
}

func TestRouteAuditVerdict_PassAndConcernsReturnNil(t *testing.T) {
	dir := t.TempDir()
	nb := filepath.Join(dir, "NON_BLOCKING_LOG.md")
	req := &Request{
		ProjectDir:      dir,
		NonBlockingFile: nb,
	}
	if err := RouteAuditVerdict(context.Background(), req, VerdictPASS); err != nil {
		t.Fatalf("PASS should return nil, got %v", err)
	}
	if err := RouteAuditVerdict(context.Background(), req, VerdictCONCERNS); err != nil {
		t.Fatalf("CONCERNS should return nil, got %v", err)
	}
}

func TestRouteAuditVerdict_NeedsWorkReturnsSentinel(t *testing.T) {
	req := &Request{ProjectDir: t.TempDir()}
	err := RouteAuditVerdict(context.Background(), req, VerdictNEEDS_WORK)
	if err == nil {
		t.Fatal("NEEDS_WORK should return an error")
	}
	if !errors.Is(err, ErrAuditNeedsWork) {
		t.Fatalf("expected ErrAuditNeedsWork, got %v", err)
	}
}

func TestRouteAuditVerdict_ConcernsAppendsToNonBlockingLog(t *testing.T) {
	dir := t.TempDir()
	report := filepath.Join(dir, "TEST_AUDIT_REPORT.md")
	if err := os.WriteFile(report, []byte(
		"# Test Audit Report\n\n"+
			"Verdict: CONCERNS\n\n"+
			"#### COVERAGE — missing nil-pointer test\n"+
			"- `pkg/foo:42` lacks a nil-pointer test\n",
	), 0o644); err != nil {
		t.Fatal(err)
	}
	nb := filepath.Join(dir, "NB.md")
	req := &Request{
		ProjectDir:      dir,
		AuditReportFile: report,
		NonBlockingFile: nb,
	}
	if err := RouteAuditVerdict(context.Background(), req, VerdictCONCERNS); err != nil {
		t.Fatalf("CONCERNS should return nil, got %v", err)
	}
	data, err := os.ReadFile(nb)
	if err != nil {
		t.Fatalf("non-blocking log not written: %v", err)
	}
	if !strings.Contains(string(data), "Test Audit Concerns") {
		t.Fatalf("expected concerns header in non-blocking log, got %q", string(data))
	}
	if !strings.Contains(string(data), "COVERAGE") {
		t.Fatalf("expected COVERAGE finding in non-blocking log, got %q", string(data))
	}
}

func TestVerdictString(t *testing.T) {
	if VerdictPASS.String() != "PASS" {
		t.Fatalf("PASS string: got %q", VerdictPASS.String())
	}
	if VerdictCONCERNS.String() != "CONCERNS" {
		t.Fatalf("CONCERNS string: got %q", VerdictCONCERNS.String())
	}
	if VerdictNEEDS_WORK.String() != "NEEDS_WORK" {
		t.Fatalf("NEEDS_WORK string: got %q", VerdictNEEDS_WORK.String())
	}
	// Unknown values fall back to PASS string (defensive).
	if Verdict(42).String() != "PASS" {
		t.Fatalf("unknown verdict should stringify to PASS")
	}
}
