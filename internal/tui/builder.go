package tui

import (
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// SetPipelineElapsed updates pipeline_elapsed_secs based on the captured
// PipelineStartTS. When PipelineStartTS is 0 (not yet seeded), the elapsed
// counter stays at 0. now is injected so tests can pin the clock.
func (s *State) SetPipelineElapsed(now time.Time) {
	if s.PipelineStartTS <= 0 {
		s.Payload.PipelineElapsedSecs = 0
		return
	}
	elapsed := now.Unix() - s.PipelineStartTS
	if elapsed < 0 {
		elapsed = 0
	}
	s.Payload.PipelineElapsedSecs = int(elapsed)
}

// AppendStageEntry creates a stage record from the supplied fields and pushes
// it onto stages_complete. Lifecycle id comes from the current open stage
// (mirroring the bash behavior where _tui_json_stage embeds whichever id was
// open at the time of the call).
func (s *State) AppendStageEntry(label, model, turns, timeStr, verdict string) proto.TUIStageEntry {
	var v *string
	if verdict != "" {
		vv := verdict
		v = &vv
	}
	entry := proto.TUIStageEntry{
		Label:       label,
		LifecycleID: s.Payload.CurrentLifecycleID,
		Model:       model,
		Turns:       turns,
		Time:        timeStr,
		Verdict:     v,
	}
	s.Payload.StagesComplete = append(s.Payload.StagesComplete, entry)
	return entry
}

// AppendEvent pushes one entry onto recent_events with timestamp and ring-
// buffer trimming. eventLines is the configured TUI_EVENT_LINES; <= 0 disables
// trimming (kept for symmetry with bash, where _TUI_EVENT_LINES <=0 was
// undefined behavior — we simply never trim).
func (s *State) AppendEvent(level, msg, eventType, source string, now time.Time, eventLines int) proto.TUIEventEntry {
	switch eventType {
	case "runtime", "summary":
	default:
		eventType = "runtime"
	}
	entry := proto.TUIEventEntry{
		TS:     now.Format("15:04:05"),
		Level:  level,
		Type:   eventType,
		Source: source,
		Msg:    msg,
	}
	s.Payload.RecentEvents = append(s.Payload.RecentEvents, entry)
	if eventLines > 0 && len(s.Payload.RecentEvents) > eventLines {
		overflow := len(s.Payload.RecentEvents) - eventLines
		s.Payload.RecentEvents = s.Payload.RecentEvents[overflow:]
	}
	// last_event mirrors bash: ts is stripped, leaving "level|type|...|msg".
	// Simpler form: just store msg, which is what the renderer cares about.
	s.Payload.LastEvent = msg
	return entry
}

// EnsureStageInOrder appends label to stage_order when it isn't already
// present. The bash implementation preserved insertion order; we do the same.
func (s *State) EnsureStageInOrder(label string) {
	if label == "" {
		return
	}
	for _, existing := range s.Payload.StageOrder {
		if existing == label {
			return
		}
	}
	s.Payload.StageOrder = append(s.Payload.StageOrder, label)
}
