// cmd/tekhton/test_audit.go — m38.4 Cobra subcommand tree for the test
// audit. The parent `tekhton test-audit` is Hidden — it exists so the
// bash shim in tekhton-legacy.sh can reach the Go implementation, not
// as a primary operator surface. Two subs:
//
//   - `run` drives test_audit.Run (pipeline-integration path)
//   - `run-standalone` drives test_audit.RunStandalone (the --audit-tests
//     CLI path)
//
// Both subs read PROJECT_DIR / TEKHTON_HOME / TESTER_REPORT_FILE / etc.
// from env so the legacy bash callers don't need to thread argv.

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/test_audit"
	"github.com/spf13/cobra"
)

func newTestAuditCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "test-audit",
		Short:  "Test audit driver (m38.4 — internal tooling)",
		Hidden: true,
	}
	c.AddCommand(newTestAuditRunCmd())
	c.AddCommand(newTestAuditRunStandaloneCmd())
	return c
}

func newTestAuditRunCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "run",
		Short: "Run the pipeline-integration test audit (m38.4)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			req := buildAuditRequest(projectDir)
			res, err := test_audit.Run(context.Background(), req)
			if err != nil {
				return err
			}
			if res == nil {
				return nil
			}
			fmt.Fprintf(cmd.OutOrStdout(), "verdict=%s agent_calls=%d rework_cycles=%d\n",
				res.Verdict.String(), res.AgentCalls, res.ReworkCycles)
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "",
		"Project directory (defaults to $PROJECT_DIR or cwd).")
	return c
}

func newTestAuditRunStandaloneCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "run-standalone",
		Short: "Run the standalone --audit-tests pass",
		RunE: func(cmd *cobra.Command, _ []string) error {
			req := buildAuditRequest(projectDir)
			res, err := test_audit.RunStandalone(context.Background(), req)
			if err != nil {
				return err
			}
			if res == nil {
				return nil
			}
			fmt.Fprintf(cmd.OutOrStdout(), "verdict=%s agent_calls=%d\n",
				res.Verdict.String(), res.AgentCalls)
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "",
		"Project directory (defaults to $PROJECT_DIR or cwd).")
	return c
}

// buildAuditRequest resolves the test_audit.Request from env + flag. Keeps
// surface symmetric with the bash shim path (the contract is "operator
// sets env, then invokes").
func buildAuditRequest(projectDirOverride string) *test_audit.Request {
	projectDir := projectDirOverride
	if projectDir == "" {
		projectDir = os.Getenv("PROJECT_DIR")
	}
	if projectDir == "" {
		projectDir, _ = os.Getwd()
	}
	envOr := func(key, fallback string) string {
		if v := os.Getenv(key); v != "" {
			return v
		}
		return fallback
	}
	resolve := func(path string) string {
		if path == "" || filepath.IsAbs(path) {
			return path
		}
		return filepath.Join(projectDir, path)
	}
	home := os.Getenv("TEKHTON_HOME")
	promptsDir := os.Getenv("PROMPTS_DIR")
	if promptsDir == "" && home != "" {
		promptsDir = filepath.Join(home, "prompts")
	}
	tekhtonDir := envOr("TEKHTON_DIR", ".tekhton")
	return &test_audit.Request{
		ProjectDir:       projectDir,
		TekhtonHome:      home,
		PromptsDir:       promptsDir,
		TesterReportFile: resolve(envOr("TESTER_REPORT_FILE", filepath.Join(tekhtonDir, "TESTER_REPORT.md"))),
		CoderSummaryFile: resolve(envOr("CODER_SUMMARY_FILE", filepath.Join(tekhtonDir, "CODER_SUMMARY.md"))),
		AuditReportFile:  resolve(envOr("TEST_AUDIT_REPORT_FILE", filepath.Join(tekhtonDir, "TEST_AUDIT_REPORT.md"))),
		NonBlockingFile:  resolve(envOr("NON_BLOCKING_LOG_FILE", filepath.Join(tekhtonDir, "NON_BLOCKING_LOG.md"))),
		TestMapFile:      os.Getenv("TEST_SYMBOL_MAP_FILE"),
		TagsFile:         os.Getenv("TEST_SYMBOL_TAGS_FILE"),
	}
}
