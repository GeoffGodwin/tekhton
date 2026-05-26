package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/geoffgodwin/tekhton/internal/clarify"
	"github.com/spf13/cobra"
)

// newClarifyCmd wires `tekhton clarify ...` subcommands. Hidden —
// internal seam used by the bash stages that call clarify mid-pipeline
// (replacing the source on lib/clarify.sh) and by the new finalize
// hook that clears stale state on success.
func newClarifyCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "clarify",
		Short:  "Mid-pipeline clarification protocol (m25 internal seam)",
		Hidden: true,
	}
	c.AddCommand(newClarifyDetectCmd())
	c.AddCommand(newClarifyHandleCmd())
	c.AddCommand(newClarifyClearCmd())
	return c
}

// clarificationsPath resolves CLARIFICATIONS.md given project-dir +
// the optional $CLARIFICATIONS_FILE override. Matches the bash
// convention.
func clarificationsPath(projectDir, override string) string {
	if projectDir == "" {
		projectDir, _ = os.Getwd()
	}
	if override == "" {
		override = os.Getenv("CLARIFICATIONS_FILE")
	}
	if override == "" {
		override = "CLARIFICATIONS.md"
	}
	if filepath.IsAbs(override) {
		return override
	}
	return filepath.Join(projectDir, override)
}

func newClarifyDetectCmd() *cobra.Command {
	var (
		report string
	)
	c := &cobra.Command{
		Use:   "detect --report PATH",
		Short: "Exit 1 when REPORT contains unchecked clarifications, 0 otherwise",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if report == "" {
				return errExitCode{code: exitUsage, err: fmt.Errorf("--report is required")}
			}
			items, err := clarify.DetectFromFile(report, clarify.DetectOptions{})
			if err != nil {
				if errors.Is(err, clarify.ErrNoClarifications) || errors.Is(err, clarify.ErrDisabled) {
					return nil // exit 0
				}
				return err
			}
			if items.HasBlocking() {
				return errExitCode{code: 1, err: fmt.Errorf("%d blocking clarification(s) detected", len(items.Blocking))}
			}
			// Non-blocking only — exit 0 with a friendly log line.
			fmt.Fprintf(cmd.ErrOrStderr(),
				"clarify: %d non-blocking item(s); no pause needed\n", len(items.NonBlocking))
			return nil
		},
	}
	c.Flags().StringVar(&report, "report", "", "report file to scan (e.g. CODER_SUMMARY.md)")
	return c
}

func newClarifyHandleCmd() *cobra.Command {
	var (
		report     string
		projectDir string
		override   string
		timeoutS   int
	)
	c := &cobra.Command{
		Use:   "handle --report PATH",
		Short: "Pause for blocking clarification answers; resume when answered",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if report == "" {
				return errExitCode{code: exitUsage, err: fmt.Errorf("--report is required")}
			}
			items, err := clarify.DetectFromFile(report, clarify.DetectOptions{})
			if err != nil {
				if errors.Is(err, clarify.ErrNoClarifications) || errors.Is(err, clarify.ErrDisabled) {
					return nil
				}
				return err
			}
			cpath := clarificationsPath(projectDir, override)
			ctx, cancel := context.WithCancel(cmd.Context())
			defer cancel()
			if timeoutS > 0 {
				var c2 context.CancelFunc
				ctx, c2 = context.WithTimeout(ctx, time.Duration(timeoutS)*time.Second)
				defer c2()
			}
			// If a /dev/tty is available, prompt interactively;
			// otherwise poll for an external edit (dashboard path).
			if _, err := os.Stat("/dev/tty"); err == nil && os.Getenv("TEKHTON_TEST_MODE") == "" {
				return clarify.HandleInteractive(items, clarify.HandleOptions{
					ClarificationsPath: cpath,
				})
			}
			return clarify.PollUntilAnswered(ctx, items, cpath, 5*time.Second)
		},
	}
	c.Flags().StringVar(&report, "report", "", "report file to scan")
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().StringVar(&override, "clarifications-file", "", "CLARIFICATIONS.md path override")
	c.Flags().IntVar(&timeoutS, "timeout", 0, "max seconds to wait (0 = forever)")
	return c
}

func newClarifyClearCmd() *cobra.Command {
	var (
		projectDir string
		override   string
	)
	c := &cobra.Command{
		Use:   "clear",
		Short: "Remove fully-answered CLARIFICATIONS.md (finalize cleanup)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := clarificationsPath(projectDir, override)
			removed, err := clarify.ClearStaleEntries(path)
			if err != nil {
				return err
			}
			if removed {
				fmt.Fprintf(cmd.OutOrStdout(), "clarify: removed %s\n", path)
			}
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().StringVar(&override, "clarifications-file", "", "CLARIFICATIONS.md path override")
	return c
}
