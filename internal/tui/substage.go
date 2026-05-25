package tui

import "time"

// SubstageBegin declares a substage active inside the currently open pipeline
// stage. Records current_substage_label and current_substage_start_ts; parent
// stage state (label, start ts, lifecycle id) and stages_complete are
// intentionally untouched — substages are breadcrumbs, not timeline entries.
//
// Empty label is a no-op (matches bash behavior).
func (s *State) SubstageBegin(label string, now time.Time) {
	if label == "" {
		return
	}
	s.Payload.CurrentSubstageLabel = label
	s.Payload.CurrentSubstageStart = now.Unix()
}

// SubstageEnd clears the active substage. label and verdict are accepted for
// call-site symmetry with StageEnd but are not retained — substage completion
// is not appended to stages_complete.
func (s *State) SubstageEnd(_, _ string) {
	s.Payload.CurrentSubstageLabel = ""
	s.Payload.CurrentSubstageStart = 0
}

// AutoCloseSubstageIfOpen is invoked from StageEnd when the parent stage
// closes while a substage is still active (crash, early return, forgotten
// end call). Emits a single warn event into recent_events and clears the
// substage globals. Returns true when a substage was open and was closed,
// false otherwise.
//
// (Currently called inline from StageEnd in ops.go; exported for tests that
// want to exercise the auto-close invariant directly.)
func (s *State) AutoCloseSubstageIfOpen(now time.Time) bool {
	lbl := s.Payload.CurrentSubstageLabel
	if lbl == "" {
		return false
	}
	s.Payload.CurrentSubstageLabel = ""
	s.Payload.CurrentSubstageStart = 0
	s.AppendEvent("warn", "[tui] substage '"+lbl+"' auto-closed by parent end", "runtime", "", now, 0)
	return true
}
