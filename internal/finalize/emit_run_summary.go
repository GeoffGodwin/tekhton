package finalize

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// EmitRunSummary is the Go body of _hook_emit_run_summary. Writes
// RUN_SUMMARY.json to LOG_DIR plus an archived copy
// RUN_SUMMARY_<timestamp>.json so dashboard parsers can find historical
// runs. Pure Go because every input is either RunResultV1, an env var the
// bash side already set as the contract for shim-invoked hooks, or an
// on-disk artifact (LAST_FAILURE_CONTEXT.json, TEST_BASELINE.json) that
// other ported hooks already touch.
//
// The bash original (lib/finalize_summary.sh + finalize_summary_collectors.sh)
// composed JSON via printf with custom escaping. The Go port uses
// encoding/json so field shape stays identical without bespoke escapers.
// Field names/order match the bash output so dashboard parsers
// (lib/dashboard_parsers.sh) continue to work unchanged.
type EmitRunSummary struct {
	// Path overrides the default RUN_SUMMARY.json location.
	Path string

	// Git overrides the git command used to capture changed files.
	Git func(dir string, args ...string) ([]byte, error)

	// Now overrides time.Now for deterministic timestamps in tests.
	Now func() time.Time
}

// Name implements Hook.
func (h *EmitRunSummary) Name() string { return "_hook_emit_run_summary" }

// runSummary mirrors the JSON shape produced by the bash printf in
// lib/finalize_summary.sh:244. The field ordering here is preserved by the
// MarshalJSON method so dashboard parsers that pattern-match on byte
// position keep working.
type runSummary struct {
	Milestone               string                 `json:"milestone"`
	Outcome                 string                 `json:"outcome"`
	Attempts                int                    `json:"attempts"`
	TotalAgentCalls         int                    `json:"total_agent_calls"`
	WallClockSeconds        int                    `json:"wall_clock_seconds"`
	TotalTurns              int                    `json:"total_turns"`
	TotalTimeS              int                    `json:"total_time_s"`
	RunType                 string                 `json:"run_type"`
	TaskLabel               string                 `json:"task_label"`
	Stages                  map[string]stageEntry  `json:"stages"`
	FilesChanged            []string               `json:"files_changed"`
	ErrorClassesEncountered []string               `json:"error_classes_encountered"`
	RecoveryActionsTaken    []string               `json:"recovery_actions_taken"`
	ReworkCycles            int                    `json:"rework_cycles"`
	SplitDepth              int                    `json:"split_depth"`
	SecurityFindingsCount   int                    `json:"security_findings_count"`
	SecurityReworkCycles    int                    `json:"security_rework_cycles"`
	IntakeVerdict           string                 `json:"intake_verdict"`
	IntakeConfidence        int                    `json:"intake_confidence"`
	Quota                   quotaStats             `json:"quota"`
	TestBaselineStatus      string                 `json:"test_baseline_status"`
	TestAuditVerdict        string                 `json:"test_audit_verdict"`
	UIValidation            uiValidation           `json:"ui_validation"`
	Team                    string                 `json:"team"`
	ParallelGroup           string                 `json:"parallel_group"`
	ConcurrentTeams         int                    `json:"concurrent_teams"`
	Decisions               json.RawMessage        `json:"decisions"`
	TimingBreakdown         json.RawMessage        `json:"timing_breakdown"`
	Remediations            json.RawMessage        `json:"remediations"`
	CausalContext           causalContext          `json:"causal_context"`
	BuildFixStats           buildFixStats          `json:"build_fix_stats"`
	RecoveryRouting         recoveryRouting        `json:"recovery_routing"`
	PreflightUI             preflightUI            `json:"preflight_ui"`
	Timestamp               string                 `json:"timestamp"`
}

