package supervisor

import "os/exec"

// Reaper is the cross-platform contract for terminating an agent's full
// process tree on cancellation. POSIX uses process groups (Setpgid + signal
// to -pgid). Windows uses Job Objects with TerminateJobObject. Each platform
// supplies an implementation in a build-tagged sibling file (`reaper_unix.go`,
// `reaper_windows.go`); newReaper() resolves to the right one at compile time.
//
// Lifecycle: Attach immediately after exec.Cmd.Start succeeds, Detach in a
// `defer` after Wait returns, Kill from any goroutine that observes a need
// to terminate the tree (ctx cancel, activity timeout, Reset cap exhausted).
// Implementations must be safe to Kill() from a goroutine concurrent with
// Wait() — that is the whole point of the reaper, so callers can race the
// timer against the agent's natural exit without a deadlock.
type Reaper interface {
	// Attach binds the reaper to a process that is already running. Returns
	// an error only when platform setup fails irrecoverably; callers MUST
	// continue with whatever fallback they have (POSIX process-group + ctx
	// cancel) when Attach fails — the reaper is best-effort by design.
	Attach(cmd *exec.Cmd) error

	// Kill terminates the process and every descendant. It must succeed
	// (return nil) even if the root has already exited — orphaned children
	// are precisely what the reaper exists to mop up. Idempotent.
	Kill() error

	// Detach releases tracking when the process exited cleanly. Detach
	// after a Kill is a no-op. Implementations close any handles they hold.
	Detach() error
}
