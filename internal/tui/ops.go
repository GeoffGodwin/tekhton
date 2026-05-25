package tui

import (
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// StageBeginInput captures all the parameters needed to open a stage. Lives
// here so the CLI handler in cmd/tekhton/tui.go can construct it from flags
// without leaking Cobra concerns into internal/tui.
type StageBeginInput struct {
	Label string
	Model string
	// Num and Total are optional explicit overrides. When zero, the state
	// derives Num from the position of Label in stage_order.
	Num   int
	Total int
}

// StageBegin opens a stage on the state: allocates a fresh lifecycle id,
// records the start timestamp, and updates the current-stage fields. Returns
// the allocated lifecycle id so callers can capture it for later end calls.
func (s *State) StageBegin(in StageBeginInput, now time.Time) string {
	id := s.AllocateLifecycleID(in.Label)
	s.EnsureStageInOrder(in.Label)
	s.Payload.StageLabel = in.Label
	s.Payload.AgentModel = in.Model
	s.Payload.AgentTurnsUsed = 0
	s.Payload.AgentTurnsMax = 0
	s.Payload.AgentElapsedSecs = 0
	s.Payload.CurrentAgentStatus = "running"
	s.Payload.StageStartTS = now.Unix()

	if in.Num > 0 {
		s.Payload.StageNum = in.Num
	} else {
		for i, lbl := range s.Payload.StageOrder {
			if lbl == in.Label {
				s.Payload.StageNum = i + 1
				break
			}
		}
	}
	if in.Total > 0 {
		s.Payload.StageTotal = in.Total
	} else {
		s.Payload.StageTotal = len(s.Payload.StageOrder)
	}
	return id
}

// StageEndInput collects parameters for closing a stage.
type StageEndInput struct {
	Label   string
	Model   string
	Turns   string
	Time    string
	Verdict string
}

// StageEnd closes the currently open stage: freezes the timer, auto-closes
// any open substage (with a warning event), pushes a completion record onto
// stages_complete, and marks the closing lifecycle id as closed so late agent
// ticks bearing it are dropped.
func (s *State) StageEnd(in StageEndInput, now time.Time) {
	if s.Payload.CurrentSubstageLabel != "" {
		lbl := s.Payload.CurrentSubstageLabel
		s.Payload.CurrentSubstageLabel = ""
		s.Payload.CurrentSubstageStart = 0
		s.AppendEvent("warn", "[tui] substage '"+lbl+"' auto-closed by parent end", "runtime", "", now, 0)
	}
	if s.Payload.StageStartTS > 0 {
		elapsed := now.Unix() - s.Payload.StageStartTS
		if elapsed < 0 {
			elapsed = 0
		}
		s.Payload.AgentElapsedSecs = int(elapsed)
	}
	closingID := s.Payload.CurrentLifecycleID
	s.AppendStageEntry(in.Label, in.Model, in.Turns, in.Time, in.Verdict)
	if closingID != "" {
		s.MarkLifecycleClosed(closingID)
	}
	s.Payload.CurrentLifecycleID = ""
	s.Payload.StageStartTS = 0
	s.Payload.CurrentAgentStatus = "idle"
}

// UpdateStageInput supports the bash tui_update_stage signature.
type UpdateStageInput struct {
	Num   int
	Total int
	Label string
	Model string
}

// UpdateStage updates the current stage's identifiers without affecting the
// lifecycle id or stage_order.
func (s *State) UpdateStage(in UpdateStageInput, now time.Time) {
	if in.Num > 0 {
		s.Payload.StageNum = in.Num
	}
	if in.Total > 0 {
		s.Payload.StageTotal = in.Total
	}
	if in.Label != "" {
		s.Payload.StageLabel = in.Label
	}
	if in.Model != "" {
		s.Payload.AgentModel = in.Model
	}
	s.Payload.CurrentAgentStatus = "running"
	s.Payload.AgentTurnsUsed = 0
	s.Payload.AgentElapsedSecs = 0
	s.Payload.StageStartTS = now.Unix()
}

// UpdateAgentInput captures spinner tick parameters.
type UpdateAgentInput struct {
	TurnsUsed   int
	TurnsMax    int
	ElapsedSecs int
	// LifecycleID is the captured owner id. When non-empty and it no longer
	// matches the current owner (stage ended), the update is dropped.
	LifecycleID string
}

// UpdateAgent ticks the spinner counters. Drops late updates whose lifecycle
// id no longer matches the current owner. Returns true when the update was
// applied, false when dropped.
func (s *State) UpdateAgent(in UpdateAgentInput) bool {
	if in.LifecycleID != "" {
		if in.LifecycleID != s.Payload.CurrentLifecycleID {
			return false
		}
		if s.IsLifecycleClosed(in.LifecycleID) {
			return false
		}
	}
	s.Payload.AgentTurnsUsed = in.TurnsUsed
	s.Payload.AgentTurnsMax = in.TurnsMax
	s.Payload.AgentElapsedSecs = in.ElapsedSecs
	s.Payload.CurrentAgentStatus = "running"
	return true
}

// FinishStageInput collects parameters for appending a stage completion entry
// directly, without auto-closing substages or freezing the timer.
type FinishStageInput struct {
	Label   string
	Model   string
	Turns   string
	Time    string
	Verdict string
}

// FinishStage appends one completion record without touching the live stage.
func (s *State) FinishStage(in FinishStageInput) {
	s.AppendStageEntry(in.Label, in.Model, in.Turns, in.Time, in.Verdict)
	s.Payload.CurrentAgentStatus = "idle"
}

// ResetForNextMilestone clears per-milestone completion + progress state
// while preserving sidecar-lifetime state (cycle counters, closed ids,
// stage_order pill row, pipeline start ts).
func (s *State) ResetForNextMilestone() {
	s.Payload.StagesComplete = []proto.TUIStageEntry{}
	s.Payload.RecentEvents = []proto.TUIEventEntry{}
	s.Payload.StageLabel = ""
	s.Payload.AgentModel = ""
	s.Payload.StageNum = 0
	s.Payload.StageTotal = 0
	s.Payload.AgentTurnsUsed = 0
	s.Payload.AgentTurnsMax = 0
	s.Payload.AgentElapsedSecs = 0
	s.Payload.CurrentAgentStatus = "idle"
	s.Payload.StageStartTS = 0
	s.Payload.CurrentLifecycleID = ""
	s.Payload.CurrentSubstageLabel = ""
	s.Payload.CurrentSubstageStart = 0
}

// SetContext seeds run-mode, CLI flags, and the stage-pill order.
func (s *State) SetContext(runMode, cliFlags string, stages []string) {
	if runMode != "" {
		s.Payload.RunMode = runMode
	}
	s.Payload.CLIFlags = cliFlags
	if stages != nil {
		clean := make([]string, 0, len(stages))
		for _, st := range stages {
			if st != "" {
				clean = append(clean, st)
			}
		}
		s.Payload.StageOrder = clean
	}
}

// MarkComplete flips the complete flag and records the final verdict.
func (s *State) MarkComplete(verdict string) {
	s.Payload.Complete = true
	if verdict != "" {
		v := verdict
		s.Payload.Verdict = &v
	}
	s.Payload.CurrentAgentStatus = "complete"
}