type stageEntry struct {
	Turns                int `json:"turns"`
	DurationS            int `json:"duration_s"`
	Budget               int `json:"budget"`
	TestExecutionCount   int `json:"test_execution_count,omitempty"`
	TestExecutionApproxS int `json:"test_execution_approx_s,omitempty"`
	TestWritingApproxS   int `json:"test_writing_approx_s,omitempty"`
}

type quotaStats struct {
	TotalPauseTimeS int  `json:"total_pause_time_s"`
	PauseCount      int  `json:"pause_count"`
	WasQuotaLimited bool `json:"was_quota_limited"`
}

type uiValidation struct {
	Pass int `json:"pass"`
	Fail int `json:"fail"`
	Warn int `json:"warn"`
}

type causalContext struct {
	SchemaVersion       int    `json:"schema_version"`
	PrimaryCategory     string `json:"primary_category,omitempty"`
	PrimarySubcategory  string `json:"primary_subcategory,omitempty"`
	PrimarySignal       string `json:"primary_signal,omitempty"`
	SecondaryCategory   string `json:"secondary_category,omitempty"`
	SecondarySubcategory string `json:"secondary_subcategory,omitempty"`
	SecondarySignal     string `json:"secondary_signal,omitempty"`
}

type buildFixStats struct {
	Enabled             bool   `json:"enabled"`
	Attempts            int    `json:"attempts"`
	MaxAttempts         int    `json:"max_attempts"`
	Outcome             string `json:"outcome"`
	TurnBudgetUsed      int    `json:"turn_budget_used"`
	ProgressGateFailures int   `json:"progress_gate_failures"`
}

type recoveryRouting struct {
	RouteTaken          string `json:"route_taken"`
	EnvGateRetried      bool   `json:"env_gate_retried"`
	MixedBuildRetried   bool   `json:"mixed_build_retried"`
	CausalSchemaVersion int    `json:"causal_schema_version"`
}

type preflightUI struct {
	InteractiveConfigDetected bool   `json:"interactive_config_detected"`
	InteractiveConfigRule     string `json:"interactive_config_rule"`
	InteractiveConfigFile     string `json:"interactive_config_file"`
	ReporterAutoPatched       bool   `json:"reporter_auto_patched"`
	FailCount                 int    `json:"fail_count"`
	WarnCount                 int    `json:"warn_count"`
}

// Run writes RUN_SUMMARY.json and an archived timestamped copy. Returns nil
// for non-fatal conditions (mirrors bash `|| true` semantics).
func (h *EmitRunSummary) Run(_ context.Context, in *Input) error {
	logDir := in.LogDir
	if logDir == "" {
		logDir = filepath.Join(in.ProjectDir, ".claude", "logs")
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return fmt.Errorf("emit_run_summary: mkdir log dir: %w", err)
	}
	path := h.Path
	if path == "" {
		path = filepath.Join(logDir, "RUN_SUMMARY.json")
	}

	sum := h.build(in)
	body, err := json.MarshalIndent(&sum, "", "  ")
	if err != nil {
		return fmt.Errorf("emit_run_summary: marshal: %w", err)
	}
	body = append(body, '\n')

	if err := writeFileAtomic(path, body); err != nil {
		return fmt.Errorf("emit_run_summary: write: %w", err)
	}
	ts := in.Timestamp
	if ts == "" {
		ts = h.nowUTC().Format("20060102_150405")
	}
	archive := filepath.Join(logDir, "RUN_SUMMARY_"+ts+".json")
	if err := writeFileAtomic(archive, body); err != nil {
		return fmt.Errorf("emit_run_summary: archive: %w", err)
	}
	return nil
}

