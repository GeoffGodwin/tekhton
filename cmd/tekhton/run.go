package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/pipeline"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/runner"
	"github.com/geoffgodwin/tekhton/internal/stagerunner"
	"github.com/geoffgodwin/tekhton/internal/state"
	"github.com/geoffgodwin/tekhton/internal/tui"
	"github.com/spf13/cobra"
)

// newRunCmd wires `tekhton run` — the run-flag entry point ported from
// tekhton.sh in m19. The bash entry point still dispatches the legacy flags
// (--init, --rescan, --report, --status, --metrics, --migrate, --health,
// --rollback) through their existing code paths; m20 flips tekhton.sh to
// route run-flags through here.
func newRunCmd() *cobra.Command {
	var (
		taskFlag         string
		completeFlag     bool
		resumeFlag       bool
		humanFlag        bool
		humanTagFlag     string
		milestoneFlag    string
		autoAdvanceFlag  bool
		autoAdvanceLimit int
		dryRunFlag       bool
		noTUIFlag        bool
		projectDirFlag   string
		tekhtonHomeFlag  string
		analyzeCmd       string
		compileCmd       string
		testCmd          string
	)

	c := &cobra.Command{
		Use:   "run",
		Short: "Run the Tekhton pipeline (m19).",
		Long: "tekhton run drives the pipeline through internal/runner. Exactly one\n" +
			"of --task / --human / --milestone / --resume must be present.\n" +
			"--complete enables the autonomous outer retry loop. Run-level\n" +
			"behavior bridges to bash for pre-flight, finalize, and the TUI sidecar\n" +
			"during the V4 wedge — see DESIGN_v4.md Phase 5 for the planned cuts.",
		RunE: func(cmd *cobra.Command, args []string) error {
			req, err := buildRunRequest(
				taskFlag, completeFlag, resumeFlag, humanFlag, humanTagFlag,
				milestoneFlag, autoAdvanceFlag, autoAdvanceLimit, dryRunFlag,
				noTUIFlag, projectDirFlag, tekhtonHomeFlag,
			)
			if err != nil {
				printRunUsageError(cmd.ErrOrStderr(), cmd, err, args, autoAdvanceFlag)
				return errExitCode{code: exitUsage, err: err}
			}
			if len(args) > 0 {
				printRunUsageError(cmd.ErrOrStderr(), cmd,
					fmt.Errorf("unexpected positional argument(s): %s", strings.Join(args, " ")),
					args, autoAdvanceFlag)
				return errExitCode{code: exitUsage, err: fmt.Errorf("unexpected positional arguments")}
			}

			r, cleanup, err := buildRunner(req, analyzeCmd, compileCmd, testCmd)
			if err != nil {
				return err
			}
			defer cleanup()

			ctx := context.Background()

			var (
				res    *proto.RunResultV1
				runErr error
			)
			// NOTE: --dry-run is accepted by the flag set and stored in
			// req.DryRun, but no dispatch branch consumes it yet — every path
			// below invokes agents for real. Wiring the flag to a preview-only
			// pipeline path is deferred to Phase 5 / a later milestone.
			switch {
			case resumeFlag:
				res, runErr = r.Resume(ctx)
			case completeFlag:
				res, runErr = r.RunCompleteLoop(ctx, req)
			default:
				res, runErr = r.RunSingle(ctx, req)
			}

			if res != nil {
				printRunSummary(cmd.OutOrStdout(), res)
			}
			if runErr != nil {
				if errors.Is(runErr, runner.ErrSafetyBound) || errors.Is(runErr, runner.ErrStuck) {
					return errExitCode{code: 2, err: runErr}
				}
				return runErr
			}
			if res != nil && res.Disposition != proto.RunDispositionSuccess {
				return errExitCode{code: 1, err: fmt.Errorf("disposition=%s", res.Disposition)}
			}
			return nil
		},
	}

	c.Flags().StringVar(&taskFlag, "task", "", "free-form task description")
	c.Flags().BoolVar(&completeFlag, "complete", false, "run in autonomous --complete mode")
	c.Flags().BoolVar(&resumeFlag, "resume", false, "resume from PIPELINE_STATE.json")
	c.Flags().BoolVar(&humanFlag, "human", false, "run in --human mode (HUMAN_NOTES.md driven)")
	c.Flags().StringVar(&humanTagFlag, "human-tag", "", "optional tag filter for --human")
	c.Flags().StringVar(&milestoneFlag, "milestone", "", "specific milestone id to run")
	c.Flags().BoolVar(&autoAdvanceFlag, "auto-advance", false, "advance to next milestone on success")
	c.Flags().IntVar(&autoAdvanceLimit, "auto-advance-limit", 0, "override AUTO_ADVANCE_LIMIT")
	c.Flags().BoolVar(&dryRunFlag, "dry-run", false, "preview run without invoking agents")
	c.Flags().BoolVar(&noTUIFlag, "no-tui", false, "disable TUI sidecar")
	c.Flags().StringVar(&projectDirFlag, "project-dir", "", "target project (defaults to PROJECT_DIR or cwd)")
	c.Flags().StringVar(&tekhtonHomeFlag, "tekhton-home", "", "tekhton repo root (defaults to TEKHTON_HOME)")
	c.Flags().StringVar(&analyzeCmd, "analyze-cmd", "", "build-gate analyze command (default: skip)")
	c.Flags().StringVar(&compileCmd, "compile-cmd", "", "build-gate compile command (default: skip)")
	c.Flags().StringVar(&testCmd, "test-cmd", "", "completion-gate test command (default: skip)")
	return c
}

