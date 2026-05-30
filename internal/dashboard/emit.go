// emit.go — Emitter type + NewEmitter constructor. Reads inputs from the
// environment (env vars and config map) so subprocesses get a stable view
// regardless of whether the parent bash dispatcher exported every global.

package dashboard

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// pipelineStages is the canonical stage list bash iterates over in
// emit_dashboard_run_state. Must stay in this order — the JSON map is
// keyed by stage name, not array index, but iteration order determines
// the key emission sequence used by the parity gate.
var pipelineStages = []string{"intake", "scout", "coder", "build_gate", "security", "reviewer", "tester"}

// Emitter owns the one-emit-per-call workflow for a single dashboard
// directory. Construct one per `tekhton dashboard emit ...` invocation;
// keep around between emits within the same process when convenient.
//
// Inputs are populated from the calling process environment by
// NewEmitter. Tests construct Emitters directly with the relevant fields
// populated.
type Emitter struct {
	// File-system layout.
	ProjectDir   string
	DashDir      string // absolute path
	LogDir       string
	TemplatesDir string

	// Lifecycle gate.
	Enabled bool

	// Run-state inputs (read from env vars set by the bash caller before
	// exec). All optional — empty values cascade to bash defaults.
	PipelineStatus    string
	CurrentStage      string
	CurrentMilestone  string
	MilestoneTitle    string
	StartedAt         string
	WaitingFor        string
	QuotaPaused       bool
	QuotaPausedAt     string
	QuotaPauseCount   int
	DashboardRefresh  int // seconds
	MaxTimelineEvents int
	HistoryDepth      int
	Verbosity         string
	ElapsedSeconds    int

	// Per-stage state. The bash caller flattens its associative arrays
	// into env vars with names like `_STAGE_STATUS_intake`,
	// `_STAGE_TURNS_coder`, etc. Empty map values cascade to the
	// pending/zero defaults the bash emitter falls back to.
	StageStatus   map[string]string
	StageTurns    map[string]int
	StageBudget   map[string]int
	StageDuration map[string]int

	// Parallel-mode (M37) inputs. Empty ParallelTeams means parallel_mode
	// is off, matching bash semantics.
	ParallelTeams      []string
	TeamMilestone      map[string]string
	TeamMilestoneTitle map[string]string
	TeamStage          map[string]string
	TeamStatus         map[string]string
	TeamStarted        map[string]string
	TeamStageStatus    map[string]string // key "<team>:<stage>"
	TeamStageTurns     map[string]int
	TeamStageBudget    map[string]int
	TeamStageDuration  map[string]int

	// Report file paths — sourced from env, default to project-relative
	// locations.
	SecurityReportFile  string
	IntakeReportFile    string
	CoderSummaryFile    string
	ReviewerReportFile  string
	TestAuditReportFile string
	HumanNotesFile      string
	HealthBaselineFile  string
	DriftLogFile        string
	HumanActionFile     string
	InitReportFile      string
	CausalLogFile       string
	ManifestPath        string
	MilestoneDir        string

	// Time source. Injected for tests; defaults to time.Now.
	Now func() time.Time

	// reader is the parser dispatcher (m33.2). NewEmitter constructs one;
	// tests that construct an Emitter directly may leave it nil — the
	// parsers use the no-arg StatusReader form, which works because the
	// readers themselves are pure on input.
	reader *StatusReader
}

