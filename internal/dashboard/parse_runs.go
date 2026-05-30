// parse_runs.go — Run summary parser. Ports
// lib/dashboard_parsers_runs.sh (metrics.jsonl primary path; embedded
// Python heredoc and bash/sed fallback both collapsed into one Go
// implementation) and lib/dashboard_parsers_runs_files.sh (RUN_SUMMARY_*.json
// legacy fallback).
//
// Depth-counting semantics: the bash Python primary path and the bash sed
// fallback disagree on what `depth` counts (Python uses lines[-depth:] before
// filtering zero-turn records; sed uses tail -n $depth and skips zero-turn
// via a continue, so depth is post-filter). The Go port adopts the
// **Python semantics** — depth applies to lines pre-filter — because the
// Python primary path is the bash-side canonical contract. Documented at
// dashboard_parsers_runs.sh:270-276 in the legacy code.

package dashboard

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// stageNames is the canonical ordered list of stage names the bash parser
// iterates over. Order is load-bearing because Go's json.Marshal sorts map
// keys lexically — but downstream consumers (parity gate uses `jq -S`, JS
// reader accesses by key) tolerate any order. Listed here so adding a new
// stage is a one-place change.
var stageNames = []string{
	"coder", "reviewer", "tester", "scout",
	"security", "cleanup", "test_audit", "analyze_cleanup",
	"specialist_security", "specialist_perf", "specialist_api",
}

// metricsRecord mirrors the relevant fields of a metrics.jsonl line. All
// fields are optional — `encoding/json` zero-fills missing keys.
type metricsRecord struct {
	Timestamp     string `json:"timestamp"`
	Task          string `json:"task"`
	TaskType      string `json:"task_type"`
	MilestoneMode bool   `json:"milestone_mode"`
	TotalTurns    int    `json:"total_turns"`
	TotalTimeS    int    `json:"total_time_s"`
	Outcome       string `json:"outcome"`

	CoderTurns              int `json:"coder_turns"`
	ReviewerTurns           int `json:"reviewer_turns"`
	TesterTurns             int `json:"tester_turns"`
	ScoutTurns              int `json:"scout_turns"`
	SecurityTurns           int `json:"security_turns"`
	CleanupTurns            int `json:"cleanup_turns"`
	TestAuditTurns          int `json:"test_audit_turns"`
	AnalyzeCleanupTurns     int `json:"analyze_cleanup_turns"`
	SpecialistSecurityTurns int `json:"specialist_security_turns"`
	SpecialistPerfTurns     int `json:"specialist_perf_turns"`
	SpecialistAPITurns      int `json:"specialist_api_turns"`

	AdjustedCoder    int `json:"adjusted_coder"`
	AdjustedReviewer int `json:"adjusted_reviewer"`
	AdjustedTester   int `json:"adjusted_tester"`

	CoderDurationS          int `json:"coder_duration_s"`
	ReviewerDurationS       int `json:"reviewer_duration_s"`
	TesterDurationS         int `json:"tester_duration_s"`
	ScoutDurationS          int `json:"scout_duration_s"`
	SecurityDurationS       int `json:"security_duration_s"`
	CleanupDurationS        int `json:"cleanup_duration_s"`
	TestAuditDurationS      int `json:"test_audit_duration_s"`
	AnalyzeCleanupDurationS int `json:"analyze_cleanup_duration_s"`

	ReviewCycles         int `json:"review_cycles"`
	SecurityReworkCycles int `json:"security_rework_cycles"`
}

// runSummaryFile mirrors the relevant fields of a legacy RUN_SUMMARY_*.json
// file. Used by the fallback path when metrics.jsonl is absent.
type runSummaryFile struct {
	Outcome         string `json:"outcome"`
	TotalTurns      int    `json:"total_turns"`
	TotalAgentCalls int    `json:"total_agent_calls"`
	TotalTimeS      int    `json:"total_time_s"`
	WallClockS      int    `json:"wall_clock_seconds"`
	Milestone       string `json:"milestone"`
	RunType         string `json:"run_type"`
	TaskLabel       string `json:"task_label"`
	Timestamp       string `json:"timestamp"`
	Team            string `json:"team"`

	Stages map[string]proto.DashboardRunSummaryStage `json:"stages"`

	CausalContext struct {
		PrimaryCategory    string `json:"primary_category"`
		PrimarySubcategory string `json:"primary_subcategory"`
	} `json:"causal_context"`
	BuildFixStats struct {
		Outcome  string `json:"outcome"`
		Attempts int    `json:"attempts"`
	} `json:"build_fix_stats"`
	RecoveryRouting struct {
		RouteTaken string `json:"route_taken"`
	} `json:"recovery_routing"`
}

