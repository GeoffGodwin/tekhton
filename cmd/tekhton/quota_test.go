package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestQuotaStatusCmd_ReportsActiveWhenLogIsEmpty exercises the empty-log
// path: status should print "active" without erroring.
func TestQuotaStatusCmd_ReportsActiveWhenLogIsEmpty(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "CAUSAL_LOG.jsonl")
	if err := os.WriteFile(path, []byte(""), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	var out bytes.Buffer
	cmd := newQuotaStatusCmd()
	cmd.SetOut(&out)
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("status: %v", err)
	}
	if got := strings.TrimSpace(out.String()); got != "active" {
		t.Errorf("status output: %q want active", got)
	}
}

// TestQuotaStatusCmd_ReportsPausedAfterPauseEvent exercises the live-pause
// detection path. A quota_pause line with no following quota_resume should
// produce "paused: <reason>" output.
func TestQuotaStatusCmd_ReportsPausedAfterPauseEvent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "CAUSAL_LOG.jsonl")

	pauseLine := `{"proto":"tekhton.causal.v1","id":"supervisor.001","ts":"2026-01-01T00:00:00Z",` +
		`"type":"quota_pause","stage":"supervisor","detail":"api_rate_limit\tuntil=2026-01-01T01:00:00Z"}` + "\n"
	if err := os.WriteFile(path, []byte(pauseLine), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	var out bytes.Buffer
	cmd := newQuotaStatusCmd()
	cmd.SetOut(&out)
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("status: %v", err)
	}
	if got := strings.TrimSpace(out.String()); got != "paused: api_rate_limit" {
		t.Errorf("status output: %q want 'paused: api_rate_limit'", got)
	}
}

// TestQuotaStatusCmd_ReportsActiveAfterResume covers the pause-then-resume
// transition. A quota_resume after a quota_pause means the supervisor is
// no longer paused.
func TestQuotaStatusCmd_ReportsActiveAfterResume(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "CAUSAL_LOG.jsonl")

	body := `{"proto":"tekhton.causal.v1","id":"supervisor.001","ts":"2026-01-01T00:00:00Z","type":"quota_pause","stage":"supervisor","detail":"api_rate_limit\tuntil=now"}` + "\n" +
		`{"proto":"tekhton.causal.v1","id":"supervisor.002","ts":"2026-01-01T00:01:00Z","type":"quota_resume","stage":"supervisor","detail":"api_rate_limit\tduration=60s"}` + "\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	var out bytes.Buffer
	cmd := newQuotaStatusCmd()
	cmd.SetOut(&out)
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("status: %v", err)
	}
	if got := strings.TrimSpace(out.String()); got != "active" {
		t.Errorf("status output: %q want active", got)
	}
}

// TestQuotaStatusCmd_JSONFlagEmitsParseable verifies --json mode produces
// valid JSON with the expected fields.
func TestQuotaStatusCmd_JSONFlagEmitsParseable(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "CAUSAL_LOG.jsonl")

	pauseLine := `{"proto":"tekhton.causal.v1","id":"supervisor.001","ts":"2026-01-01T00:00:00Z","type":"quota_pause","stage":"supervisor","detail":"api_rate_limit\tuntil=now"}` + "\n"
	if err := os.WriteFile(path, []byte(pauseLine), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	var out bytes.Buffer
	cmd := newQuotaStatusCmd()
	cmd.SetOut(&out)
	cmd.SetArgs([]string{"--path", path, "--json"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("status: %v", err)
	}

	var got quotaStatus
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal %q: %v", out.String(), err)
	}
	if !got.Paused {
		t.Errorf("Paused: false want true")
	}
	if got.Reason != "api_rate_limit" {
		t.Errorf("Reason: %q want api_rate_limit", got.Reason)
	}
	if got.LastEventID != "supervisor.001" {
		t.Errorf("LastEventID: %q want supervisor.001", got.LastEventID)
	}
}

// TestQuotaProbeCmd_RejectsBadKind exercises the parseProbeKind error path.
func TestQuotaProbeCmd_RejectsBadKind(t *testing.T) {
	cmd := newQuotaProbeCmd()
	cmd.SetArgs([]string{"--kind", "bogus"})
	cmd.SetOut(new(bytes.Buffer))
	cmd.SetErr(new(bytes.Buffer))
	err := cmd.Execute()
	if err == nil {
		t.Fatalf("err: nil; want invalid --kind")
	}
	if !strings.Contains(err.Error(), "invalid --kind") {
		t.Errorf("err: %v; want substring 'invalid --kind'", err)
	}
}

// TestParseProbeKind_AllForms covers the dash and underscore variants.
func TestParseProbeKind_AllForms(t *testing.T) {
	cases := []string{"version", "zero-turn", "zero_turn", "fallback", "VERSION"}
	for _, c := range cases {
		t.Run(c, func(t *testing.T) {
			if _, err := parseProbeKind(c); err != nil {
				t.Errorf("parseProbeKind(%q) = %v; want nil", c, err)
			}
		})
	}
}

// TestQuotaStatusCmd_MissingFileReturnsActive covers the os.IsNotExist branch
// inside readQuotaStatus: when the log file does not exist the command should
// print "active" without error (not-found is not an operational error).
func TestQuotaStatusCmd_MissingFileReturnsActive(t *testing.T) {
	dir := t.TempDir()
	nonexistent := filepath.Join(dir, "no_such_file.jsonl")

	var out bytes.Buffer
	cmd := newQuotaStatusCmd()
	cmd.SetOut(&out)
	cmd.SetArgs([]string{"--path", nonexistent})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("status: %v", err)
	}
	if got := strings.TrimSpace(out.String()); got != "active" {
		t.Errorf("status output: %q want active", got)
	}
}

// TestQuotaStatus_Human_PausedWithNoReason covers the Paused=true,
// Reason="" branch of Human() which returns "paused" (no colon-reason suffix).
func TestQuotaStatus_Human_PausedWithNoReason(t *testing.T) {
	st := quotaStatus{Paused: true, Reason: ""}
	got := st.Human()
	if got != "paused" {
		t.Errorf("Human() = %q; want \"paused\"", got)
	}
}
