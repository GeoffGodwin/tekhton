// Dashboard data-file payload contracts (m33.1).
//
// The Watchtower dashboard is a static HTML/JS surface served from
// .claude/dashboard/. Its 10 *.js data files are JSON payloads wrapped in
// `window.<TK_VAR> = <json>;` scaffolding so the browser can `<script>`-load
// them without a server. The bash dashboard emitters (lib/dashboard.sh,
// lib/dashboard_emitters.sh) hand-built the JSON via printf concatenation
// with no schema. m33.1 freezes the shapes as typed Go structs so the
// emitter (this milestone) and the parser (m33.2) round-trip against the
// same contract.
//
// Versioning. Field additions within v1 are additive; renames or removals
// bump the proto tag. The JS reader (`templates/watchtower/app.js`) treats
// missing fields defensively, so adding new fields is safe.

package proto

import (
	"encoding/json"
	"errors"
	"fmt"
)

// DashboardV1 is the wire identifier for the v1 dashboard data envelope.
// The on-disk files do NOT embed this constant — they are wrapped JS — but
// the runtime carries it so future schema variants can be flagged.
const DashboardV1 = "tekhton.dashboard.v1"

// JS window-variable names. The browser reader (templates/watchtower/app.js)
// addresses each payload through one of these globals, so they are part of
// the contract.
const (
	DashboardVarRunState   = "TK_RUN_STATE"
	DashboardVarTimeline   = "TK_TIMELINE"
	DashboardVarMilestones = "TK_MILESTONES"
	DashboardVarSecurity   = "TK_SECURITY"
	DashboardVarReports    = "TK_REPORTS"
	DashboardVarMetrics    = "TK_METRICS"
	DashboardVarHealth     = "TK_HEALTH"
	DashboardVarDiagnosis  = "TK_DIAGNOSIS"
	DashboardVarInbox      = "TK_INBOX"
	DashboardVarNotes      = "TK_NOTES"

	// Auxiliary files emitted by the inbox-family quartet but not in the
	// 10-kind core. Kept here so m33.2 / V5 sees one source of truth.
	DashboardVarInit            = "TK_INIT"
	DashboardVarActionItems     = "TK_ACTION_ITEMS"
	DashboardVarDraftMilestones = "TK_DRAFT_MILESTONES"
)

// Validation: the legal pipeline_status vocabulary the bash emitter writes.
// Anything else is a producer bug, not a wire-format change.
var validPipelineStatuses = map[string]struct{}{
	"initializing": {},
	"running":      {},
	"success":      {},
	"failed":       {},
	"paused":       {},
}

// ErrDashboardInvalid is the sentinel returned by Validate() methods when a
// payload would emit a JS file the static reader can't parse. Wrapped via
// fmt.Errorf("%w: ...") so callers can errors.Is against it.
var ErrDashboardInvalid = errors.New("dashboard payload invalid")

// --- Run state ---------------------------------------------------------------

// DashboardStageState mirrors the per-stage entry inside DashboardRunStateV1.
// Bash emits these as a string-keyed object (`{"intake": {...}}`) keyed by
// stage name; the wire representation is a map, not an array, so the JS
// reader can address `data.stages.intake.status` directly.
type DashboardStageState struct {
	Status    string `json:"status"`
	Turns     int    `json:"turns"`
	Budget    int    `json:"budget"`
	DurationS int    `json:"duration_s"`
}

// DashboardMilestoneRef is the {id,title} pair embedded in run_state.js as
// active_milestone. Bash emits `null` when there is no active milestone; the
// Go side uses a pointer so the marshaled value is `null` exactly when the
// caller leaves it unset.
type DashboardMilestoneRef struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

// DashboardTeamState is the per-team payload embedded in the run_state.js
// teams map under M37 parallel mode. Mirrors the bash _TEAM_* arrays.
type DashboardTeamState struct {
	Milestone    *DashboardMilestoneRef         `json:"milestone"`
	CurrentStage string                         `json:"current_stage"`
	Stages       map[string]DashboardStageState `json:"stages"`
	Status       string                         `json:"status"`
	StartedAt    string                         `json:"started_at"`
}