// build assembles the runSummary in-memory from the Input + the inherited
// shell environment. Fields that the bash version read from bash globals
// are read here from env vars; the bash shim already exported those vars
// for shim-invoked hooks, so the contract is unchanged.
func (h *EmitRunSummary) build(in *Input) runSummary {
	outcome := h.outcome(in)

	files := h.changedFiles(in.ProjectDir)
	if files == nil {
		files = []string{}
	}

	attempts := lookupIntEnv("_ORCH_ATTEMPT", 1)
	agentCalls := lookupIntEnv("_ORCH_AGENT_CALLS", 0)
	elapsed := lookupIntEnv("_ORCH_ELAPSED", 0)
	if in.Result != nil {
		if agentCalls == 0 {
			agentCalls = in.Result.AgentCalls
		}
		if elapsed == 0 && in.Result.ElapsedSecs > 0 {
			elapsed = int(in.Result.ElapsedSecs)
		}
	}

	milestone := in.Milestone
	if milestone == "" {
		milestone = "none"
	}

	taskLabel := os.Getenv("TASK")
	if len(taskLabel) > 80 {
		taskLabel = taskLabel[:80]
	}

	timestamp := h.nowUTC().Format("2006-01-02T15:04:05Z")

	primary := loadCausalContext(in.ProjectDir)

	dec := envOrJSON("decisions", "[]")
	timing := envOrJSON("timing", "{}")
	remed := envOrJSON("remediations", "[]")

	return runSummary{
		Milestone:               milestone,
		Outcome:                 outcome,
		Attempts:                attempts,
		TotalAgentCalls:         agentCalls,
		WallClockSeconds:        elapsed,
		TotalTurns:              agentCalls,
		TotalTimeS:              elapsed,
		RunType:                 h.runType(in),
		TaskLabel:               taskLabel,
		Stages:                  map[string]stageEntry{},
		FilesChanged:            files,
		ErrorClassesEncountered: h.errorClasses(primary),
		RecoveryActionsTaken:    h.recoveryActions(),
		ReworkCycles:            lastInt(os.Getenv("REVIEW_CYCLE")),
		SplitDepth:              lastInt(os.Getenv("MILESTONE_CURRENT_SPLIT_DEPTH")),
		SecurityFindingsCount:   countLines(os.Getenv("SECURITY_FINDINGS_BLOCK"), "- "),
		SecurityReworkCycles:    lookupIntEnv("SECURITY_REWORK_CYCLES_DONE", 0),
		IntakeVerdict:           defaultStr(os.Getenv("INTAKE_VERDICT"), "none"),
		IntakeConfidence:        lastInt(os.Getenv("INTAKE_CONFIDENCE")),
		Quota:                   loadQuotaStats(),
		TestBaselineStatus:      h.testBaselineStatus(in.ProjectDir),
		TestAuditVerdict:        h.testAuditVerdict(in.ProjectDir),
		UIValidation: uiValidation{
			Pass: lookupIntEnv("UI_VALIDATION_PASS_COUNT", 0),
			Fail: lookupIntEnv("UI_VALIDATION_FAIL_COUNT", 0),
			Warn: lookupIntEnv("UI_VALIDATION_WARN_COUNT", 0),
		},
		Team:            os.Getenv("CURRENT_TEAM_ID"),
		ParallelGroup:   os.Getenv("CURRENT_PARALLEL_GROUP"),
		ConcurrentTeams: lookupIntEnv("CONCURRENT_TEAM_COUNT", 0),
		Decisions:       dec,
		TimingBreakdown: timing,
		Remediations:    remed,
		CausalContext:   primary,
		BuildFixStats:   loadBuildFixStats(),
		RecoveryRouting: loadRecoveryRouting(),
		PreflightUI:     loadPreflightUI(),
		Timestamp:       timestamp,
	}
}

// outcome mirrors the bash exit/timeout/stuck/failure classification.
func (h *EmitRunSummary) outcome(in *Input) string {
	if in.ExitCode == 0 {
		return "success"
	}
	if elapsed := lookupIntEnv("_ORCH_ELAPSED", 0); elapsed > 0 {
		if timeout := lookupIntEnv("AUTONOMOUS_TIMEOUT", 7200); elapsed >= timeout {
			return "timeout"
		}
	}
	if lookupIntEnv("_ORCH_NO_PROGRESS_COUNT", 0) >= 2 {
		return "stuck"
	}
	return "failure"
}