// NewEmitter reads the bash-flattened environment and returns a populated
// Emitter. The constructor is pure — no I/O, no filesystem checks. Call
// sites that need a populated Emitter from a non-default cwd pass
// projectDir explicitly; an empty string falls back to $PWD.
func NewEmitter(projectDir string) *Emitter {
	if projectDir == "" {
		projectDir, _ = os.Getwd()
	}
	dashDirRel := envOr("DASHBOARD_DIR", ".claude/dashboard")
	logDirRel := envOr("LOG_DIR", ".claude/logs")

	e := &Emitter{
		ProjectDir:        projectDir,
		DashDir:           filepath.Join(projectDir, dashDirRel),
		LogDir:            absPath(projectDir, logDirRel),
		TemplatesDir:      templatesDirFromHome(),
		Enabled:           Enabled(envOr("DASHBOARD_ENABLED", "true")),
		PipelineStatus:    envOr("PIPELINE_STATUS", "running"),
		CurrentStage:      envOr("CURRENT_STAGE", "unknown"),
		CurrentMilestone:  envOr("_CURRENT_MILESTONE", ""),
		MilestoneTitle:    envOr("_CURRENT_MILESTONE_TITLE", ""),
		StartedAt:         envOr("START_AT_TS", ""),
		WaitingFor:        envOr("WAITING_FOR", ""),
		QuotaPaused:       envOr("_QUOTA_PAUSED", "false") == "true",
		QuotaPausedAt:     envOr("_QUOTA_PAUSED_AT", ""),
		QuotaPauseCount:   envInt("_QUOTA_PAUSE_COUNT", 0),
		DashboardRefresh:  envInt("DASHBOARD_REFRESH_INTERVAL", 5),
		MaxTimelineEvents: envInt("DASHBOARD_MAX_TIMELINE_EVENTS", 500),
		HistoryDepth:      envInt("DASHBOARD_HISTORY_DEPTH", 50),
		Verbosity:         envOr("DASHBOARD_VERBOSITY", "normal"),
		ElapsedSeconds:    envInt("SECONDS", 0),

		StageStatus:   readStageStringMap("_STAGE_STATUS"),
		StageTurns:    readStageIntMap("_STAGE_TURNS"),
		StageBudget:   readStageIntMap("_STAGE_BUDGET"),
		StageDuration: readStageIntMap("_STAGE_DURATION"),

		SecurityReportFile:  envPath(projectDir, "SECURITY_REPORT_FILE", ".tekhton/SECURITY_REPORT.md"),
		IntakeReportFile:    envPath(projectDir, "INTAKE_REPORT_FILE", ".tekhton/INTAKE_REPORT.md"),
		CoderSummaryFile:    envPath(projectDir, "CODER_SUMMARY_FILE", ".tekhton/CODER_SUMMARY.md"),
		ReviewerReportFile:  envPath(projectDir, "REVIEWER_REPORT_FILE", ".tekhton/REVIEWER_REPORT.md"),
		TestAuditReportFile: envPath(projectDir, "TEST_AUDIT_REPORT_FILE", ".tekhton/TEST_AUDIT_REPORT.md"),
		HumanNotesFile:      envPath(projectDir, "HUMAN_NOTES_FILE", ".tekhton/HUMAN_NOTES.md"),
		HealthBaselineFile:  envPath(projectDir, "HEALTH_BASELINE_FILE", ".claude/HEALTH_BASELINE.json"),
		DriftLogFile:        envPath(projectDir, "DRIFT_LOG_FILE", ".tekhton/DRIFT_LOG.md"),
		HumanActionFile:     envPath(projectDir, "HUMAN_ACTION_FILE", "HUMAN_ACTION_REQUIRED.md"),
		InitReportFile:      filepath.Join(projectDir, "INIT_REPORT.md"),
		CausalLogFile:       envPath(projectDir, "CAUSAL_LOG_FILE", ".claude/logs/CAUSAL_LOG.jsonl"),
		MilestoneDir:        envPath(projectDir, "MILESTONE_DIR", ".claude/milestones"),

		Now: time.Now,
	}
	e.ManifestPath = filepath.Join(e.MilestoneDir, envOr("MILESTONE_MANIFEST", "MANIFEST.cfg"))
	e.populateParallelMode()
	e.reader = NewStatusReader(e)
	return e
}

// statusReader returns the Emitter's StatusReader, lazily constructing one
// when nil (the test fixtures construct Emitters directly without going
// through NewEmitter). Pure dispatcher; no I/O.
func (e *Emitter) statusReader() *StatusReader {
	if e.reader == nil {
		e.reader = NewStatusReader(e)
	}
	return e.reader
}