// DashboardRunStateV1 is the run_state.js payload — the single most-read
// dashboard file. Updated on every stage transition and on the finalize
// hook. JSON field order follows the bash printf format string in
// lib/dashboard.sh:276 byte-for-byte so the parity gate diffs cleanly.
type DashboardRunStateV1 struct {
	PipelineStatus      string                         `json:"pipeline_status"`
	CurrentStage        string                         `json:"current_stage"`
	ActiveMilestone     *DashboardMilestoneRef         `json:"active_milestone"`
	Stages              map[string]DashboardStageState `json:"stages"`
	WaitingFor          *string                        `json:"waiting_for"`
	StartedAt           string                         `json:"started_at"`
	CompletedAt         *string                        `json:"completed_at"`
	ElapsedS            int                            `json:"elapsed_s"`
	EstimatedRemainingS *int                           `json:"estimated_remaining_s"`
	RefreshIntervalMs   int                            `json:"refresh_interval_ms"`
	QuotaStatus         string                         `json:"quota_status"`
	QuotaPausedAt       string                         `json:"quota_paused_at"`
	QuotaRetryCount     int                            `json:"quota_retry_count"`
	ParallelMode        bool                           `json:"parallel_mode"`
	Teams               map[string]DashboardTeamState  `json:"teams"`
}

// Validate enforces the pipeline_status vocabulary and the
// elapsed/refresh-interval ranges. Run from tests; the emitter trusts its
// own field population on the hot path.
func (p *DashboardRunStateV1) Validate() error {
	if _, ok := validPipelineStatuses[p.PipelineStatus]; !ok {
		return fmt.Errorf("%w: pipeline_status=%q not in {initializing,running,success,failed,paused}",
			ErrDashboardInvalid, p.PipelineStatus)
	}
	if p.RefreshIntervalMs < 0 {
		return fmt.Errorf("%w: refresh_interval_ms=%d must be >= 0", ErrDashboardInvalid, p.RefreshIntervalMs)
	}
	if p.ElapsedS < 0 {
		return fmt.Errorf("%w: elapsed_s=%d must be >= 0", ErrDashboardInvalid, p.ElapsedS)
	}
	return nil
}

// --- Timeline ----------------------------------------------------------------

// DashboardTimelineV1 is the timeline.js payload — a passthrough array of
// causal-log event lines, capped at DASHBOARD_MAX_TIMELINE_EVENTS and
// filtered by DASHBOARD_VERBOSITY. Each element is the raw JSON object
// (NOT re-decoded), preserving byte-for-byte the event line the causal-log
// writer emitted.
type DashboardTimelineV1 struct {
	Events []json.RawMessage
}

// MarshalJSON emits the events as a bare JSON array (not wrapped in an
// object) to match the bash output shape.
func (p DashboardTimelineV1) MarshalJSON() ([]byte, error) {
	if p.Events == nil {
		return []byte("[]"), nil
	}
	return json.Marshal(p.Events)
}

// Validate is a no-op — every passthrough line is opaque to us. Kept for
// interface symmetry with the other payload types.
func (p *DashboardTimelineV1) Validate() error { return nil }

// --- Milestones --------------------------------------------------------------

// DashboardMilestoneEntry is one row of the milestones.js array. Mirrors
// the bash printf shape in lib/dashboard_emitters.sh:192 byte-for-byte
// (depends_on / parallel_group as strings, not arrays — the bash writer
// stringifies the manifest CSV directly).
type DashboardMilestoneEntry struct {
	ID            string `json:"id"`
	Title         string `json:"title"`
	Status        string `json:"status"`
	DependsOn     string `json:"depends_on"`
	ParallelGroup string `json:"parallel_group"`
	Summary       string `json:"summary"`
	Enables       string `json:"enables"`
}

// DashboardMilestonesV1 is the milestones.js payload — an array of manifest
// rows enriched with summary (extracted from the milestone .md file's
// ## Overview block) and enables (reverse-dependency map computed at emit
// time).
type DashboardMilestonesV1 struct {
	Entries []DashboardMilestoneEntry
}

