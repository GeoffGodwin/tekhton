// dashboard_parse_test.go — smoke tests for `tekhton dashboard parse` arms.

package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDashboardParseSecurity_Smoke(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "sec.md")
	body := `# Security Review

## Findings
- Severity: HIGH (A01) — exposure
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := newDashboardCmd()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetArgs([]string{"parse", "security", path})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("execute: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("output is not JSON: %v\nbody: %s", err, out.String())
	}
	findings, ok := got["findings"].([]any)
	if !ok || len(findings) != 1 {
		t.Fatalf("expected 1 finding, got %v", got)
	}
}

func TestDashboardParseRuns_Smoke(t *testing.T) {
	tmp := t.TempDir()
	mfile := filepath.Join(tmp, "metrics.jsonl")
	body := `{"timestamp":"2026-04-02T10:00:00Z","task":"t1","task_type":"feature","total_turns":5,"total_time_s":60,"coder_turns":5,"outcome":"success"}
`
	if err := os.WriteFile(mfile, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := newDashboardCmd()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetArgs([]string{"parse", "runs", "--metrics", mfile, "--depth", "10"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("execute: %v", err)
	}
	if !strings.HasPrefix(strings.TrimSpace(out.String()), "[") {
		t.Errorf("expected JSON array, got: %s", out.String())
	}
}

func TestDashboardParseIntake_Smoke(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "intake.md")
	if err := os.WriteFile(path, []byte("## Verdict: PASS\n## Confidence: 80\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := newDashboardCmd()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetArgs([]string{"parse", "intake", path})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("execute: %v", err)
	}
	if !strings.Contains(out.String(), `"verdict":"PASS"`) {
		t.Errorf("missing verdict: %s", out.String())
	}
	if !strings.Contains(out.String(), `"confidence":80`) {
		t.Errorf("missing confidence: %s", out.String())
	}
}