// populateParallelMode parses the _PARALLEL_TEAMS env var (space- or
// comma-separated team ids) and reads each team's flattened state.
func (e *Emitter) populateParallelMode() {
	raw := envOr("_PARALLEL_TEAMS", "")
	if raw == "" {
		return
	}
	teams := splitTeams(raw)
	if len(teams) == 0 {
		return
	}
	e.ParallelTeams = teams
	e.TeamMilestone = make(map[string]string, len(teams))
	e.TeamMilestoneTitle = make(map[string]string, len(teams))
	e.TeamStage = make(map[string]string, len(teams))
	e.TeamStatus = make(map[string]string, len(teams))
	e.TeamStarted = make(map[string]string, len(teams))
	e.TeamStageStatus = make(map[string]string)
	e.TeamStageTurns = make(map[string]int)
	e.TeamStageBudget = make(map[string]int)
	e.TeamStageDuration = make(map[string]int)

	for _, team := range teams {
		e.TeamMilestone[team] = envOr("_TEAM_MILESTONE_"+team, "")
		e.TeamMilestoneTitle[team] = envOr("_TEAM_MILESTONE_TITLE_"+team, "")
		e.TeamStage[team] = envOr("_TEAM_STAGE_"+team, "unknown")
		e.TeamStatus[team] = envOr("_TEAM_STATUS_"+team, "pending")
		e.TeamStarted[team] = envOr("_TEAM_STARTED_"+team, "")
		for _, stage := range pipelineStages {
			key := team + ":" + stage
			e.TeamStageStatus[key] = envOr("_TEAM_STAGE_STATUS_"+team+"_"+stage, "pending")
			e.TeamStageTurns[key] = envInt("_TEAM_STAGE_TURNS_"+team+"_"+stage, 0)
			e.TeamStageBudget[key] = envInt("_TEAM_STAGE_BUDGET_"+team+"_"+stage, 0)
			e.TeamStageDuration[key] = envInt("_TEAM_STAGE_DURATION_"+team+"_"+stage, 0)
		}
	}
}

// readStageStringMap reads one env var per pipelineStages entry (e.g.
// `_STAGE_STATUS_intake`) and returns a populated map. Missing values are
// left out of the map; the caller substitutes per-stage defaults.
func readStageStringMap(prefix string) map[string]string {
	out := make(map[string]string, len(pipelineStages))
	for _, stage := range pipelineStages {
		if v, ok := os.LookupEnv(prefix + "_" + stage); ok {
			out[stage] = v
		}
	}
	return out
}

func readStageIntMap(prefix string) map[string]int {
	out := make(map[string]int, len(pipelineStages))
	for _, stage := range pipelineStages {
		if v, ok := os.LookupEnv(prefix + "_" + stage); ok {
			if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
				out[stage] = n
			}
		}
	}
	return out
}

func envOr(name, fallback string) string {
	if v, ok := os.LookupEnv(name); ok && v != "" {
		return v
	}
	return fallback
}

func envInt(name string, fallback int) int {
	v, ok := os.LookupEnv(name)
	if !ok || v == "" {
		return fallback
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		return fallback
	}
	return n
}

func envPath(projectDir, name, fallbackRel string) string {
	if v, ok := os.LookupEnv(name); ok && v != "" {
		return absPath(projectDir, v)
	}
	return filepath.Join(projectDir, fallbackRel)
}

func absPath(base, p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(base, p)
}

func templatesDirFromHome() string {
	home := os.Getenv("TEKHTON_HOME")
	if home == "" {
		return ""
	}
	return filepath.Join(home, "templates", "watchtower")
}

func splitTeams(raw string) []string {
	var out []string
	for _, candidate := range strings.FieldsFunc(raw, func(r rune) bool { return r == ',' || r == ' ' }) {
		if candidate != "" {
			out = append(out, candidate)
		}
	}
	return out
}