// runType mirrors the bash adhoc/milestone/human/drift/nonblocker tag.
func (h *EmitRunSummary) runType(in *Input) string {
	if in.Milestone != "" && in.Milestone != "none" {
		return "milestone"
	}
	if strings.EqualFold(os.Getenv("HUMAN_MODE"), "true") {
		switch os.Getenv("HUMAN_NOTES_TAG") {
		case "BUG":
			return "human_bug"
		case "FEAT":
			return "human_feat"
		case "POLISH":
			return "human_polish"
		default:
			return "human"
		}
	}
	if strings.EqualFold(os.Getenv("FIX_DRIFT_MODE"), "true") {
		return "drift"
	}
	if strings.EqualFold(os.Getenv("FIX_NONBLOCKERS_MODE"), "true") {
		return "nonblocker"
	}
	return "adhoc"
}

// changedFiles delegates to the same git command EmitRunMemory uses.
func (h *EmitRunSummary) changedFiles(projectDir string) []string {
	runner := h.Git
	if runner == nil {
		runner = defaultGit
	}
	out, err := runner(projectDir, "diff", "--name-only", "HEAD")
	if err != nil {
		return nil
	}
	var files []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		files = append(files, line)
	}
	return files
}

// errorClasses builds the symptom + root-cause array. Mirrors
// _collect_error_classes_json in finalize_summary_collectors.sh.
func (h *EmitRunSummary) errorClasses(primary causalContext) []string {
	var out []string
	symptom := os.Getenv("AGENT_ERROR_CATEGORY")
	symptomClass := ""
	if symptom != "" {
		sub := defaultStr(os.Getenv("AGENT_ERROR_SUBCATEGORY"), "unknown")
		symptomClass = symptom + "/" + sub
		out = append(out, symptomClass)
	}
	if primary.PrimaryCategory != "" {
		sub := defaultStr(primary.PrimarySubcategory, "unknown")
		root := "root:" + primary.PrimaryCategory + "/" + sub
		if primary.PrimaryCategory+"/"+sub != symptomClass {
			out = append(out, root)
		}
	}
	if out == nil {
		return []string{}
	}
	return out
}

// recoveryActions mirrors _collect_recovery_actions_json.
func (h *EmitRunSummary) recoveryActions() []string {
	var out []string
	if strings.EqualFold(os.Getenv("_ORCH_REVIEW_BUMPED"), "true") {
		out = append(out, "review_cycle_bump")
	}
	if lookupIntEnv("CONTINUATION_ATTEMPTS", 0) > 0 {
		out = append(out, "continuation")
	}
	if lookupIntEnv("LAST_AGENT_RETRY_COUNT", 0) > 0 {
		out = append(out, "transient_retry")
	}
	route := os.Getenv("_ORCH_RECOVERY_ROUTE_TAKEN")
	if route != "" && route != "save_exit" {
		out = append(out, route)
	}
	if out == nil {
		return []string{}
	}
	return out
}

// testBaselineStatus mirrors the bash check on TEST_BASELINE.json.
func (h *EmitRunSummary) testBaselineStatus(projectDir string) string {
	if !boolEnv("TEST_BASELINE_ENABLED", true) {
		return "disabled"
	}
	path := filepath.Join(projectDir, ".claude", "TEST_BASELINE.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return "not_captured"
	}
	var bl struct {
		ExitCode int `json:"exit_code"`
	}
	if err := json.Unmarshal(data, &bl); err != nil {
		return "not_captured"
	}
	if bl.ExitCode == 0 {
		return "clean"
	}
	return "pre_existing_failures"
}

