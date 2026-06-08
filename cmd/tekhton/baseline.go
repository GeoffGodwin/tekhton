// cmd/tekhton/baseline.go — m38.5 Cobra subcommand tree for the test
// baseline subsystem. The parent `tekhton baseline` is Hidden — it exists
// so the bash shim in lib/test_baseline_cleanup.sh and any remaining bash
// callers can reach the Go implementation, not as a primary operator
// surface. Five subs:
//
//   - capture <milestone>       — run TEST_CMD and write the baseline files
//   - has <milestone>           — exit 0 iff a baseline for milestone exists
//   - compare --output PATH     — classify current output vs baseline
//   - acceptance-stuck          — diagnostic state-machine probe
//   - get-exit-code             — print the baseline exit_code, "" when absent
//
// All subs resolve PROJECT_DIR and TEST_CMD from env. The bash shim
// invariants (atomic writes, normalization regexes, M92 false default)
// live in internal/test_baseline.

package main

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/geoffgodwin/tekhton/internal/test_baseline"
	"github.com/spf13/cobra"
)

func newBaselineCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "baseline",
		Short:  "Test baseline driver (m38.5 — internal tooling)",
		Hidden: true,
	}
	c.AddCommand(newBaselineCaptureCmd())
	c.AddCommand(newBaselineHasCmd())
	c.AddCommand(newBaselineCompareCmd())
	c.AddCommand(newBaselineAcceptanceStuckCmd())
	c.AddCommand(newBaselineGetExitCodeCmd())
	return c
}

func resolveBaselineProjectDir(override string) string {
	if override != "" {
		return override
	}
	if v := os.Getenv("PROJECT_DIR"); v != "" {
		return v
	}
	cwd, _ := os.Getwd()
	return cwd
}

func newBaselineCaptureCmd() *cobra.Command {
	var projectDir, runID, testCmd string
	c := &cobra.Command{
		Use:   "capture <milestone>",
		Short: "Capture a test baseline for <milestone>",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			milestone := args[0]
			dir := resolveBaselineProjectDir(projectDir)
			if testCmd == "" {
				testCmd = os.Getenv("TEST_CMD")
			}
			if runID == "" {
				runID = os.Getenv("TIMESTAMP")
			}
			bl, err := test_baseline.Capture(context.Background(), test_baseline.CaptureOptions{
				Milestone:  milestone,
				RunID:      runID,
				ProjectDir: dir,
				TestCmd:    testCmd,
			})
			if err != nil {
				return err
			}
			if bl == nil {
				fmt.Fprintln(cmd.OutOrStdout(), "no TEST_CMD configured — baseline skipped")
				return nil
			}
			fmt.Fprintf(cmd.OutOrStdout(),
				"captured milestone=%s exit=%d failure_count=%d\n",
				bl.Milestone, bl.ExitCode, bl.FailureCount)
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "Project directory.")
	c.Flags().StringVar(&runID, "run-id", "", "Run ID (defaults to $TIMESTAMP).")
	c.Flags().StringVar(&testCmd, "test-cmd", "", "Override TEST_CMD.")
	return c
}

func newBaselineHasCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "has <milestone>",
		Short: "Exit 0 iff a baseline for <milestone> exists, 1 otherwise",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			dir := resolveBaselineProjectDir(projectDir)
			if test_baseline.Has(args[0], dir) {
				return nil
			}
			return errExitCode{code: 1}
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "Project directory.")
	return c
}

func newBaselineCompareCmd() *cobra.Command {
	var projectDir, outputPath string
	var exitCode int
	c := &cobra.Command{
		Use:   "compare",
		Short: "Classify --output against the captured baseline",
		RunE: func(cmd *cobra.Command, _ []string) error {
			dir := resolveBaselineProjectDir(projectDir)
			var body string
			if outputPath != "" {
				data, err := os.ReadFile(outputPath)
				if err != nil {
					return err
				}
				body = string(data)
			} else {
				data, err := io.ReadAll(cmd.InOrStdin())
				if err != nil {
					return err
				}
				body = string(data)
			}
			v, err := test_baseline.Compare(body, exitCode, dir)
			if err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), v.String())
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "Project directory.")
	c.Flags().StringVar(&outputPath, "output", "", "Path to current test output (defaults to stdin).")
	c.Flags().IntVar(&exitCode, "exit", 1, "Current test exit code (informational).")
	return c
}

func newBaselineAcceptanceStuckCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "acceptance-stuck",
		Short: "Print the current acceptance output hash (diagnostic)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			dir := resolveBaselineProjectDir(projectDir)
			hash, err := test_baseline.GetAcceptanceOutputHash(dir)
			if err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), hash)
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "Project directory.")
	return c
}

func newBaselineGetExitCodeCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "get-exit-code",
		Short: "Print the baseline exit code, or empty string when no baseline",
		RunE: func(cmd *cobra.Command, _ []string) error {
			dir := resolveBaselineProjectDir(projectDir)
			fmt.Fprintln(cmd.OutOrStdout(), test_baseline.GetBaselineExitCode(dir))
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "Project directory.")
	return c
}
