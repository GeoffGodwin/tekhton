//go:build windows

package supervisor

import (
	"errors"
	"os/exec"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

// windowsReaper assigns the agent process to a Job Object configured to
// terminate every member when the job is closed or explicitly killed. This
// is the canonical Windows replacement for the V3 `taskkill.exe /T` dance —
// taskkill races against orphans that detach before we can enumerate them,
// while a JobObject grabs them via inheritance at exec time.
//
// The handle is closed in Detach (clean exit) or after TerminateJobObject
// in Kill. Both paths are idempotent; concurrent Kill+Detach calls are
// serialized by mu.
type windowsReaper struct {
	mu      sync.Mutex
	job     windows.Handle
	killed  bool
	hasJob  bool
	closeFn func()
}

func newReaper() Reaper { return &windowsReaper{} }

// applyProcAttr is a no-op on Windows — the JobObject does the work that
// Setpgid does on POSIX, and it gets installed in Attach (after Start)
// rather than at command-construction time. Kept symmetrical with the
// POSIX file so run.go has one call site.
func applyProcAttr(cmd *exec.Cmd) { _ = cmd }

// jobInfoLimit is the JOBOBJECT_BASIC_LIMIT_INFORMATION + EXTENDED layout
// we set on the handle. The KILL_ON_JOB_CLOSE flag is the magic that makes
// Close() reap orphans automatically; pair it with TerminateJobObject for
// explicit Kill().
//
// Layout taken from the Windows SDK header `winnt.h`:
//
//	JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
//	    JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
//	    IO_COUNTERS                       IoInfo;
//	    SIZE_T                            ProcessMemoryLimit;
//	    SIZE_T                            JobMemoryLimit;
//	    SIZE_T                            PeakProcessMemoryUsed;
//	    SIZE_T                            PeakJobMemoryUsed;
//	}
type jobObjectExtendedLimitInformation struct {
	BasicLimitInformation windows.JOBOBJECT_BASIC_LIMIT_INFORMATION
	IoInfo                windows.IO_COUNTERS
	ProcessMemoryLimit    uintptr
	JobMemoryLimit        uintptr
	PeakProcessMemoryUsed uintptr
	PeakJobMemoryUsed     uintptr
}

func (r *windowsReaper) Attach(cmd *exec.Cmd) error {
	if cmd == nil || cmd.Process == nil {
		return errors.New("reaper: nil cmd or process")
	}

	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return err
	}

	info := jobObjectExtendedLimitInformation{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(
		job,
		windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)),
		uint32(unsafe.Sizeof(info)),
	); err != nil {
		windows.CloseHandle(job)
		return err
	}

	procHandle, err := windows.OpenProcess(
		windows.PROCESS_TERMINATE|windows.PROCESS_SET_QUOTA,
		false,
		uint32(cmd.Process.Pid),
	)
	if err != nil {
		windows.CloseHandle(job)
		return err
	}
	defer windows.CloseHandle(procHandle)

	if err := windows.AssignProcessToJobObject(job, procHandle); err != nil {
		windows.CloseHandle(job)
		return err
	}

	r.mu.Lock()
	r.job = job
	r.hasJob = true
	r.mu.Unlock()
	return nil
}

func (r *windowsReaper) Kill() error {
	r.mu.Lock()
	if r.killed || !r.hasJob {
		r.killed = true
		r.mu.Unlock()
		return nil
	}
	job := r.job
	r.killed = true
	r.mu.Unlock()

	// Exit code 1 on Windows is the conventional "killed by supervisor"
	// signal. Parity tests on the bash side use the same value.
	if err := windows.TerminateJobObject(job, 1); err != nil {
		return err
	}
	return nil
}

func (r *windowsReaper) Detach() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.hasJob {
		return nil
	}
	r.hasJob = false
	return windows.CloseHandle(r.job)
}

func reaperPlatformProbe() string { return "windows" }
