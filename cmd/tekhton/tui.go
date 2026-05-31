package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"syscall"
	"time"

	"github.com/geoffgodwin/tekhton/internal/tui"
	"github.com/spf13/cobra"
)

// newTUICmd wires `tekhton tui ...` subcommands. m23 ports the bash TUI
// writer surface to Go. Bash callers (lib/agent.sh, lib/quota.sh,
// stages/*.sh, tekhton-legacy.sh) shell out to these subcommands rather
// than sourcing six bash files.
//
// All subcommands are Hidden — they are an internal seam between bash
// callers and the Go state. The Python sidecar still reads tui_status.json
// directly; nothing here drives the rendering.
//
// State persistence model: each subcommand loads tui_status.json, mutates
// the in-memory State, writes it back atomically. The single-writer-at-a-
// time invariant is the same as the bash side — every mutation is a full
// snapshot rewrite.
func newTUICmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "tui",
		Short:  "TUI sidecar state mutators (internal — bash shim seam)",
		Hidden: true,
	}
	c.AddCommand(
		newTUIStartCmd(),
		newTUIStopCmd(),
		newTUICompleteCmd(),
		newTUIStageBeginCmd(),
		newTUIStageEndCmd(),
		newTUIUpdateStageCmd(),
		newTUIUpdateAgentCmd(),
		newTUIAppendEventCmd(),
		newTUISubstageBeginCmd(),
		newTUISubstageEndCmd(),
		newTUIPauseEnterCmd(),
		newTUIPauseUpdateCmd(),
		newTUIPauseExitCmd(),
		newTUIResetCmd(),
		newTUISetContextCmd(),
	)
	return c
}

// statusFilePath returns the default tui_status.json location, honoring
// $TEKHTON_SESSION_DIR (set by the bash entry point) and falling back to
// /tmp. Match lib/tui.sh:170.
func statusFilePath(override string) string {
	if override != "" {
		return override
	}
	if v := os.Getenv("TEKHTON_SESSION_DIR"); v != "" {
		return v + "/tui_status.json"
	}
	return "/tmp/tui_status.json"
}

// loadOrNew returns the state at path, or a fresh State when the file is
// missing. Every other load error is fatal.
func loadOrNew(path string) (*tui.State, error) {
	st, err := tui.Load(path)
	if err == nil {
		return st, nil
	}
	if errors.Is(err, tui.ErrNotFound) {
		return tui.NewState(), nil
	}
	return nil, err
}

// saveWithLiveness wraps SaveAtomic with a sidecar liveness probe. pidEnv
// names the env var holding the sidecar PID (set by `tekhton tui start`).
func saveWithLiveness(st *tui.State, path string) error {
	if pid := pidFromEnv(); pid > 0 {
		res := st.CheckSidecarLiveness(pid, tui.DefaultLivenessInterval, killZeroAlive)
		if res.Probed && !res.Alive && res.WarnEvent != "" {
			// Emit one warn event, clear sidecar pid so subsequent calls
			// don't keep probing.
			st.AppendEvent("warn", res.WarnEvent, "runtime", "", time.Now(), 0)
			_ = os.Unsetenv("TEKHTON_TUI_PID")
		}
	}
	return st.SaveAtomic(path)
}

func pidFromEnv() int {
	v := os.Getenv("TEKHTON_TUI_PID")
	if v == "" {
		return 0
	}
	var pid int
	_, _ = fmt.Sscanf(v, "%d", &pid)
	return pid
}

// killZeroAlive is the production SidecarProbe — kill(pid, 0) returns nil
// when the process is alive.
func killZeroAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	if err := proc.Signal(syscall.Signal(0)); err != nil {
		return false
	}
	return true
}

func addStatusFileFlag(c *cobra.Command, dest *string) {
	c.Flags().StringVar(dest, "status-file", "", "tui_status.json path (defaults to $TEKHTON_SESSION_DIR/tui_status.json)")
}

// --- start / stop / complete -----------------------------------------------

