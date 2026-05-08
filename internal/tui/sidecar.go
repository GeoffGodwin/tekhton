// Package tui owns the Go-side spawn-and-monitor logic for the Python TUI
// sidecar (tools/tui.py). The mid-run status writers stay in bash
// (lib/tui_ops.sh, lib/tui_liveness.sh) — they write tui_status.json which
// the Python sidecar polls. m19 only ports the *spawn* logic, not the status
// writers.
//
// Activation rules mirror lib/tui.sh::_tui_should_activate:
//   - Skip if Disabled is true (the --no-tui CLI flag flips this).
//   - Skip if stdout is not a TTY.
//   - Skip if the venv python is missing or doesn't have rich installed.
//   - Skip if tools/tui.py is missing from TekhtonHome.
package tui

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

// Sentinel errors callers match with errors.Is.
var (
	// ErrDisabled is returned when activation gating turns the sidecar off.
	// Callers treat this as a soft skip, not a fatal error.
	ErrDisabled = errors.New("tui: disabled")

	// ErrNotStarted is returned by Stop when Start was never called.
	ErrNotStarted = errors.New("tui: sidecar not started")
)

// Sidecar manages the Python TUI sidecar process. Construct via New.
type Sidecar struct {
	// TekhtonHome is the repo root (where tools/tui.py lives).
	TekhtonHome string

	// ProjectDir is where the .claude/tui_sidecar.pid file is written. The
	// bash side already owns this convention; we honor it so cross-language
	// stale-PID cleanup works.
	ProjectDir string

	// VenvPython is the absolute path to the venv python. When empty,
	// resolution falls back to defaultPython under the project venv dir.
	VenvPython string

	// SessionDir is where tui_status.json is written. Defaults to /tmp.
	SessionDir string

	// Disabled forces the sidecar off — used by the --no-tui flag.
	Disabled bool

	// HoldTimeout is the max wall-clock to wait for the sidecar to exit
	// during Stop(holdEnter=true). Ignored when holdEnter is false.
	HoldTimeout time.Duration

	// SimpleLogo passes --simple-logo to the Python sidecar.
	SimpleLogo bool

	// TickMs / EventLines / WatchdogSecs match the bash flags surface.
	TickMs       int
	EventLines   int
	WatchdogSecs int

	// IsTTY overrides the TTY check. When nil, defaults to checking stdout.
	IsTTY func() bool

	cmd        *exec.Cmd
	pid        int
	statusFile string
}

// New constructs a Sidecar with sensible defaults.
func New(tekhtonHome, projectDir string) *Sidecar {
	return &Sidecar{
		TekhtonHome:  tekhtonHome,
		ProjectDir:   projectDir,
		SessionDir:   "/tmp",
		HoldTimeout:  120 * time.Second,
		TickMs:       500,
		EventLines:   60,
		WatchdogSecs: 300,
	}
}

// PID returns the running sidecar's PID, or 0 when not started.
func (s *Sidecar) PID() int { return s.pid }

// StatusFile returns the path the sidecar reads for status updates.
func (s *Sidecar) StatusFile() string { return s.statusFile }

// shouldActivate replicates the bash gating logic.
func (s *Sidecar) shouldActivate() (bool, string) {
	if s.Disabled {
		return false, "TUI_ENABLED=false"
	}
	if s.TekhtonHome == "" {
		return false, "tekhton_home unset"
	}
	scriptPath := filepath.Join(s.TekhtonHome, "tools", "tui.py")
	if _, err := os.Stat(scriptPath); err != nil {
		return false, "tools/tui.py missing from TEKHTON_HOME"
	}
	tty := s.IsTTY
	if tty == nil {
		tty = stdoutIsTTY
	}
	if !tty() {
		return false, "non-interactive TTY"
	}
	py, ok := s.resolvePython()
	if !ok {
		return false, "Python venv not found"
	}
	s.VenvPython = py
	if !pythonHasRich(py) {
		return false, "rich not installed in venv"
	}
	return true, ""
}

// resolvePython picks the Python interpreter from VenvPython (when set) or
// the conventional venv path under PROJECT_DIR.
func (s *Sidecar) resolvePython() (string, bool) {
	if s.VenvPython != "" {
		if _, err := os.Stat(s.VenvPython); err == nil {
			return s.VenvPython, true
		}
	}
	candidates := []string{
		filepath.Join(s.ProjectDir, ".claude", "indexer-venv", "bin", "python"),
		filepath.Join(s.ProjectDir, ".claude", "indexer-venv", "Scripts", "python.exe"),
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c, true
		}
	}
	return "", false
}

// stdoutIsTTY is the default IsTTY check. Indirected so tests don't need to
// allocate a /dev/tty.
func stdoutIsTTY() bool {
	fi, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return (fi.Mode() & os.ModeCharDevice) != 0
}