func (p DashboardMilestonesV1) MarshalJSON() ([]byte, error) {
	if p.Entries == nil {
		return []byte("[]"), nil
	}
	return json.Marshal(p.Entries)
}

func (p *DashboardMilestonesV1) Validate() error { return nil }

// --- Security ----------------------------------------------------------------

// DashboardFinding is one row of the security.js findings array. Bash
// extracts severity by case-insensitive substring grep and category by
// regex; both are passed through verbatim from those greps.
type DashboardFinding struct {
	Severity string `json:"severity"`
	Category string `json:"category"`
	Detail   string `json:"detail"`
}

// DashboardSecurityV1 is the security.js payload — an object with one
// `findings` field. Bash wraps the array in {"findings": [...]}.
type DashboardSecurityV1 struct {
	Findings []DashboardFinding `json:"findings"`
}

func (p *DashboardSecurityV1) Validate() error {
	if p.Findings == nil {
		// Bash emits "findings":[] not "findings":null; the empty slice is
		// the contract.
		return nil
	}
	return nil
}

// --- Reports -----------------------------------------------------------------

// DashboardIntakeReport mirrors lib/dashboard_parsers.sh:_parse_intake_report.
// Verdict is a free-form string ("PASS"/"REJECT"/"unknown"); confidence is a
// 0–100 integer that bash writes unquoted.
type DashboardIntakeReport struct {
	Verdict    string `json:"verdict"`
	Confidence int    `json:"confidence"`
	TaskText   string `json:"task_text,omitempty"`
}

// DashboardCoderReport mirrors lib/dashboard_parsers.sh:_parse_coder_summary.
type DashboardCoderReport struct {
	Status        string `json:"status"`
	FilesModified int    `json:"files_modified"`
}

// DashboardReviewerReport mirrors lib/dashboard_parsers.sh:_parse_reviewer_report.
type DashboardReviewerReport struct {
	Verdict string `json:"verdict"`
}

// DashboardTestAudit is the test_audit slot of reports.js, populated from
// TEST_AUDIT_REPORT.md via grep.
type DashboardTestAudit struct {
	Verdict         string `json:"verdict"`
	HighFindings    int    `json:"high_findings"`
	MediumFindings  int    `json:"medium_findings"`
}

// DashboardNotesBacklog is the backlog summary embedded in reports.js,
// produced by lib/notes_*.sh `get_notes_summary` (pipe-delimited 6-tuple).
type DashboardNotesBacklog struct {
	Total     int `json:"total"`
	Bug       int `json:"bug"`
	Feat      int `json:"feat"`
	Polish    int `json:"polish"`
	Checked   int `json:"checked"`
	Unchecked int `json:"unchecked"`
}

// DashboardTeamReports is one entry of the reports.js teams map under M37
// parallel mode.
type DashboardTeamReports struct {
	Intake   DashboardIntakeReport   `json:"intake"`
	Coder    DashboardCoderReport    `json:"coder"`
	Reviewer DashboardReviewerReport `json:"reviewer"`
}

// DashboardReportsV1 is the reports.js payload — the composite stage-report
// summary shown in the dashboard's Reports tab.
type DashboardReportsV1 struct {
	Intake    DashboardIntakeReport            `json:"intake"`
	Coder     DashboardCoderReport             `json:"coder"`
	Reviewer  DashboardReviewerReport          `json:"reviewer"`
	TestAudit DashboardTestAudit               `json:"test_audit"`
	Backlog   DashboardNotesBacklog            `json:"backlog"`
	Teams     map[string]DashboardTeamReports  `json:"teams"`
}

func (p *DashboardReportsV1) Validate() error { return nil }

// --- Metrics / Health / Diagnosis / Inbox / Notes / Init / ActionItems ------
// (Continued in dashboard_v1_extra.go to keep this file under the 600-line
// soft target — Go file-length guidance per CLAUDE.md.)
