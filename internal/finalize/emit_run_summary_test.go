package finalize

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestEmitRunSummary_WritesValidJSON(t *testing.T) {
	clearSummaryEnv(t)
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	h := &EmitRunSummary{
		Now: func() time.Time { return time.Date(2026, 5, 18, 12, 0, 0, 0, time.UTC) },
		Git: func(_ string, _ ...string) ([]byte, error) {
			return []byte("a.go\nb.go\n"), nil
		},
	}
	in := &Input{
		ExitCode:   0,
		ProjectDir: dir,
		LogDir:     logDir,
		Timestamp:  "20260518_120000",
		Milestone:  "m21",
		Result: &proto.RunResultV1{
			ElapsedSecs: 60,
			AgentCalls:  5,
		},
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("Run: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(logDir, "RUN_SUMMARY.json"))
	if err != nil {
		t.Fatalf("read summary: %v", err)
	}
	var sum runSummary
	if err := json.Unmarshal(body, &sum); err != nil {
		t.Fatalf("parse summary: %v\n%s", err, body)
	}
	if sum.Milestone != "m21" {
		t.Errorf("Milestone = %q, want m21", sum.Milestone)
	}
	if sum.Outcome != "success" {
		t.Errorf("Outcome = %q, want success", sum.Outcome)
	}
	if sum.RunType != "milestone" {
		t.Errorf("RunType = %q, want milestone", sum.RunType)
	}
	if sum.TotalAgentCalls != 5 {
		t.Errorf("TotalAgentCalls = %d, want 5", sum.TotalAgentCalls)
	}
	if sum.WallClockSeconds != 60 {
		t.Errorf("WallClockSeconds = %d, want 60", sum.WallClockSeconds)
	}
	if len(sum.FilesChanged) != 2 {
		t.Errorf("FilesChanged length = %d, want 2", len(sum.FilesChanged))
	}
	// Verify archived copy exists.
	if _, err := os.Stat(filepath.Join(logDir, "RUN_SUMMARY_20260518_120000.json")); err != nil {
		t.Errorf("expected archived copy: %v", err)
	}
}

func TestEmitRunSummary_FailureOutcome(t *testing.T) {
	clearSummaryEnv(t)
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	h := &EmitRunSummary{
		Now: func() time.Time { return time.Now().UTC() },
		Git: func(_ string, _ ...string) ([]byte, error) { return nil, nil },
	}
	in := &Input{
		ExitCode:   1,
		ProjectDir: dir,
		LogDir:     logDir,
		Timestamp:  "20260518_120000",
		Result:     &proto.RunResultV1{},
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("Run: %v", err)
	}
	body, _ := os.ReadFile(filepath.Join(logDir, "RUN_SUMMARY.json"))
	if !strings.Contains(string(body), `"outcome": "failure"`) {
		t.Errorf("expected failure outcome; got %s", body)
	}
}

func TestEmitRunSummary_LoadsCausalContext(t *testing.T) {
	clearSummaryEnv(t)
	dir := t.TempDir()
	logDir := filepath.Join(dir, ".claude", "logs")
	claudeDir := filepath.Join(dir, ".claude")
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	ctxFile := filepath.Join(claudeDir, "LAST_FAILURE_CONTEXT.json")
	payload := `{"schema_version":2,"primary_category":"build","primary_subcategory":"compile","primary_signal":"go_build"}`
	if err := os.WriteFile(ctxFile, []byte(payload), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &EmitRunSummary{
		Now: func() time.Time { return time.Now().UTC() },
		Git: func(_ string, _ ...string) ([]byte, error) { return nil, nil },
	}
	in := &Input{
		ExitCode:   1,
		ProjectDir: dir,
		LogDir:     logDir,
		Timestamp:  "20260518_120000",
		Result:     &proto.RunResultV1{},
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("Run: %v", err)
	}
	body, _ := os.ReadFile(filepath.Join(logDir, "RUN_SUMMARY.json"))
	var sum runSummary
	if err := json.Unmarshal(body, &sum); err != nil {
		t.Fatal(err)
	}
	if sum.CausalContext.SchemaVersion != 2 {
		t.Errorf("schema_version = %d, want 2", sum.CausalContext.SchemaVersion)
	}
	if sum.CausalContext.PrimaryCategory != "build" {
		t.Errorf("primary_category = %q", sum.CausalContext.PrimaryCategory)
	}
}

func TestEmitRunSummary_AbsentCausalContext(t *testing.T) {
	clearSummaryEnv(t)
	dir := t.TempDir()
	h := &EmitRunSummary{
		Now: func() time.Time { return time.Now().UTC() },
		Git: func(_ string, _ ...string) ([]byte, error) { return nil, nil },
	}
	in := &Input{
		ExitCode:   0,
		ProjectDir: dir,
		LogDir:     filepath.Join(dir, ".claude", "logs"),
		Timestamp:  "20260518_120000",
		Result:     &proto.RunResultV1{},
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("Run: %v", err)
	}
	body, _ := os.ReadFile(filepath.Join(dir, ".claude", "logs", "RUN_SUMMARY.json"))
	var sum runSummary
	if err := json.Unmarshal(body, &sum); err != nil {
		t.Fatal(err)
	}
	if sum.CausalContext.SchemaVersion != 0 {
		t.Errorf("absent context should yield schema_version 0; got %d", sum.CausalContext.SchemaVersion)
	}
}

// clearSummaryEnv unsets every env var the EmitRunSummary build function
// reads. Tests run inside `tekhton run --milestone` inherit a populated
// _ORCH_ELAPSED / _ORCH_AGENT_CALLS / etc., so the hook would read the
// outer pipeline's counters instead of the synthetic Input fixture.
func clearSummaryEnv(t *testing.T) {
	t.Helper()
	for _, k := range []string{
		"_ORCH_ATTEMPT", "_ORCH_AGENT_CALLS", "_ORCH_ELAPSED", "_ORCH_NO_PROGRESS_COUNT",
		"_ORCH_REVIEW_BUMPED", "_ORCH_RECOVERY_ROUTE_TAKEN", "_ORCH_ENV_GATE_RETRIED",
		"_ORCH_MIXED_BUILD_RETRIED", "_ORCH_SCHEMA_VERSION", "_ORCH_PRIMARY_CAT",
		"_ORCH_PRIMARY_SUB",
		"AUTONOMOUS_TIMEOUT", "AGENT_ERROR_CATEGORY", "AGENT_ERROR_SUBCATEGORY",
		"CONTINUATION_ATTEMPTS", "LAST_AGENT_RETRY_COUNT", "REVIEW_CYCLE",
		"MILESTONE_CURRENT_SPLIT_DEPTH", "SECURITY_FINDINGS_BLOCK",
		"SECURITY_REWORK_CYCLES_DONE", "INTAKE_VERDICT", "INTAKE_CONFIDENCE",
		"TEST_BASELINE_ENABLED", "TEST_AUDIT_ENABLED", "TEST_AUDIT_REPORT_FILE",
		"UI_VALIDATION_PASS_COUNT", "UI_VALIDATION_FAIL_COUNT", "UI_VALIDATION_WARN_COUNT",
		"CURRENT_TEAM_ID", "CURRENT_PARALLEL_GROUP", "CONCURRENT_TEAM_COUNT",
		"DECISIONS_JSON", "TIMING_JSON", "REMEDIATIONS_JSON",
		"QUOTA_STATS_JSON", "_QUOTA_TOTAL_PAUSE_S", "_QUOTA_PAUSE_COUNT",
		"BUILD_FIX_ATTEMPTS", "BUILD_FIX_MAX_ATTEMPTS", "BUILD_FIX_OUTCOME",
		"BUILD_FIX_TURN_BUDGET_USED", "BUILD_FIX_PROGRESS_GATE_FAILURES",
		"PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED", "PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE",
		"PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE", "PREFLIGHT_UI_REPORTER_PATCHED",
		"_PF_FAIL", "_PF_WARN",
		"HUMAN_MODE", "HUMAN_NOTES_TAG", "FIX_DRIFT_MODE", "FIX_NONBLOCKERS_MODE",
		"TASK", "ORCH_CONTEXT_FILE_OVERRIDE",
	} {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}
}

func TestLastInt(t *testing.T) {
	cases := map[string]int{
		"":       0,
		"7":      7,
		"abc7":   7,
		"1 2 3":  3,
		"v3.21":  21,
		"none":   0,
	}
	for in, want := range cases {
		if got := lastInt(in); got != want {
			t.Errorf("lastInt(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestCountLinesPrefix(t *testing.T) {
	body := "- one\n- two\nother\n- three\n"
	if got := countLines(body, "- "); got != 3 {
		t.Errorf("countLines = %d, want 3", got)
	}
	if got := countLines("", "- "); got != 0 {
		t.Errorf("empty input should yield 0")
	}
}

func TestOutcome_Timeout(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("_ORCH_ELAPSED", "7200")
	t.Setenv("AUTONOMOUS_TIMEOUT", "7200")
	h := &EmitRunSummary{}
	in := &Input{ExitCode: 1}
	if got := h.outcome(in); got != "timeout" {
		t.Errorf("outcome = %q, want timeout", got)
	}
}

func TestOutcome_Stuck(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("_ORCH_NO_PROGRESS_COUNT", "2")
	h := &EmitRunSummary{}
	in := &Input{ExitCode: 1}
	if got := h.outcome(in); got != "stuck" {
		t.Errorf("outcome = %q, want stuck", got)
	}
}

func TestRunType_HumanVariants(t *testing.T) {
	cases := []struct {
		tag  string
		want string
	}{
		{"BUG", "human_bug"},
		{"FEAT", "human_feat"},
		{"POLISH", "human_polish"},
		{"", "human"},
	}
	for _, tc := range cases {
		t.Run(tc.want, func(t *testing.T) {
			clearSummaryEnv(t)
			t.Setenv("HUMAN_MODE", "true")
			t.Setenv("HUMAN_NOTES_TAG", tc.tag)
			h := &EmitRunSummary{}
			in := &Input{}
			if got := h.runType(in); got != tc.want {
				t.Errorf("runType with tag=%q = %q, want %q", tc.tag, got, tc.want)
			}
		})
	}
}

func TestRunType_Drift(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("FIX_DRIFT_MODE", "true")
	h := &EmitRunSummary{}
	if got := h.runType(&Input{}); got != "drift" {
		t.Errorf("runType = %q, want drift", got)
	}
}

func TestRunType_Nonblocker(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("FIX_NONBLOCKERS_MODE", "true")
	h := &EmitRunSummary{}
	if got := h.runType(&Input{}); got != "nonblocker" {
		t.Errorf("runType = %q, want nonblocker", got)
	}
}

func TestRunType_Adhoc(t *testing.T) {
	clearSummaryEnv(t)
	h := &EmitRunSummary{}
	if got := h.runType(&Input{}); got != "adhoc" {
		t.Errorf("runType = %q, want adhoc", got)
	}
}

func TestRecoveryActions_AllCombinations(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("_ORCH_REVIEW_BUMPED", "true")
	t.Setenv("CONTINUATION_ATTEMPTS", "1")
	t.Setenv("LAST_AGENT_RETRY_COUNT", "2")
	t.Setenv("_ORCH_RECOVERY_ROUTE_TAKEN", "retry_attempt")
	h := &EmitRunSummary{}
	got := h.recoveryActions()
	want := map[string]bool{
		"review_cycle_bump": true,
		"continuation":      true,
		"transient_retry":   true,
		"retry_attempt":     true,
	}
	for _, action := range got {
		if !want[action] {
			t.Errorf("unexpected recovery action %q", action)
		}
		delete(want, action)
	}
	for missing := range want {
		t.Errorf("missing recovery action %q", missing)
	}
}

func TestRecoveryActions_SaveExitFiltered(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("_ORCH_RECOVERY_ROUTE_TAKEN", "save_exit")
	h := &EmitRunSummary{}
	got := h.recoveryActions()
	for _, action := range got {
		if action == "save_exit" {
			t.Errorf("save_exit should be excluded from recovery actions")
		}
	}
}

func TestErrorClasses_SymptomAndRootCause(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("AGENT_ERROR_CATEGORY", "quota")
	t.Setenv("AGENT_ERROR_SUBCATEGORY", "rate_limit")
	h := &EmitRunSummary{}
	primary := causalContext{
		PrimaryCategory:    "build",
		PrimarySubcategory: "compile",
	}
	got := h.errorClasses(primary)
	if len(got) != 2 {
		t.Fatalf("expected 2 error classes, got %v", got)
	}
	if got[0] != "quota/rate_limit" {
		t.Errorf("got[0] = %q, want quota/rate_limit", got[0])
	}
	if got[1] != "root:build/compile" {
		t.Errorf("got[1] = %q, want root:build/compile", got[1])
	}
}

func TestErrorClasses_DeduplicatesWhenSame(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("AGENT_ERROR_CATEGORY", "build")
	t.Setenv("AGENT_ERROR_SUBCATEGORY", "compile")
	h := &EmitRunSummary{}
	primary := causalContext{
		PrimaryCategory:    "build",
		PrimarySubcategory: "compile",
	}
	got := h.errorClasses(primary)
	// Root and symptom are identical — only the symptom should appear.
	if len(got) != 1 {
		t.Errorf("expected deduplication to yield 1 class; got %v", got)
	}
}

func TestTestBaselineStatus_Disabled(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("TEST_BASELINE_ENABLED", "false")
	dir := t.TempDir()
	h := &EmitRunSummary{}
	if got := h.testBaselineStatus(dir); got != "disabled" {
		t.Errorf("testBaselineStatus = %q, want disabled", got)
	}
}

func TestTestBaselineStatus_PreExistingFailures(t *testing.T) {
	clearSummaryEnv(t)
	dir := t.TempDir()
	claudeDir := filepath.Join(dir, ".claude")
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	payload := `{"exit_code":1}`
	if err := os.WriteFile(filepath.Join(claudeDir, "TEST_BASELINE.json"), []byte(payload), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &EmitRunSummary{}
	if got := h.testBaselineStatus(dir); got != "pre_existing_failures" {
		t.Errorf("testBaselineStatus = %q, want pre_existing_failures", got)
	}
}

func TestTestBaselineStatus_Clean(t *testing.T) {
	clearSummaryEnv(t)
	dir := t.TempDir()
	claudeDir := filepath.Join(dir, ".claude")
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	payload := `{"exit_code":0}`
	if err := os.WriteFile(filepath.Join(claudeDir, "TEST_BASELINE.json"), []byte(payload), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &EmitRunSummary{}
	if got := h.testBaselineStatus(dir); got != "clean" {
		t.Errorf("testBaselineStatus = %q, want clean", got)
	}
}

func TestTestAuditVerdict_ReturnsVerdict(t *testing.T) {
	cases := []struct {
		content string
		want    string
	}{
		{"## Section\nVerdict: PASS\n", "PASS"},
		{"Verdict: NEEDS_WORK\n", "NEEDS_WORK"},
		{"Verdict: CONCERNS\n", "CONCERNS"},
		{"no verdict line\n", "unknown"},
	}
	for _, tc := range cases {
		t.Run(tc.want, func(t *testing.T) {
			clearSummaryEnv(t)
			dir := t.TempDir()
			report := filepath.Join(dir, "TEST_AUDIT_REPORT.md")
			if err := os.WriteFile(report, []byte(tc.content), 0o644); err != nil {
				t.Fatal(err)
			}
			t.Setenv("TEST_AUDIT_REPORT_FILE", report)
			h := &EmitRunSummary{}
			if got := h.testAuditVerdict(dir); got != tc.want {
				t.Errorf("testAuditVerdict = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestTestAuditVerdict_SkippedWhenDisabled(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("TEST_AUDIT_ENABLED", "false")
	h := &EmitRunSummary{}
	if got := h.testAuditVerdict(t.TempDir()); got != "skipped" {
		t.Errorf("testAuditVerdict = %q, want skipped", got)
	}
}

func TestLoadBuildFixStats_EnabledWhenAttemptsNonZero(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("BUILD_FIX_ATTEMPTS", "2")
	t.Setenv("BUILD_FIX_OUTCOME", "success")
	t.Setenv("BUILD_FIX_TURN_BUDGET_USED", "15")
	got := loadBuildFixStats()
	if !got.Enabled {
		t.Errorf("Enabled should be true when attempts > 0")
	}
	if got.Attempts != 2 {
		t.Errorf("Attempts = %d, want 2", got.Attempts)
	}
	if got.Outcome != "success" {
		t.Errorf("Outcome = %q, want success", got.Outcome)
	}
	if got.TurnBudgetUsed != 15 {
		t.Errorf("TurnBudgetUsed = %d, want 15", got.TurnBudgetUsed)
	}
}

func TestLoadRecoveryRouting_Flags(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("_ORCH_RECOVERY_ROUTE_TAKEN", "retry_attempt")
	t.Setenv("_ORCH_ENV_GATE_RETRIED", "1")
	t.Setenv("_ORCH_MIXED_BUILD_RETRIED", "1")
	t.Setenv("_ORCH_SCHEMA_VERSION", "2")
	got := loadRecoveryRouting()
	if got.RouteTaken != "retry_attempt" {
		t.Errorf("RouteTaken = %q, want retry_attempt", got.RouteTaken)
	}
	if !got.EnvGateRetried {
		t.Errorf("EnvGateRetried should be true")
	}
	if !got.MixedBuildRetried {
		t.Errorf("MixedBuildRetried should be true")
	}
	if got.CausalSchemaVersion != 2 {
		t.Errorf("CausalSchemaVersion = %d, want 2", got.CausalSchemaVersion)
	}
}

func TestLoadPreflightUI_Flags(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED", "1")
	t.Setenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE", "test_rule")
	t.Setenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE", "playwright.config.ts")
	t.Setenv("PREFLIGHT_UI_REPORTER_PATCHED", "1")
	t.Setenv("_PF_FAIL", "3")
	t.Setenv("_PF_WARN", "1")
	got := loadPreflightUI()
	if !got.InteractiveConfigDetected {
		t.Errorf("InteractiveConfigDetected should be true")
	}
	if got.InteractiveConfigRule != "test_rule" {
		t.Errorf("InteractiveConfigRule = %q, want test_rule", got.InteractiveConfigRule)
	}
	if got.InteractiveConfigFile != "playwright.config.ts" {
		t.Errorf("InteractiveConfigFile = %q", got.InteractiveConfigFile)
	}
	if !got.ReporterAutoPatched {
		t.Errorf("ReporterAutoPatched should be true")
	}
	if got.FailCount != 3 {
		t.Errorf("FailCount = %d, want 3", got.FailCount)
	}
	if got.WarnCount != 1 {
		t.Errorf("WarnCount = %d, want 1", got.WarnCount)
	}
}

func TestLoadQuotaStats_FromJSONEnvVar(t *testing.T) {
	clearSummaryEnv(t)
	t.Setenv("QUOTA_STATS_JSON", `{"total_pause_time_s":300,"pause_count":2,"was_quota_limited":true}`)
	got := loadQuotaStats()
	if got.TotalPauseTimeS != 300 {
		t.Errorf("TotalPauseTimeS = %d, want 300", got.TotalPauseTimeS)
	}
	if got.PauseCount != 2 {
		t.Errorf("PauseCount = %d, want 2", got.PauseCount)
	}
	if !got.WasQuotaLimited {
		t.Errorf("WasQuotaLimited should be true")
	}
}

func TestBoolEnv(t *testing.T) {
	cases := []struct {
		name     string
		value    string
		fallback bool
		want     bool
	}{
		{"true", "true", false, true},
		{"1", "1", false, true},
		{"yes", "yes", false, true},
		{"on", "on", false, true},
		{"TRUE", "TRUE", false, true},
		{"false", "false", true, false},
		{"0", "0", true, false},
		{"no", "no", true, false},
		{"off", "off", true, false},
		{"empty_fallback_true", "", true, true},
		{"junk_fallback_true", "junk", true, true},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			const key = "TEST_BOOL_ENV_KEY"
			if tc.value == "" {
				os.Unsetenv(key)
			} else {
				t.Setenv(key, tc.value)
			}
			if got := boolEnv(key, tc.fallback); got != tc.want {
				t.Errorf("boolEnv(%q, %v) = %v, want %v", tc.value, tc.fallback, got, tc.want)
			}
		})
	}
}

func TestEnvOrJSON_InvalidFallsBack(t *testing.T) {
	t.Setenv("INVALID_JSON", "not-valid-json")
	got := envOrJSON("invalid", "[]")
	if string(got) != "[]" {
		t.Errorf("invalid JSON should fall back to %q; got %q", "[]", got)
	}
}

func TestEnvOrJSON_ValidReturnsRaw(t *testing.T) {
	t.Setenv("DECISIONS_JSON", `[{"key":"val"}]`)
	got := envOrJSON("decisions", "[]")
	if string(got) != `[{"key":"val"}]` {
		t.Errorf("valid JSON env var not returned; got %q", got)
	}
}

func TestEnvOrJSON_EmptyFallsBack(t *testing.T) {
	os.Unsetenv("EMPTY_JSON")
	got := envOrJSON("empty", "{}")
	if string(got) != "{}" {
		t.Errorf("empty env var should use fallback; got %q", got)
	}
}

func TestEmitRunSummary_TaskLabelTruncated(t *testing.T) {
	clearSummaryEnv(t)
	longTask := strings.Repeat("x", 100)
	t.Setenv("TASK", longTask)
	dir := t.TempDir()
	h := &EmitRunSummary{
		Now: func() time.Time { return time.Now().UTC() },
		Git: func(_ string, _ ...string) ([]byte, error) { return nil, nil },
	}
	sum := h.build(&Input{ExitCode: 0, ProjectDir: dir, Timestamp: "ts"})
	if len(sum.TaskLabel) != 80 {
		t.Errorf("TaskLabel length = %d, want 80", len(sum.TaskLabel))
	}
}