// buildRunRequest validates flag combinations and assembles a RunRequestV1.
// Exactly-one-of validation is the primary failure mode; the rest is field
// transcription.
func buildRunRequest(
	task string,
	complete, resume, human bool,
	humanTag string,
	milestone string,
	autoAdvance bool,
	autoAdvanceLimit int,
	dryRun, noTUI bool,
	projectDir, tekhtonHome string,
) (*proto.RunRequestV1, error) {
	chosen := 0
	mode := ""
	switch {
	case resume:
		chosen++
		mode = proto.RunModeResume
	}
	if task != "" {
		chosen++
		mode = proto.RunModeTask
	}
	if human {
		chosen++
		mode = proto.RunModeHuman
	}
	if milestone != "" {
		chosen++
		mode = proto.RunModeMilestone
	}
	if chosen != 1 {
		return nil, fmt.Errorf("exactly one of --task / --human / --milestone / --resume required (saw %d)", chosen)
	}

	if projectDir == "" {
		projectDir = os.Getenv("PROJECT_DIR")
	}
	if projectDir == "" {
		cwd, _ := os.Getwd()
		projectDir = cwd
	}
	if tekhtonHome == "" {
		tekhtonHome = os.Getenv("TEKHTON_HOME")
	}
	if tekhtonHome == "" {
		return nil, fmt.Errorf("--tekhton-home or TEKHTON_HOME required")
	}

	req := &proto.RunRequestV1{
		Proto:            proto.RunRequestProtoV1,
		Mode:             mode,
		Task:             task,
		HumanTag:         humanTag,
		Milestone:        milestone,
		Complete:         complete,
		AutoAdvance:      autoAdvance,
		AutoAdvanceLimit: autoAdvanceLimit,
		DryRun:           dryRun,
		NoTUI:            noTUI,
		ProjectDir:       projectDir,
		TekhtonHome:      tekhtonHome,
	}
	if mode != proto.RunModeResume {
		if err := req.Validate(); err != nil {
			return nil, err
		}
	}
	return req, nil
}

// buildRunner wires the runner with its dependencies. Caller invokes the
// returned cleanup func before returning from Cobra.
func buildRunner(req *proto.RunRequestV1, analyzeCmd, compileCmd, testCmd string) (*runner.Runner, func(), error) {
	adapter := &stagerunner.BashAdapter{
		TekhtonHome: req.TekhtonHome,
		ProjectDir:  req.ProjectDir,
		LogWriter:   os.Stderr,
		TekhtonBin:  resolveTekhtonBin(),
	}

	pipeOpts := pipeline.Options{
		LogDir:    filepath.Join(req.ProjectDir, ".claude", "logs"),
		ResultDir: filepath.Join(req.ProjectDir, ".tekhton", "stage_results"),
	}
	if analyzeCmd != "" || compileCmd != "" {
		pipeOpts.Gate = &pipeline.BuildGate{
			AnalyzeCmd: analyzeCmd,
			CompileCmd: compileCmd,
		}
	}
	if testCmd != "" {
		pipeOpts.CompletionGate = &pipeline.CompletionGate{TestCmd: testCmd}
	}

	pipe, err := pipeline.New(adapter, pipeOpts)
	if err != nil {
		return nil, func() {}, err
	}

	statePath := filepath.Join(req.ProjectDir, ".claude", "PIPELINE_STATE.json")
	r := runner.New(pipe)
	r.State = state.New(statePath)
	r.ProjectDir = req.ProjectDir
	r.TekhtonHome = req.TekhtonHome
	r.Hooks = &runner.BashHookRunner{TekhtonHome: req.TekhtonHome}

	var sidecar *tui.Sidecar
	if !req.NoTUI {
		sidecar = tui.New(req.TekhtonHome, req.ProjectDir)
		r.TUI = sidecar
	}

	cleanup := func() {
		if sidecar != nil && sidecar.PID() != 0 {
			_ = sidecar.Stop(context.Background(), false)
		}
	}
	return r, cleanup, nil
}

