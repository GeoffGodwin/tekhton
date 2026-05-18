package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/geoffgodwin/tekhton/internal/finalize"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/spf13/cobra"
)

// newFinalizeCmd wires `tekhton finalize` — an internal developer subcommand
// for two use cases:
//
//  1. The bash legacy compatibility shim in lib/finalize.sh delegates here
//     so legacy callers (orchestrate_iteration.sh, orchestrate_save.sh, etc.)
//     still get a working `finalize_run` while the bash orchestrator is gone.
//  2. The m21 parity gate replays a captured RUN_RESULT.json envelope through
//     the Go orchestrator to diff side-effects against a bash baseline
//     without re-running the whole pipeline.
//
// Flagged "internal" in the Cobra help so it is hidden from the standard
// command list (developer tool, not a user feature).
func newFinalizeCmd() *cobra.Command {
	var (
		exitCode             int
		resultPath           string
		projectDir           string
		home                 string
		milestone            string
		milestoneMode        string
		milestoneDisposition string
		logDir               string
		timestamp            string
		disposition          string
	)
	c := &cobra.Command{
		Use:   "finalize",
		Short: "Run the Go finalize orchestrator (internal — developer tool)",
		Long: "Internal subcommand used by lib/finalize.sh's legacy compatibility " +
			"shim and the m21 parity gate. Not intended for direct user invocation.\n\n" +
			"Behavior: constructs internal/finalize.Orchestrator and drives the 26-hook " +
			"chain (8 pure-Go bodies + 18 routed through lib/finalize_shim.sh). The " +
			"chain is continue-on-error — a failing hook is logged but does not abort " +
			"the rest of the sequence (mirrors the bash finalize_run loop).",
		Hidden: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if projectDir == "" {
				projectDir, _ = os.Getwd()
			}
			if home == "" {
				home = os.Getenv("TEKHTON_HOME")
			}
			if logDir == "" {
				logDir = filepath.Join(projectDir, ".claude", "logs")
			}
			if timestamp == "" {
				timestamp = time.Now().UTC().Format("20060102_150405")
			}

			var result *proto.RunResultV1
			if resultPath != "" {
				r, err := loadRunResult(resultPath)
				if err != nil {
					return errExitCode{code: exitNotFound, err: fmt.Errorf("finalize: load result: %w", err)}
				}
				result = r
				if disposition == "" {
					disposition = r.Disposition
				}
			} else {
				// No envelope on disk — build a minimal stand-in so hooks
				// that read Result do not nil-deref.
				if disposition == "" {
					if exitCode == 0 {
						disposition = proto.RunDispositionSuccess
					} else {
						disposition = proto.RunDispositionFailure
					}
				}
				result = &proto.RunResultV1{
					Proto:       proto.RunResultProtoV1,
					Disposition: disposition,
				}
			}

			orch := finalize.NewOrchestrator(home, projectDir)
			in := &finalize.Input{
				ExitCode:             exitCode,
				Disposition:          disposition,
				Result:               result,
				ResultPath:           resultPath,
				TekhtonHome:          home,
				ProjectDir:           projectDir,
				LogDir:               logDir,
				Timestamp:            timestamp,
				Milestone:            milestone,
				MilestoneMode:        milestoneMode == "true",
				MilestoneDisposition: milestoneDisposition,
				Log:                  cmd.ErrOrStderr(),
			}
			ctx := context.Background()
			sum := orch.Run(ctx, in)
			if failed := sum.Failed(); len(failed) > 0 {
				fmt.Fprintf(cmd.ErrOrStderr(), "finalize: %d hooks reported errors: %v\n", len(failed), failed)
			}
			return nil
		},
	}
	c.Flags().IntVar(&exitCode, "exit-code", 0, "pipeline exit code (0 success, non-zero failure)")
	c.Flags().StringVar(&resultPath, "result", "", "path to RUN_RESULT.json envelope (optional)")
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().StringVar(&home, "home", "", "TEKHTON_HOME (defaults to $TEKHTON_HOME)")
	c.Flags().StringVar(&milestone, "milestone", "", "active milestone id (e.g. m21)")
	c.Flags().StringVar(&milestoneMode, "milestone-mode", "false", "milestone mode flag (true/false)")
	c.Flags().StringVar(&milestoneDisposition, "milestone-disposition", "", "milestone disposition (COMPLETE_AND_CONTINUE, etc.)")
	c.Flags().StringVar(&logDir, "log-dir", "", "log directory (defaults to <project>/.claude/logs)")
	c.Flags().StringVar(&timestamp, "timestamp", "", "run timestamp (YYYYMMDD_HHMMSS, defaults to now)")
	c.Flags().StringVar(&disposition, "disposition", "", "run disposition (defaults to inferred from exit-code)")
	return c
}

// loadRunResult reads a RUN_RESULT.json envelope from disk and parses it
// as RunResultV1. Returns a typed error on missing file or invalid JSON.
func loadRunResult(path string) (*proto.RunResultV1, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var r proto.RunResultV1
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	r.EnsureProto()
	return &r, nil
}
