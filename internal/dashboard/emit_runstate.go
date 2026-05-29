// emit_runstate.go — run_state.js emit + team-state delegate. Ports
// lib/dashboard.sh:126-308 (emit_dashboard_run_state +
// emit_dashboard_team_state).

package dashboard

import (
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EmitRunState writes data/run_state.js. No-op when Enabled is false or
// the data/ subdirectory does not yet exist.
func (e *Emitter) EmitRunState() error {
	if !e.Enabled {
		return nil
	}
	if !e.dataDirExists() {
		return nil
	}
	payload := e.buildRunStatePayload()
	return WriteJSFile(filepath.Join(e.DashDir, "data", "run_state.js"),
		proto.DashboardVarRunState, &payload, e.nowFn())
}

// EmitTeamState is the parallel-mode hook; bash form
// (lib/dashboard.sh:300) just delegates to EmitRunState because the
// per-team state lives in shared _TEAM_* env vars that EmitRunState
// already serializes. Kept as a distinct method for caller clarity.
func (e *Emitter) EmitTeamState(teamID string) error {
	if teamID == "" {
		return errEmptyTeamID
	}
	return e.EmitRunState()
}

// buildRunStatePayload assembles the typed payload from the Emitter's
// fields. Stage status / duration overrides follow bash semantics: a
// pending stage matching CurrentStage is upgraded to "active"; an active
// stage with a recorded StageStartTS gets duration_s replaced with the
// live elapsed value. (The StageStartTS map is read from
// `_STAGE_START_TS_<stage>` env vars only when the caller flattens them;
// the default zero leaves bash's `${SECONDS - ...}` no-op in place.)
func (e *Emitter) buildRunStatePayload() proto.DashboardRunStateV1 {
	stages := make(map[string]proto.DashboardStageState, len(pipelineStages))
	for _, stg := range pipelineStages {
		status := defaultIfEmpty(e.StageStatus[stg], "pending")
		if stg == e.CurrentStage && status == "pending" {
			status = "active"
		}
		stages[stg] = proto.DashboardStageState{
			Status:    status,
			Turns:     e.StageTurns[stg],
			Budget:    e.StageBudget[stg],
			DurationS: e.StageDuration[stg],
		}
	}

	var activeMS *proto.DashboardMilestoneRef
	if e.CurrentMilestone != "" {
		activeMS = &proto.DashboardMilestoneRef{
			ID:    e.CurrentMilestone,
			Title: e.MilestoneTitle,
		}
	}

	var waitingPtr *string
	if e.WaitingFor != "" {
		w := e.WaitingFor
		waitingPtr = &w
	}

	var completedAt *string
	if e.PipelineStatus == "success" || e.PipelineStatus == "failed" {
		ts := e.nowFn()().UTC().Format("2006-01-02T15:04:05Z")
		completedAt = &ts
	}

	elapsed := 0
	if e.StartedAt != "" {
		elapsed = e.ElapsedSeconds
	}

	quotaStatus := "ok"
	pausedAt := ""
	retryCount := 0
	if e.QuotaPaused {
		quotaStatus = "paused"
		pausedAt = e.QuotaPausedAt
		retryCount = e.QuotaPauseCount
	}

	return proto.DashboardRunStateV1{
		PipelineStatus:    defaultIfEmpty(e.PipelineStatus, "running"),
		CurrentStage:      defaultIfEmpty(e.CurrentStage, "unknown"),
		ActiveMilestone:   activeMS,
		Stages:            stages,
		WaitingFor:        waitingPtr,
		StartedAt:         e.StartedAt,
		CompletedAt:       completedAt,
		ElapsedS:          elapsed,
		RefreshIntervalMs: e.DashboardRefresh * 1000,
		QuotaStatus:       quotaStatus,
		QuotaPausedAt:     pausedAt,
		QuotaRetryCount:   retryCount,
		ParallelMode:      len(e.ParallelTeams) > 0,
		Teams:             e.buildTeamsMap(),
	}
}

// buildTeamsMap renders the parallel-mode teams payload from the
// Team* fields. Returns an empty map when not in parallel mode (bash
// emits `{}` literally, not null).
func (e *Emitter) buildTeamsMap() map[string]proto.DashboardTeamState {
	out := make(map[string]proto.DashboardTeamState, len(e.ParallelTeams))
	for _, team := range e.ParallelTeams {
		if team == "" {
			continue
		}
		stages := make(map[string]proto.DashboardStageState, len(pipelineStages))
		for _, stg := range pipelineStages {
			key := team + ":" + stg
			stages[stg] = proto.DashboardStageState{
				Status:    defaultIfEmpty(e.TeamStageStatus[key], "pending"),
				Turns:     e.TeamStageTurns[key],
				Budget:    e.TeamStageBudget[key],
				DurationS: e.TeamStageDuration[key],
			}
		}
		var ms *proto.DashboardMilestoneRef
		if id := e.TeamMilestone[team]; id != "" {
			ms = &proto.DashboardMilestoneRef{ID: id, Title: e.TeamMilestoneTitle[team]}
		}
		out[team] = proto.DashboardTeamState{
			Milestone:    ms,
			CurrentStage: defaultIfEmpty(e.TeamStage[team], "unknown"),
			Stages:       stages,
			Status:       defaultIfEmpty(e.TeamStatus[team], "pending"),
			StartedAt:    e.TeamStarted[team],
		}
	}
	return out
}