// testAuditVerdict scans the audit report for the verdict line.
func (h *EmitRunSummary) testAuditVerdict(projectDir string) string {
	if !boolEnv("TEST_AUDIT_ENABLED", true) {
		return "skipped"
	}
	report := os.Getenv("TEST_AUDIT_REPORT_FILE")
	if report == "" {
		return "skipped"
	}
	if !filepath.IsAbs(report) {
		report = filepath.Join(projectDir, report)
	}
	data, err := os.ReadFile(report)
	if err != nil {
		return "skipped"
	}
	for _, line := range strings.Split(string(data), "\n") {
		lower := strings.ToLower(line)
		if i := strings.Index(lower, "verdict:"); i >= 0 {
			rest := strings.TrimSpace(line[i+len("verdict:"):])
			for _, tok := range []string{"NEEDS_WORK", "PASS", "CONCERNS"} {
				if strings.EqualFold(rest, tok) || strings.HasPrefix(strings.ToUpper(rest), tok) {
					return tok
				}
			}
			return "unknown"
		}
	}
	return "unknown"
}

// nowUTC returns the configured clock (or time.Now) in UTC.
func (h *EmitRunSummary) nowUTC() time.Time {
	if h.Now != nil {
		return h.Now().UTC()
	}
	return time.Now().UTC()
}