func newTUIStartCmd() *cobra.Command {
	var (
		statusFile string
		runMode    string
		cliFlags   string
		stageOrder []string
	)
	c := &cobra.Command{
		Use:   "start",
		Short: "Initialize tui_status.json (bash callers spawn sidecar separately)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.SetContext(runMode, cliFlags, stageOrder)
			st.PipelineStartTS = time.Now().Unix()
			return st.SaveAtomic(path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().StringVar(&runMode, "run-mode", "task", "run mode (task | milestone | etc)")
	c.Flags().StringVar(&cliFlags, "cli-flags", "", "non-default CLI flags string")
	c.Flags().StringSliceVar(&stageOrder, "stage-order", nil, "ordered pipeline stage list")
	return c
}

func newTUIStopCmd() *cobra.Command {
	var statusFile string
	c := &cobra.Command{
		Use:   "stop",
		Short: "Mark the run as stopped (bash callers tear down the sidecar separately)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := tui.Load(path)
			if err != nil {
				if errors.Is(err, tui.ErrNotFound) {
					return nil
				}
				return err
			}
			st.Payload.CurrentAgentStatus = "idle"
			return st.SaveAtomic(path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	return c
}

func newTUICompleteCmd() *cobra.Command {
	var (
		statusFile string
		verdict    string
	)
	c := &cobra.Command{
		Use:   "complete",
		Short: "Flip complete=true and record final verdict",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.MarkComplete(verdict)
			return st.SaveAtomic(path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().StringVar(&verdict, "verdict", "", "final verdict (SUCCESS | FAIL | ...)")
	return c
}

// --- stage lifecycle --------------------------------------------------------

func newTUIStageBeginCmd() *cobra.Command {
	var (
		statusFile string
		label      string
		model      string
		num        int
		total      int
	)
	c := &cobra.Command{
		Use:   "stage-begin",
		Short: "Open a pipeline stage",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if label == "" {
				return fmt.Errorf("--label required")
			}
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.StageBegin(tui.StageBeginInput{Label: label, Model: model, Num: num, Total: total}, time.Now())
			return saveWithLiveness(st, path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().StringVar(&label, "label", "", "stage display label (required)")
	c.Flags().StringVar(&model, "model", "", "agent model")
	c.Flags().IntVar(&num, "num", 0, "stage number (auto when 0)")
	c.Flags().IntVar(&total, "total", 0, "total stages (auto when 0)")
	return c
}

func newTUIStageEndCmd() *cobra.Command {
	var (
		statusFile string
		label      string
		model      string
		turns      string
		timeStr    string
		verdict    string
	)
	c := &cobra.Command{
		Use:   "stage-end",
		Short: "Close the open pipeline stage",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.StageEnd(tui.StageEndInput{Label: label, Model: model, Turns: turns, Time: timeStr, Verdict: verdict}, time.Now())
			return saveWithLiveness(st, path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().StringVar(&label, "label", "", "stage label")
	c.Flags().StringVar(&model, "model", "", "agent model")
	c.Flags().StringVar(&turns, "turns", "", "turns used / max")
	c.Flags().StringVar(&timeStr, "time", "", "stage duration string")
	c.Flags().StringVar(&verdict, "verdict", "", "stage verdict")
	return c
}

func newTUIUpdateStageCmd() *cobra.Command {
	var (
		statusFile string
		num        int
		total      int
		label      string
		model      string
	)
	c := &cobra.Command{
		Use:   "update-stage",
		Short: "Update the active stage's label/model/index without closing it",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.UpdateStage(tui.UpdateStageInput{Num: num, Total: total, Label: label, Model: model}, time.Now())
			return saveWithLiveness(st, path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().IntVar(&num, "num", 0, "stage number")
	c.Flags().IntVar(&total, "total", 0, "total stages")
	c.Flags().StringVar(&label, "label", "", "stage label")
	c.Flags().StringVar(&model, "model", "", "agent model")
	return c
}

func newTUIUpdateAgentCmd() *cobra.Command {
	var (
		statusFile  string
		turnsUsed   int
		turnsMax    int
		elapsedSecs int
		lifecycleID string
	)
	c := &cobra.Command{
		Use:   "update-agent",
		Short: "Tick agent counters (spinner cadence)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.UpdateAgent(tui.UpdateAgentInput{
				TurnsUsed:   turnsUsed,
				TurnsMax:    turnsMax,
				ElapsedSecs: elapsedSecs,
				LifecycleID: lifecycleID,
			})
			return saveWithLiveness(st, path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().IntVar(&turnsUsed, "turns-used", 0, "turns used")
	c.Flags().IntVar(&turnsMax, "turns-max", 0, "max turns")
	c.Flags().IntVar(&elapsedSecs, "elapsed-secs", 0, "agent elapsed seconds")
	c.Flags().StringVar(&lifecycleID, "lifecycle-id", "", "captured lifecycle id (drops late ticks)")
	return c
}

func newTUIAppendEventCmd() *cobra.Command {
	var (
		statusFile string
		level      string
		message    string
		eventType  string
		source     string
	)
	c := &cobra.Command{
		Use:   "append-event",
		Short: "Append one entry to the recent-events ring buffer",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			max := 60
			if v := os.Getenv("TUI_EVENT_LINES"); v != "" {
				_, _ = fmt.Sscanf(v, "%d", &max)
			}
			st.AppendEvent(level, message, eventType, source, time.Now(), max)
			return saveWithLiveness(st, path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().StringVar(&level, "level", "info", "event level (info | warn | error | success)")
	c.Flags().StringVar(&message, "message", "", "event message")
	c.Flags().StringVar(&eventType, "type", "runtime", "event type (runtime | summary)")
	c.Flags().StringVar(&source, "source", "", "attribution source (\"stage » substage\" or \"stage\")")
	return c
}

// --- substage --------------------------------------------------------------

func newTUISubstageBeginCmd() *cobra.Command {
	var (
		statusFile string
		label      string
	)
	c := &cobra.Command{
		Use:   "substage-begin",
		Short: "Open a substage breadcrumb inside the current stage",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.SubstageBegin(label, time.Now())
			return saveWithLiveness(st, path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().StringVar(&label, "label", "", "substage label")
	return c
}

func newTUISubstageEndCmd() *cobra.Command {
	var (
		statusFile string
		label      string
		verdict    string
	)
	c := &cobra.Command{
		Use:   "substage-end",
		Short: "Close the active substage breadcrumb",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.SubstageEnd(label, verdict)
			return saveWithLiveness(st, path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().StringVar(&label, "label", "", "substage label (informational)")
	c.Flags().StringVar(&verdict, "verdict", "", "substage verdict (informational)")
	return c
}

// --- pause -----------------------------------------------------------------

func newTUIPauseEnterCmd() *cobra.Command {
	var (
		statusFile      string
		reason          string
		retryInterval   int
		maxDuration     int
		firstProbeDelay int
	)
	c := &cobra.Command{
		Use:   "pause-enter",
		Short: "Enter a quota pause",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.EnterPause(tui.EnterPauseInput{
				Reason:          reason,
				RetryInterval:   retryInterval,
				MaxDuration:     maxDuration,
				FirstProbeDelay: firstProbeDelay,
			}, time.Now())
			return saveWithLiveness(st, path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().StringVar(&reason, "reason", "Rate limited", "pause reason")
	c.Flags().IntVar(&retryInterval, "retry-interval", 0, "probe retry interval seconds")
	c.Flags().IntVar(&maxDuration, "max-duration", 0, "max pause duration seconds")
	c.Flags().IntVar(&firstProbeDelay, "first-probe-delay", 0, "initial probe delay override")
	return c
}

func newTUIPauseUpdateCmd() *cobra.Command {
	var (
		statusFile string
		nextIn     int
	)
	c := &cobra.Command{
		Use:   "pause-update",
		Short: "Refresh pause_next_probe_at to now+nextIn",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.UpdatePause(nextIn, time.Now())
			return saveWithLiveness(st, path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().IntVar(&nextIn, "next-in", 0, "seconds until next probe")
	return c
}

func newTUIPauseExitCmd() *cobra.Command {
	var (
		statusFile string
		result     string
	)
	c := &cobra.Command{
		Use:   "pause-exit",
		Short: "Exit pause (refreshed | timeout | cancelled)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.ExitPause(result, time.Now())
			return saveWithLiveness(st, path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().StringVar(&result, "result", "refreshed", "pause outcome")
	return c
}

// --- misc ------------------------------------------------------------------

func newTUIResetCmd() *cobra.Command {
	var statusFile string
	c := &cobra.Command{
		Use:   "reset",
		Short: "Reset per-milestone state for auto-advance",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.ResetForNextMilestone()
			return saveWithLiveness(st, path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	return c
}

func newTUISetContextCmd() *cobra.Command {
	var (
		statusFile string
		runMode    string
		cliFlags   string
		stages     []string
	)
	c := &cobra.Command{
		Use:   "set-context",
		Short: "Seed run-mode, CLI flags, and stage_order",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := statusFilePath(statusFile)
			st, err := loadOrNew(path)
			if err != nil {
				return err
			}
			st.SetContext(runMode, cliFlags, stages)
			return saveWithLiveness(st, path)
		},
	}
	addStatusFileFlag(c, &statusFile)
	c.Flags().StringVar(&runMode, "run-mode", "task", "run mode")
	c.Flags().StringVar(&cliFlags, "cli-flags", "", "non-default CLI flags string")
	c.Flags().StringSliceVar(&stages, "stages", nil, "ordered pipeline stage labels")
	return c
}

// ensure unused-import errors stay quiet during partial builds.
var _ = context.Background
