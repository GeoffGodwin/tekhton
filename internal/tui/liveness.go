package tui

// DefaultLivenessInterval is the sampling interval — the sidecar liveness
// probe fires once per N writes. Mirrors bash _TUI_LIVENESS_INTERVAL=20.
const DefaultLivenessInterval = 20

// SidecarProbe is the function signature for the syscall-level liveness
// check. Returns true when the process is alive. Tests inject a fake; the
// production CLI passes a kill(0) closure.
type SidecarProbe func(pid int) bool

// LivenessResult is the outcome of a single CheckSidecarLiveness call.
type LivenessResult struct {
	Probed    bool   // true when the sampling interval expired and the probe ran
	Alive     bool   // result of the probe — only meaningful when Probed
	WarnEvent string // when non-empty, an event the caller should emit (sidecar transition)
}

// CheckSidecarLiveness implements the sampled probe. It is invoked once per
// SaveAtomic; the probe itself only fires once per Interval writes to keep
// the hot path cheap. When the probe detects the sidecar is dead, the
// returned WarnEvent carries the message bash would have logged.
//
// pid is the captured sidecar PID; <= 0 means "no sidecar running" → no
// probe. interval <= 0 falls back to DefaultLivenessInterval.
func (s *State) CheckSidecarLiveness(pid int, interval int, probe SidecarProbe) LivenessResult {
	if pid <= 0 {
		return LivenessResult{}
	}
	if interval <= 0 {
		interval = DefaultLivenessInterval
	}
	s.LivenessCount++
	if s.LivenessCount < interval {
		return LivenessResult{}
	}
	s.LivenessCount = 0
	if probe == nil {
		return LivenessResult{Probed: true, Alive: true}
	}
	alive := probe(pid)
	if alive {
		return LivenessResult{Probed: true, Alive: true}
	}
	return LivenessResult{
		Probed:    true,
		Alive:     false,
		WarnEvent: "TUI sidecar exited (pid " + itoa(pid) + "; likely watchdog timeout); continuing in CLI mode",
	}
}
