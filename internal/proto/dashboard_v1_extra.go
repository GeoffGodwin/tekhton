// Continuation of dashboard_v1.go — metrics, health, diagnosis, inbox,
// notes, init, and action-items payload structs. Split out so the primary
// proto file stays under the 600-line soft target.

package proto

import (
	"encoding/json"
	"fmt"
)

// --- Metrics -----------------------------------------------------------------

// DashboardRunSummaryStage is one stage entry inside a per-run summary.
// Field shape mirrors lib/dashboard_parsers_runs.sh.
type DashboardRunSummaryStage struct {
	Name      string `json:"name"`
	Status    string `json:"status,omitempty"`
	Turns     int    `json:"turns"`
	Budget    int    `json:"budget,omitempty"`
	DurationS int    `json:"duration_s"`
}

// DashboardRunSummary is one entry of the metrics.js runs array. The bash
// parser reads either metrics.jsonl (M21+ canonical) or per-run
// RUN_SUMMARY_*.json files (fallback). Field grouping matches the JSONL
// record shape.
type DashboardRunSummary struct {
	Timestamp string                     `json:"timestamp"`
	Task      string                     `json:"task"`
	Milestone string                     `json:"milestone,omitempty"`
	Status    string                     `json:"status"`
	Stages    []DashboardRunSummaryStage `json:"stages,omitempty"`
	Turns     int                        `json:"turns"`
	DurationS int                        `json:"duration_s"`
}

// DashboardMetricsV1 is the metrics.js payload.
type DashboardMetricsV1 struct {
	Runs []DashboardRunSummary `json:"runs"`
}

func (p *DashboardMetricsV1) Validate() error { return nil }

// --- Health ------------------------------------------------------------------

// DashboardHealthV1 is the health.js payload. When the project has no
// HEALTH_BASELINE.json yet, the emitter writes `{"available":false}`.
// When present, `data` carries the baseline file's JSON contents verbatim
// (passed through as json.RawMessage so the byte-level shape is preserved).
type DashboardHealthV1 struct {
	Available bool            `json:"available"`
	Belt      string          `json:"belt,omitempty"`
	Data      json.RawMessage `json:"data,omitempty"`
}

func (p *DashboardHealthV1) Validate() error {
	if !p.Available && len(p.Data) > 0 {
		return fmt.Errorf("%w: health payload available=false but data is non-empty", ErrDashboardInvalid)
	}
	return nil
}

// --- Diagnosis ---------------------------------------------------------------

// DashboardDiagnosisV1 is the diagnosis.js payload. When no failure
// diagnosis is available, the file holds `{"available":false}`. When the
// failure-context hook fires, the bash emit function (TBD — not in m33.1
// scope but its slot must exist) populates the structured fields.
type DashboardDiagnosisV1 struct {
	Available      bool   `json:"available"`
	Classification string `json:"classification,omitempty"`
	Stage          string `json:"stage,omitempty"`
	Summary        string `json:"summary,omitempty"`
}

func (p *DashboardDiagnosisV1) Validate() error { return nil }

// --- Inbox -------------------------------------------------------------------

// DashboardInboxItem is one row of the inbox.js items array — a Watchtower
// inbox submission (note, milestone, or task).
type DashboardInboxItem struct {
	Type      string `json:"type"`
	Title     string `json:"title"`
	Filename  string `json:"filename"`
	Submitted string `json:"submitted"`
}

// DashboardInboxV1 is the inbox.js payload.
type DashboardInboxV1 struct {
	Items []DashboardInboxItem `json:"items"`
}

func (p *DashboardInboxV1) Validate() error { return nil }

// --- Notes -------------------------------------------------------------------

// DashboardNote is one row of the notes.js array — a structured human-note
// view including M40/M41/M42 metadata.
type DashboardNote struct {
	ID                string `json:"id"`
	Tag               string `json:"tag"`
	Title             string `json:"title"`
	Description       string `json:"description"`
	Status            string `json:"status"`
	Priority          string `json:"priority"`
	Source            string `json:"source"`
	Created           string `json:"created"`
	TriageDisposition string `json:"triage_disposition"`
	EstimatedTurns    string `json:"estimated_turns"`
	TriagedAt         string `json:"triaged_at"`
	Promoted          string `json:"promoted"`
	AcceptanceResult  string `json:"acceptance_result"`
	CompletedAt       string `json:"completed_at"`
	TurnsUsed         string `json:"turns_used"`
	ReviewerSkipped   string `json:"reviewer_skipped"`
	RCAPresent        bool   `json:"rca_present"`
}

// DashboardNotesV1 is the notes.js payload — a bare JSON array.
type DashboardNotesV1 struct {
	Notes []DashboardNote
}

func (p DashboardNotesV1) MarshalJSON() ([]byte, error) {
	if p.Notes == nil {
		return []byte("[]"), nil
	}
	return json.Marshal(p.Notes)
}

func (p *DashboardNotesV1) Validate() error {
	for i, n := range p.Notes {
		switch n.Status {
		case "open", "claimed", "done", "":
			// "" is tolerated for round-trip; the emitter sets one of three.
		default:
			return fmt.Errorf("%w: notes[%d].status=%q must be open|claimed|done", ErrDashboardInvalid, i, n.Status)
		}
	}
	return nil
}

// --- Init --------------------------------------------------------------------

// DashboardInitV1 is the init.js payload — metadata extracted from
// INIT_REPORT.md's HTML comment block.
type DashboardInitV1 struct {
	Available   bool   `json:"available"`
	Timestamp   string `json:"timestamp"`
	Project     string `json:"project"`
	FileCount   string `json:"fileCount"`
	ProjectType string `json:"projectType"`
}

func (p *DashboardInitV1) Validate() error { return nil }

// --- Action items ------------------------------------------------------------

// DashboardSeverityCount is the {count,severity} pair used inside
// DashboardActionItemsV1 for nonblocking + human_notes.
type DashboardSeverityCount struct {
	Count    int    `json:"count"`
	Severity string `json:"severity"`
}

// DashboardCount is the {count} singleton used for drift + human_actions.
type DashboardCount struct {
	Count int `json:"count"`
}

// DashboardActionItemsV1 is the action_items.js payload — severity-annotated
// counts for the dashboard's status badge row.
type DashboardActionItemsV1 struct {
	Nonblocking  DashboardSeverityCount `json:"nonblocking"`
	HumanNotes   DashboardSeverityCount `json:"human_notes"`
	Drift        DashboardCount         `json:"drift"`
	HumanActions DashboardCount         `json:"human_actions"`
}

func (p *DashboardActionItemsV1) Validate() error {
	for _, name := range []string{p.Nonblocking.Severity, p.HumanNotes.Severity} {
		switch name {
		case "normal", "warning", "critical", "":
		default:
			return fmt.Errorf("%w: severity=%q must be normal|warning|critical", ErrDashboardInvalid, name)
		}
	}
	return nil
}

// --- Draft milestones --------------------------------------------------------

// DashboardDraftMilestonesV1 is the draft_milestones.js payload — a bare
// JSON array (currently always empty; full Watchtower UI integration is a
// future V4 milestone).
type DashboardDraftMilestonesV1 struct {
	Entries []json.RawMessage
}

func (p DashboardDraftMilestonesV1) MarshalJSON() ([]byte, error) {
	if p.Entries == nil {
		return []byte("[]"), nil
	}
	return json.Marshal(p.Entries)
}

func (p *DashboardDraftMilestonesV1) Validate() error { return nil }
