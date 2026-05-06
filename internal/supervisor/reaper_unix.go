//go:build !windows

package supervisor

import (
	"errors"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// posixReaper drives the V3 process-group strategy in Go: the supervisor
// asks os/exec to set Setpgid on the child (see applyProcAttr below); on
// Kill we send SIGTERM to the negative pgid so every descendant gets the
// signal. This is the same shape as `kill -- -<pgid>` from the bash side.
//
// Most of the work is delegated to the kernel and to exec.CommandContext's
// existing cancel hook. The reaper exists as a typed surface so the Windows
// implementation can substitute a JobObject without forcing run.go to know
// about either platform.
type posixReaper struct {
	mu     sync.Mutex
	pid    int
	killed bool
}

func newReaper() Reaper { return &posixReaper{} }

// applyProcAttr is called from buildCommand BEFORE cmd.Start. Setting
// Setpgid after Start is a no-op (per the kernel; see m09 Watch For), so
// the right place to wire it is at command-construction time. The function
// is exported across the package — Windows substitutes a no-op via a
// build-tagged sibling.
func applyProcAttr(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
}

// Attach captures the started process's pid. The pgid equals the pid because
// we asked the kernel to start a new group rooted at the child.
func (r *posixReaper) Attach(cmd *exec.Cmd) error {
	if cmd == nil || cmd.Process == nil {
		return errors.New("reaper: nil cmd or process")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.pid = cmd.Process.Pid
	return nil
}

// Kill sends SIGTERM to the process group, then SIGKILL after a grace
// period if anyone is still alive. Errors are folded — a killed-already
// child looks identical to a process that exited on its own, so we treat
// "no such process" / ESRCH as success.
//
// The grace period mirrors run.go's killGrace constant. We don't import it
// directly to avoid a tight coupling, but the value matches.
func (r *posixReaper) Kill() error {
	r.mu.Lock()
	pid := r.pid
	already := r.killed
	r.killed = true
	r.mu.Unlock()
	if pid <= 0 || already {
		return nil
	}
	// Negative pid → group. ESRCH means the leader is already gone; that is
	// fine on the SIGTERM path because the children are guaranteed to die
	// when the group leader does (assuming POSIX semantics).
	if err := syscall.Kill(-pid, syscall.SIGTERM); err != nil && !errors.Is(err, syscall.ESRCH) {
		return err
	}
	// Wait briefly, then escalate. The 5s budget is identical to run.go's
	// killGrace; longer would risk a parity-test stall under CI on slow
	// runners. Loop in 100ms steps so a fast exit isn't blocked.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if syscall.Kill(-pid, 0) != nil {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err := syscall.Kill(-pid, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) {
		return err
	}
	return nil
}

// Detach is a no-op on POSIX; the kernel cleans up process-group tracking
// on its own when the leader exits. Kept here so the interface contract is
// uniform with the Windows side, which DOES need to close a JobObject handle.
func (r *posixReaper) Detach() error { return nil }

// reaperPlatformProbe is a sanity hook — exposed only inside the package —
// for tests that want to confirm the build-tagged reaper resolved correctly.
// Returning a stable string ("unix") means a Windows-only test using the
// matching build tag can assert "windows" without importing runtime.
func reaperPlatformProbe() string { return "unix" }