// loadCausalContext mirrors _collect_causal_context_json. Reads
// LAST_FAILURE_CONTEXT.json when present; returns zero schema_version
// otherwise (matches the bash absent-file sentinel).
func loadCausalContext(projectDir string) causalContext {
	path := os.Getenv("ORCH_CONTEXT_FILE_OVERRIDE")
	if path == "" {
		path = filepath.Join(projectDir, ".claude", "LAST_FAILURE_CONTEXT.json")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return causalContext{}
	}
	var raw struct {
		SchemaVersion        int    `json:"schema_version"`
		PrimaryCategory      string `json:"primary_category"`
		PrimarySubcategory   string `json:"primary_subcategory"`
		PrimarySignal        string `json:"primary_signal"`
		SecondaryCategory    string `json:"secondary_category"`
		SecondarySubcategory string `json:"secondary_subcategory"`
		SecondarySignal      string `json:"secondary_signal"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return causalContext{}
	}
	return causalContext{
		SchemaVersion:        raw.SchemaVersion,
		PrimaryCategory:      raw.PrimaryCategory,
		PrimarySubcategory:   raw.PrimarySubcategory,
		PrimarySignal:        raw.PrimarySignal,
		SecondaryCategory:    raw.SecondaryCategory,
		SecondarySubcategory: raw.SecondarySubcategory,
		SecondarySignal:      raw.SecondarySignal,
	}
}

// loadBuildFixStats reads the m128 build-fix exported vars.
func loadBuildFixStats() buildFixStats {
	attempts := lookupIntEnv("BUILD_FIX_ATTEMPTS", 0)
	maxAttempts := lookupIntEnv("BUILD_FIX_MAX_ATTEMPTS", 3)
	outcome := defaultStr(os.Getenv("BUILD_FIX_OUTCOME"), "not_run")
	enabled := true
	if attempts == 0 {
		outcome = "not_run"
		enabled = false
	}
	return buildFixStats{
		Enabled:              enabled,
		Attempts:             attempts,
		MaxAttempts:          maxAttempts,
		Outcome:              outcome,
		TurnBudgetUsed:       lookupIntEnv("BUILD_FIX_TURN_BUDGET_USED", 0),
		ProgressGateFailures: lookupIntEnv("BUILD_FIX_PROGRESS_GATE_FAILURES", 0),
	}
}

// loadRecoveryRouting reads m130 recovery-routing exported vars.
func loadRecoveryRouting() recoveryRouting {
	route := defaultStr(os.Getenv("_ORCH_RECOVERY_ROUTE_TAKEN"), "save_exit")
	return recoveryRouting{
		RouteTaken:          route,
		EnvGateRetried:      os.Getenv("_ORCH_ENV_GATE_RETRIED") == "1",
		MixedBuildRetried:   os.Getenv("_ORCH_MIXED_BUILD_RETRIED") == "1",
		CausalSchemaVersion: lookupIntEnv("_ORCH_SCHEMA_VERSION", 0),
	}
}

// loadPreflightUI reads m131 preflight-UI audit vars.
func loadPreflightUI() preflightUI {
	return preflightUI{
		InteractiveConfigDetected: os.Getenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED") == "1",
		InteractiveConfigRule:     os.Getenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE"),
		InteractiveConfigFile:     os.Getenv("PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE"),
		ReporterAutoPatched:       os.Getenv("PREFLIGHT_UI_REPORTER_PATCHED") == "1",
		FailCount:                 lookupIntEnv("_PF_FAIL", 0),
		WarnCount:                 lookupIntEnv("_PF_WARN", 0),
	}
}

// loadQuotaStats reads the M16 quota counters from env (bash hook called
// get_quota_stats_json — same contract surface).
func loadQuotaStats() quotaStats {
	if raw := os.Getenv("QUOTA_STATS_JSON"); raw != "" {
		var q quotaStats
		if err := json.Unmarshal([]byte(raw), &q); err == nil {
			return q
		}
	}
	return quotaStats{
		TotalPauseTimeS: lookupIntEnv("_QUOTA_TOTAL_PAUSE_S", 0),
		PauseCount:      lookupIntEnv("_QUOTA_PAUSE_COUNT", 0),
		WasQuotaLimited: lookupIntEnv("_QUOTA_PAUSE_COUNT", 0) > 0,
	}
}

// writeFileAtomic mirrors the m03 tmpfile + rename pattern. Same dir so the
// rename is a same-fs op.
func writeFileAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".run_summary.*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	cleanup := func() { _ = os.Remove(name) }
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(name, path); err != nil {
		cleanup()
		return err
	}
	return nil
}

// envOrJSON returns the contents of <upper>_JSON env var if it parses as
// JSON, else the fallback. Lets bash callers feed full JSON arrays/objects
// for decisions / timing / remediations without re-implementing those
// collectors in Go (they'll port in m24/m25 alongside their subsystems).
func envOrJSON(name, fallback string) json.RawMessage {
	key := strings.ToUpper(name) + "_JSON"
	raw := os.Getenv(key)
	if raw == "" {
		return json.RawMessage(fallback)
	}
	if json.Valid([]byte(raw)) {
		return json.RawMessage(raw)
	}
	return json.RawMessage(fallback)
}

// defaultStr returns s if non-empty, else fallback.
func defaultStr(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}

// lastInt extracts the last integer found in s. Returns 0 when none.
// Mirrors the bash `echo "$x" | grep -oE '[0-9]+' | tail -1` — the bash
// pipeline kept only the last match, and the Go port preserves that
// behavior verbatim despite the env vars in practice carrying a single
// integer.
func lastInt(s string) int {
	var last int
	var current string
	for _, r := range s {
		if r >= '0' && r <= '9' {
			current += string(r)
		} else {
			if current != "" {
				if n, err := strconv.Atoi(current); err == nil {
					last = n
				}
				current = ""
			}
		}
	}
	if current != "" {
		if n, err := strconv.Atoi(current); err == nil {
			last = n
		}
	}
	return last
}

// countLines returns the number of lines in s that begin with prefix.
func countLines(s, prefix string) int {
	if s == "" {
		return 0
	}
	n := 0
	for _, line := range strings.Split(s, "\n") {
		if strings.HasPrefix(line, prefix) {
			n++
		}
	}
	return n
}

// boolEnv returns true if NAME is unset (uses fallback) or matches a
// canonical truthy token (case-insensitive).
func boolEnv(name string, fallback bool) bool {
	raw, ok := os.LookupEnv(name)
	if !ok || raw == "" {
		return fallback
	}
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "true", "1", "yes", "on":
		return true
	case "false", "0", "no", "off":
		return false
	}
	return fallback
}