// printRunSummary writes a one-paragraph summary of the run to stdout. The
// finalize bridge prints the full RUN_SUMMARY.md / banner; we keep this
// terse so a CLI caller piping output can grep it.
func printRunSummary(out interface{ Write([]byte) (int, error) }, res *proto.RunResultV1) {
	fmt.Fprintf(out, "tekhton run: disposition=%s attempts=%d agent_calls=%d elapsed=%ds",
		res.Disposition, res.Attempts, res.AgentCalls, res.ElapsedSecs)
	if res.Recovery != "" {
		fmt.Fprintf(out, " recovery=%s", res.Recovery)
	}
	fmt.Fprintln(out)
}

var milestoneIDPattern = regexp.MustCompile(`^[Mm]\d+$`)

// printRunUsageError emits a clear, actionable diagnostic for usage errors
// against `tekhton run`. It surfaces silently-dropped positional args, calls
// out the V3→V4 syntax change for --auto-advance, and prints the full flag
// usage block. The root cmd has SilenceUsage=true; printing it here keeps the
// usage block off non-usage failures while ensuring syntax errors are
// debuggable.
func printRunUsageError(w interface{ Write([]byte) (int, error) }, cmd *cobra.Command, cause error, args []string, autoAdvance bool) {
	fmt.Fprintf(w, "tekhton run: %s\n\n", cause.Error())

	if len(args) > 0 {
		fmt.Fprintf(w, "Unused positional argument(s): %s\n", strings.Join(args, " "))
		hints := suggestionsFromArgs(args, autoAdvance)
		for _, h := range hints {
			fmt.Fprintf(w, "  hint: %s\n", h)
		}
		fmt.Fprintln(w)
	}

	if autoAdvance {
		fmt.Fprintln(w, "Note: in V4 --auto-advance is a boolean flag. The V3 form")
		fmt.Fprintln(w, "  `--auto-advance N \"task\"` is no longer supported. Use:")
		fmt.Fprintln(w, "    --auto-advance --auto-advance-limit N --milestone <id>")
		fmt.Fprintln(w)
	}

	fmt.Fprintln(w, "Examples:")
	fmt.Fprintln(w, "  tekhton --task \"Add OAuth login\"")
	fmt.Fprintln(w, "  tekhton --milestone m23")
	fmt.Fprintln(w, "  tekhton --milestone m23 --auto-advance --auto-advance-limit 3")
	fmt.Fprintln(w, "  tekhton --resume")
	fmt.Fprintln(w)

	fmt.Fprintln(w, cmd.UsageString())
}

// suggestionsFromArgs maps stray positionals to likely intended flags. Bare
// integers next to --auto-advance map to --auto-advance-limit; milestone-id-
// looking tokens map to --milestone; everything else suggests --task.
func suggestionsFromArgs(args []string, autoAdvance bool) []string {
	var out []string
	for _, a := range args {
		switch {
		case autoAdvance && isBareInt(a):
			out = append(out, fmt.Sprintf("did you mean `--auto-advance-limit %s`?", a))
		case milestoneIDPattern.MatchString(a):
			out = append(out, fmt.Sprintf("did you mean `--milestone %s`?", a))
		default:
			out = append(out, fmt.Sprintf("did you mean `--task %q`?", a))
		}
	}
	return out
}

func isBareInt(s string) bool {
	_, err := strconv.Atoi(s)
	return err == nil
}
