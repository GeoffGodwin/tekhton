package tui

import "time"

// EnterPauseInput captures the parameters of tui_enter_pause.
type EnterPauseInput struct {
	Reason           string
	RetryInterval    int
	MaxDuration      int
	FirstProbeDelay  int
}

// EnterPause records the start of a quota pause. agent_status flips to
// "paused" so the renderer can switch into the active-pause bar. Appends one
// warn-level event so the transition is visible in recent_events.
func (s *State) EnterPause(in EnterPauseInput, now time.Time) {
	if in.Reason == "" {
		in.Reason = "Rate limited"
	}
	initialDelay := in.RetryInterval
	if in.FirstProbeDelay > 0 {
		initialDelay = in.FirstProbeDelay
	}
	s.Payload.PauseReason = in.Reason
	s.Payload.PauseRetryInterval = in.RetryInterval
	s.Payload.PauseMaxDuration = in.MaxDuration
	s.Payload.PauseStartedAt = now.Unix()
	s.Payload.PauseNextProbeAt = now.Unix() + int64(initialDelay)
	s.Payload.CurrentAgentStatus = "paused"
	s.AppendEvent("warn", "Quota pause: "+in.Reason, "runtime", "", now, 0)
}

// UpdatePause refreshes pause_next_probe_at to now+nextInSecs. No event is
// appended — bash quota_sleep.sh ticks once per chunk-sleep cycle and we
// preserve the cadence (don't flood the ring buffer).
func (s *State) UpdatePause(nextInSecs int, now time.Time) bool {
	if s.Payload.CurrentAgentStatus != "paused" {
		return false
	}
	if nextInSecs < 0 {
		nextInSecs = 0
	}
	s.Payload.PauseNextProbeAt = now.Unix() + int64(nextInSecs)
	return true
}

// ExitPause clears pause state and appends one summary event reporting the
// outcome. Valid results: "refreshed" (default), "timeout", "cancelled".
func (s *State) ExitPause(result string, now time.Time) {
	switch result {
	case "refreshed", "timeout", "cancelled":
	default:
		result = "refreshed"
	}
	var elapsed int64
	if s.Payload.PauseStartedAt > 0 {
		elapsed = now.Unix() - s.Payload.PauseStartedAt
		if elapsed < 0 {
			elapsed = 0
		}
	}
	s.Payload.PauseReason = ""
	s.Payload.PauseRetryInterval = 0
	s.Payload.PauseMaxDuration = 0
	s.Payload.PauseStartedAt = 0
	s.Payload.PauseNextProbeAt = 0
	s.Payload.CurrentAgentStatus = "idle"

	level := "success"
	var msg string
	switch result {
	case "refreshed":
		msg = "Quota refreshed — resumed (paused " + itoa(int(elapsed)) + "s)"
	case "timeout":
		level = "error"
		msg = "Quota pause timed out after " + itoa(int(elapsed)) + "s"
	case "cancelled":
		level = "warn"
		msg = "Quota pause cancelled after " + itoa(int(elapsed)) + "s"
	}
	s.AppendEvent(level, msg, "runtime", "", now, 0)
}

// itoa is a small local helper that avoids pulling in strconv just for the
// pause messages.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