// pythonHasRich returns true if the venv has the rich library installed. We
// shell out because the import test is the only authoritative answer.
func pythonHasRich(py string) bool {
	cmd := exec.Command(py, "-c", "import rich")
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	return cmd.Run() == nil
}

// Start spawns the sidecar. Idempotent; returns nil if Start was already
// called.
func (s *Sidecar) Start(ctx context.Context) error {
	if s.cmd != nil {
		return nil
	}

	ok, reason := s.shouldActivate()
	if !ok {
		return fmt.Errorf("%w: %s", ErrDisabled, reason)
	}

	s.killStale()

	if s.SessionDir == "" {
		s.SessionDir = "/tmp"
	}
	s.statusFile = filepath.Join(s.SessionDir, "tui_status.json")

	args := []string{
		filepath.Join(s.TekhtonHome, "tools", "tui.py"),
		"--status-file", s.statusFile,
		"--tick-ms", strconv.Itoa(s.TickMs),
		"--event-lines", strconv.Itoa(s.EventLines),
		"--watchdog-secs", strconv.Itoa(s.WatchdogSecs),
	}
	if s.SimpleLogo {
		args = append(args, "--simple-logo")
	}

	cmd := exec.CommandContext(ctx, s.VenvPython, args...)
	cmd.Dir = s.ProjectDir
	logPath := filepath.Join(s.SessionDir, "tui_sidecar.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err == nil {
		cmd.Stderr = logFile
	}

	if err := cmd.Start(); err != nil {
		if logFile != nil {
			_ = logFile.Close()
		}
		return fmt.Errorf("tui: start sidecar: %w", err)
	}
	s.cmd = cmd
	s.pid = cmd.Process.Pid
	s.writePIDFile(s.pid)
	return nil
}

// Stop terminates the sidecar. holdEnter mirrors the bash tui_complete behavior
// — when true, the caller wants the sidecar to display its final view and wait
// for the user to press Enter, up to s.HoldTimeout. When false, kill immediately.
func (s *Sidecar) Stop(ctx context.Context, holdEnter bool) error {
	if s.cmd == nil || s.pid == 0 {
		return ErrNotStarted
	}

	if holdEnter && s.HoldTimeout > 0 {
		s.waitForExit(ctx, s.HoldTimeout)
	}

	if s.cmd.ProcessState == nil || !s.cmd.ProcessState.Exited() {
		_ = s.cmd.Process.Signal(syscall.SIGTERM)
		s.waitForExit(ctx, 500*time.Millisecond)
		if s.cmd.ProcessState == nil || !s.cmd.ProcessState.Exited() {
			_ = s.cmd.Process.Kill()
			_, _ = s.cmd.Process.Wait()
		}
	}

	s.removePIDFile()
	s.cmd = nil
	s.pid = 0
	return nil
}

// waitForExit polls the process state until exited or the timeout fires.
// Cheaper than spawning a goroutine for the common short-hold case.
func (s *Sidecar) waitForExit(ctx context.Context, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := ctx.Err(); err != nil {
			return
		}
		if s.cmd.ProcessState != nil && s.cmd.ProcessState.Exited() {
			return
		}
		// Non-blocking peek using FindProcess + signal 0.
		if proc, err := os.FindProcess(s.pid); err == nil {
			if err := proc.Signal(syscall.Signal(0)); err != nil {
				return
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// killStale removes any leftover sidecar PID file from a prior crashed run.
// Mirrors the bash _tui_kill_stale.
func (s *Sidecar) killStale() {
	pidfile := filepath.Join(s.ProjectDir, ".claude", "tui_sidecar.pid")
	data, err := os.ReadFile(pidfile)
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(string(trimWhitespace(data)))
	if err != nil || pid <= 0 {
		return
	}
	if proc, err := os.FindProcess(pid); err == nil {
		// Best effort — process may already be gone.
		_ = proc.Signal(syscall.SIGTERM)
	}
	_ = os.Remove(pidfile)
}

// writePIDFile persists the sidecar's PID where the bash tools expect it.
func (s *Sidecar) writePIDFile(pid int) {
	dir := filepath.Join(s.ProjectDir, ".claude")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(dir, "tui_sidecar.pid"),
		[]byte(strconv.Itoa(pid)), 0o644)
}

// removePIDFile cleans up the PID file on Stop.
func (s *Sidecar) removePIDFile() {
	_ = os.Remove(filepath.Join(s.ProjectDir, ".claude", "tui_sidecar.pid"))
}

// trimWhitespace returns data with leading/trailing whitespace removed.
func trimWhitespace(data []byte) []byte {
	start, end := 0, len(data)
	for start < end {
		if !isSpace(data[start]) {
			break
		}
		start++
	}
	for end > start {
		if !isSpace(data[end-1]) {
			break
		}
		end--
	}
	return data[start:end]
}

func isSpace(b byte) bool { return b == ' ' || b == '\t' || b == '\n' || b == '\r' }