// ParseRunSummaries returns up to depth most-recent runs. Prefers
// metrics.jsonl (one record per line); falls back to RUN_SUMMARY_*.json files
// in dir. metricsFile and summariesDir may both be empty — empty inputs
// return an empty slice (not nil) so the caller's JSON output is stable.
//
// depth ≤ 0 means "no limit" (the Python bash path used `lines[-depth:]`
// which on 0 would slice empty; the Go port treats 0 the same way the
// downstream emit_metrics.go default behaves — fall back to depth=50).
func (r *StatusReader) ParseRunSummaries(metricsFile, summariesDir string, depth int) ([]proto.DashboardRunSummary, error) {
	if depth <= 0 {
		depth = 50
	}
	if metricsFile == "" && r.LogDir != "" {
		metricsFile = filepath.Join(r.LogDir, "metrics.jsonl")
	}
	if summariesDir == "" {
		summariesDir = r.LogDir
	}

	if rows := parseMetricsJSONL(metricsFile, depth); len(rows) > 0 {
		return rows, nil
	}
	return parseRunSummaryFiles(summariesDir, depth), nil
}

// parseMetricsJSONL reads metrics.jsonl line by line, decodes the
// most-recent `depth` lines, and converts each surviving record into a
// DashboardRunSummary. The bash filter rule applies: records with
// total_turns == 0 are dropped (crash/noise records). Returned slice is
// newest-first.
func parseMetricsJSONL(path string, depth int) []proto.DashboardRunSummary {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer func() { _ = f.Close() }()

	var lines []string
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		lines = append(lines, line)
	}
	// Python semantics: take last `depth` lines before zero-turn filter.
	if len(lines) > depth {
		lines = lines[len(lines)-depth:]
	}

	out := []proto.DashboardRunSummary{}
	for _, line := range lines {
		var rec metricsRecord
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			continue
		}
		if rec.TotalTurns == 0 {
			continue
		}
		out = append(out, recordToSummary(&rec))
	}
	// Bash reverses so newest is first.
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

// recordToSummary applies the bash Python derivation rules:
//   - run_type derived from milestone_mode + task_type
//   - stages map built from per-stage turn + duration + budget fields,
//     keeping only stages with turns > 0
//   - reviewer.cycles and security.rework_cycles attached when populated
//   - missing durations estimated proportionally from total_time_s
//   - task_label = task[:80]
func recordToSummary(rec *metricsRecord) proto.DashboardRunSummary {
	runType := "adhoc"
	if rec.MilestoneMode {
		runType = "milestone"
	} else {
		switch rec.TaskType {
		case "bug":
			runType = "human_bug"
		case "feature":
			runType = "human_feat"
		case "polish":
			runType = "human_polish"
		case "drift":
			runType = "drift"
		}
	}

	stages := map[string]proto.DashboardRunSummaryStage{}
	for _, name := range stageNames {
		turns, dur, budget := stageMetricsFor(rec, name)
		if turns <= 0 {
			continue
		}
		entry := proto.DashboardRunSummaryStage{
			Turns:     turns,
			DurationS: dur,
			Budget:    budget,
		}
		if name == "reviewer" && rec.ReviewCycles > 0 {
			entry.Cycles = rec.ReviewCycles
		}
		if name == "security" && rec.SecurityReworkCycles > 0 {
			entry.ReworkCycles = rec.SecurityReworkCycles
		}
		stages[name] = entry
	}

	estimateMissingDurations(rec.TotalTimeS, stages)

	outcome := rec.Outcome
	if outcome == "" {
		outcome = "unknown"
	}
	taskLabel := rec.Task
	if len(taskLabel) > 80 {
		taskLabel = taskLabel[:80]
	}
	return proto.DashboardRunSummary{
		Outcome:    outcome,
		TotalTurns: rec.TotalTurns,
		TotalTimeS: rec.TotalTimeS,
		Milestone:  "",
		RunType:    runType,
		TaskLabel:  taskLabel,
		Timestamp:  rec.Timestamp,
		Stages:     stages,
	}
}

