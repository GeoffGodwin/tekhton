package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/finalize"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/spf13/cobra"
)

// newCommitBookkeepingCmd wires `tekhton commit-bookkeeping` — invoked by
// lib/finalize_commit.sh's _hook_commit AFTER the user picks "y" but BEFORE
// _do_git_commit. It runs the three completion-bookkeeping hooks
// (mark_done, cleanup_milestone, clear_state) so their state mutations
// (manifest = done, milestone file deleted, MILESTONE_STATE.md cleared)
// are present in the working tree when `git add -A && git commit` runs.
//
// Without this pre-commit invocation, the same three hooks run via the
// Go finalize chain AFTER _hook_commit (per the 2026-05 reorder that gates
// them on the commit_decision sentinel), but by then the commit is already
// made — the manifest mutation + file deletion show up as uncommitted
// working-tree changes, breaking the "clean state after success" contract.
//
// The hooks remain in the finalize chain so they still fire on AUTO_COMMIT
// and any future code path that bypasses _hook_commit. They're idempotent:
// re-running them when the work is already done is a no-op.
func newCommitBookkeepingCmd() *cobra.Command {
	var (
		projectDir           string
		home                 string
		milestone            string
		milestoneMode        string
		milestoneDisposition string
		exitCode             int
	)
	c := &cobra.Command{
		Use:   "commit-bookkeeping",
		Short: "Run pre-commit milestone-completion hooks (internal)",
		Long: "Internal subcommand invoked by lib/finalize_commit.sh's " +
			"_hook_commit y-branch. Runs mark_done + cleanup_milestone + " +
			"clear_state so the upcoming `git add -A && git commit` captures " +
			"manifest mutation and milestone file deletion in the same commit.\n\n" +
			"Idempotent — safe to re-run; the same hooks fire again in the " +
			"finalize chain afterward and no-op when state is already current.",
		Hidden: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if projectDir == "" {
				projectDir, _ = os.Getwd()
			}
			if home == "" {
				home = os.Getenv("TEKHTON_HOME")
			}
			in := &finalize.Input{
				ExitCode:             exitCode,
				Disposition:          proto.RunDispositionSuccess,
				Result:               &proto.RunResultV1{Proto: proto.RunResultProtoV1, Disposition: proto.RunDispositionSuccess},
				TekhtonHome:          home,
				ProjectDir:           projectDir,
				Milestone:            milestone,
				MilestoneMode:        milestoneMode == "true",
				MilestoneDisposition: milestoneDisposition,
				Log:                  cmd.ErrOrStderr(),
			}
			// Pre-write the commit decision sentinel so the three hooks'
			// shouldRunOnCompletion gate (which checks the sentinel since
			// the 2026-05 reorder) sees "committed" and fires. The bash
			// caller writes the same value before invoking us; we write
			// it again defensively in case operators invoke this subcommand
			// standalone for diagnostic purposes.
			if err := writeCommitDecisionSentinel(in, "committed"); err != nil {
				fmt.Fprintf(cmd.ErrOrStderr(), "commit-bookkeeping: sentinel write failed: %v\n", err)
				// Don't abort — the hooks just won't fire, same as
				// when the bash caller's _write_commit_decision fails.
			}
			runOneHook(cmd.ErrOrStderr(), in, &finalize.MarkDone{})
			runOneHook(cmd.ErrOrStderr(), in, &finalize.CleanupMilestone{})
			runOneHook(cmd.ErrOrStderr(), in, &finalize.ClearState{})
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().StringVar(&home, "home", "", "TEKHTON_HOME (defaults to $TEKHTON_HOME)")
	c.Flags().StringVar(&milestone, "milestone", "", "active milestone id (e.g. m23)")
	c.Flags().StringVar(&milestoneMode, "milestone-mode", "true", "milestone mode flag (true/false)")
	c.Flags().StringVar(&milestoneDisposition, "milestone-disposition", "COMPLETE_AND_CONTINUE", "milestone disposition")
	c.Flags().IntVar(&exitCode, "exit-code", 0, "pipeline exit code (must be 0 for hooks to fire)")
	return c
}

// runOneHook executes a single hook and logs any error. The hook's Run
// signature returns error; we never abort on a single failure because the
// three completion hooks are independent (mark_done can succeed even if
// the milestone file is already gone, etc.).
func runOneHook(log io.Writer, in *finalize.Input, h finalize.Hook) {
	if err := h.Run(context.Background(), in); err != nil {
		fmt.Fprintf(log, "commit-bookkeeping: %s: %v\n", h.Name(), err)
	}
}

// writeCommitDecisionSentinel mirrors the bash _write_commit_decision
// helper. Kept in sync via the path constant — both must point at
// ${PROJECT_DIR}/${TEKHTON_DIR:-.tekhton}/.commit_decision.
func writeCommitDecisionSentinel(in *finalize.Input, decision string) error {
	tekhtonDir := os.Getenv("TEKHTON_DIR")
	if tekhtonDir == "" {
		tekhtonDir = ".tekhton"
	}
	if !filepath.IsAbs(tekhtonDir) {
		tekhtonDir = filepath.Join(in.ProjectDir, tekhtonDir)
	}
	if err := os.MkdirAll(tekhtonDir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(tekhtonDir, ".commit_decision"),
		[]byte(decision+"\n"), 0o644)
}