// stageMetricsFor returns (turns, duration_s, budget) for a named stage by
// reading the corresponding fields off the record.
func stageMetricsFor(rec *metricsRecord, name string) (turns, dur, budget int) {
	switch name {
	case "coder":
		return rec.CoderTurns, rec.CoderDurationS, rec.AdjustedCoder
	case "reviewer":
		return rec.ReviewerTurns, rec.ReviewerDurationS, rec.AdjustedReviewer
	case "tester":
		return rec.TesterTurns, rec.TesterDurationS, rec.AdjustedTester
	case "scout":
		return rec.ScoutTurns, rec.ScoutDurationS, 0
	case "security":
		return rec.SecurityTurns, rec.SecurityDurationS, 0
	case "cleanup":
		return rec.CleanupTurns, rec.CleanupDurationS, 0
	case "test_audit":
		return rec.TestAuditTurns, rec.TestAuditDurationS, 0
	case "analyze_cleanup":
		return rec.AnalyzeCleanupTurns, rec.AnalyzeCleanupDurationS, 0
	case "specialist_security":
		return rec.SpecialistSecurityTurns, 0, 0
	case "specialist_perf":
		return rec.SpecialistPerfTurns, 0, 0
	case "specialist_api":
		return rec.SpecialistAPITurns, 0, 0
	}
	return 0, 0, 0
}

// estimateMissingDurations distributes total_time_s proportionally across
// stages when none of them carry a duration. Mirrors the bash Python branch
// at dashboard_parsers_runs.sh:94-100.
func estimateMissingDurations(totalTimeS int, stages map[string]proto.DashboardRunSummaryStage) {
	if totalTimeS <= 0 || len(stages) == 0 {
		return
	}
	hasAny := false
	totalTurns := 0
	for _, s := range stages {
		if s.DurationS > 0 {
			hasAny = true
		}
		totalTurns += s.Turns
	}
	if hasAny || totalTurns <= 0 {
		return
	}
	for name, s := range stages {
		s.DurationS = (totalTimeS*s.Turns + totalTurns/2) / totalTurns
		stages[name] = s
	}
}

// parseRunSummaryFiles is the legacy RUN_SUMMARY_*.json fallback path. Read
// files newest-first by name (filenames embed timestamp), up to `depth`,
// then reverse so the result is newest-first.
//
// No zero-turn filter applies here — RUN_SUMMARY_*.json files are written
// only on successful pipeline completion by finalize hooks; unlike
// metrics.jsonl, they do not accumulate crash records.
func parseRunSummaryFiles(dir string, depth int) []proto.DashboardRunSummary {
	if dir == "" {
		return []proto.DashboardRunSummary{}
	}
	matches, err := filepath.Glob(filepath.Join(dir, "RUN_SUMMARY_*.json"))
	if err != nil || len(matches) == 0 {
		return []proto.DashboardRunSummary{}
	}
	// Sort descending (newest first) — filenames embed timestamps so
	// string-sort matches time-sort.
	sort.Sort(sort.Reverse(sort.StringSlice(matches)))
	if len(matches) > depth {
		matches = matches[:depth]
	}
	out := make([]proto.DashboardRunSummary, 0, len(matches))
	for _, m := range matches {
		data, err := os.ReadFile(m)
		if err != nil {
			continue
		}
		var rec runSummaryFile
		if err := json.Unmarshal(data, &rec); err != nil {
			continue
		}
		out = append(out, fileToSummary(&rec))
	}
	return out
}

// fileToSummary maps the legacy RUN_SUMMARY_*.json field shape into the
// canonical DashboardRunSummary. Handles the M132 enrichment fields
// (recovery_route, build_fix_outcome) and the field-name fallback for
// total_turns / total_time_s (legacy filenames used total_agent_calls /
// wall_clock_seconds).
func fileToSummary(rec *runSummaryFile) proto.DashboardRunSummary {
	totalTurns := rec.TotalTurns
	if totalTurns == 0 {
		totalTurns = rec.TotalAgentCalls
	}
	totalTimeS := rec.TotalTimeS
	if totalTimeS == 0 {
		totalTimeS = rec.WallClockS
	}
	outcome := rec.Outcome
	if outcome == "" {
		outcome = "unknown"
	}
	runType := rec.RunType
	if runType == "" {
		runType = "adhoc"
	}
	stages := rec.Stages
	if stages == nil {
		stages = map[string]proto.DashboardRunSummaryStage{}
	}
	out := proto.DashboardRunSummary{
		Outcome:    outcome,
		TotalTurns: totalTurns,
		TotalTimeS: totalTimeS,
		Milestone:  rec.Milestone,
		RunType:    runType,
		TaskLabel:  rec.TaskLabel,
		Timestamp:  rec.Timestamp,
		Team:       rec.Team,
		Stages:     stages,
	}
	if rec.RecoveryRouting.RouteTaken != "" {
		out.RecoveryRoute = rec.RecoveryRouting.RouteTaken
	} else {
		out.RecoveryRoute = "save_exit"
	}
	if rec.BuildFixStats.Outcome != "" {
		out.BuildFixOutcome = rec.BuildFixStats.Outcome
	} else {
		out.BuildFixOutcome = "not_run"
	}
	return out
}
