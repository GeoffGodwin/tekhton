package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/security"
	"github.com/spf13/cobra"
)

// newSecurityCmd wires `tekhton security ...` subcommands. Hidden — this is
// the m35.1 internal seam the bash shim (lib/security_helpers.sh) calls into
// while the bash stage (stages/security.sh) is still in flight. m35.2 ports
// the stage; the operator-facing subset (`parse-findings`, etc.) stays after
// m35.2 closes for manual report inspection, mirroring m17's diagnose
// retention pattern.
func newSecurityCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "security",
		Short:  "Security helpers (m35.1 internal seam)",
		Hidden: true,
	}
	c.AddCommand(newSecurityParseFindingsCmd())
	c.AddCommand(newSecurityMeetsThresholdCmd())
	c.AddCommand(newSecurityBuildBlockCmd())
	c.AddCommand(newSecurityIsDocsOnlyCmd())
	c.AddCommand(newSecurityHandleUnfixableCmd())
	return c
}

// newSecurityParseFindingsCmd emits SECURITY_REPORT.md rows as TSV or JSON.
// The TSV format is a load-bearing contract for the bash shim: three
// tab-separated columns (severity, fixable, description). If a description
// ever contains a tab, the shim parser will mis-split; the bash version had
// the same vulnerability so m35.1 preserves the behavior.
func newSecurityParseFindingsCmd() *cobra.Command {
	var report, format string
	c := &cobra.Command{
		Use:   "parse-findings",
		Short: "Parse SECURITY_REPORT.md and emit findings as TSV or JSON",
		RunE: func(cmd *cobra.Command, _ []string) error {
			fs, err := security.ParseReport(report)
			if err != nil {
				return err
			}
			switch format {
			case "", "tsv":
				for _, f := range fs {
					fmt.Fprintf(cmd.OutOrStdout(), "%s\t%s\t%s\n", f.Severity, f.Fixable, f.Description)
				}
				return nil
			case "json":
				enc := json.NewEncoder(cmd.OutOrStdout())
				enc.SetIndent("", "  ")
				return enc.Encode(fs)
			default:
				return fmt.Errorf("unknown --format %q (want tsv or json)", format)
			}
		},
	}
	c.Flags().StringVar(&report, "report", "", "path to SECURITY_REPORT.md")
	c.Flags().StringVar(&format, "format", "tsv", "output format: tsv | json")
	_ = c.MarkFlagRequired("report")
	return c
}

// newSecurityMeetsThresholdCmd exits 0 when --severity meets --threshold,
// 1 otherwise. The bash shim relies on the exit-code contract so the
// `if _severity_meets_threshold ...; then` callers work unchanged.
func newSecurityMeetsThresholdCmd() *cobra.Command {
	var sev, thr string
	c := &cobra.Command{
		Use:   "meets-threshold",
		Short: "Exit 0 when --severity meets --threshold; 1 otherwise",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if security.MeetsThreshold(security.Severity(sev), security.Severity(thr)) {
				return nil
			}
			// Suppress the default "tekhton: ..." stderr line by silencing usage.
			cmd.SilenceUsage = true
			cmd.SilenceErrors = true
			os.Exit(1)
			return nil
		},
	}
	c.Flags().StringVar(&sev, "severity", "", "severity to test")
	c.Flags().StringVar(&thr, "threshold", "", "threshold to meet")
	_ = c.MarkFlagRequired("severity")
	_ = c.MarkFlagRequired("threshold")
	return c
}

// newSecurityBuildBlockCmd parses a report and emits one of the three block
// forms (fixable / unfixable / notes) to stdout. The bash shim captures the
// output via $(...) and feeds it into prompts.
func newSecurityBuildBlockCmd() *cobra.Command {
	var report, kind, threshold string
	c := &cobra.Command{
		Use:   "build-block",
		Short: "Build one of fixable | unfixable | notes from SECURITY_REPORT.md",
		RunE: func(cmd *cobra.Command, _ []string) error {
			fs, err := security.ParseReport(report)
			if err != nil {
				return err
			}
			thr := security.Severity(threshold)
			var out string
			switch kind {
			case "fixable":
				out = security.BuildFixableBlock(fs, thr)
			case "unfixable":
				out = security.BuildUnfixableBlock(fs, thr)
			case "notes":
				out = security.BuildNotesBlock(fs, thr)
			default:
				return fmt.Errorf("unknown --kind %q (want fixable, unfixable, or notes)", kind)
			}
			fmt.Fprint(cmd.OutOrStdout(), out)
			return nil
		},
	}
	c.Flags().StringVar(&report, "report", "", "path to SECURITY_REPORT.md")
	c.Flags().StringVar(&kind, "kind", "", "block kind: fixable | unfixable | notes")
	c.Flags().StringVar(&threshold, "threshold", "HIGH", "blocking severity threshold")
	_ = c.MarkFlagRequired("report")
	_ = c.MarkFlagRequired("kind")
	return c
}

// newSecurityIsDocsOnlyCmd exits 0 when every file in the coder summary is
// in the docs/config/assets allowlist; exits 1 when any code file is
// present or the summary is missing. The exit-code contract matches the
// bash _security_is_docs_only return semantics so the shim's `if`
// conditional flips correctly.
func newSecurityIsDocsOnlyCmd() *cobra.Command {
	var summary string
	c := &cobra.Command{
		Use:   "is-docs-only",
		Short: "Exit 0 when every file in --summary is docs/config/assets",
		RunE: func(cmd *cobra.Command, _ []string) error {
			ok, err := security.IsDocsOnly(summary)
			if err != nil {
				return err
			}
			if ok {
				return nil
			}
			cmd.SilenceUsage = true
			cmd.SilenceErrors = true
			os.Exit(1)
			return nil
		},
	}
	c.Flags().StringVar(&summary, "summary", "", "path to CODER_SUMMARY.md")
	_ = c.MarkFlagRequired("summary")
	return c
}

// newSecurityHandleUnfixableCmd applies SECURITY_UNFIXABLE_POLICY to the
// supplied --block. Exit 0 → continue pipeline; exit 1 → halt (caller must
// write pipeline state — that's the bash stage's responsibility today and
// m35.2's RunStage tomorrow).
func newSecurityHandleUnfixableCmd() *cobra.Command {
	var policy, block, task, projectDir, haFile string
	c := &cobra.Command{
		Use:   "handle-unfixable",
		Short: "Apply unfixable-finding policy; exit 1 on halt branch",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if projectDir == "" {
				projectDir, _ = os.Getwd()
			}
			var e *security.Escalator
			switch {
			case haFile != "":
				e = security.NewEscalatorWithPath(haFile)
			default:
				// humanActionPath is defined in drift.go and shared across
				// every `tekhton ... human-action` consumer so the bash
				// _handle_unfixable_findings shim and the direct
				// `tekhton drift human-action append` path resolve to the
				// same file.
				e = security.NewEscalatorWithPath(humanActionPath(projectDir))
			}
			cont, err := e.HandleUnfixable(policy, block, task)
			if err != nil {
				// Matches bash `... || warn "..."`: log to stderr and continue
				// when cont=true; treat as terminal otherwise.
				fmt.Fprintln(cmd.ErrOrStderr(), "warn:", err)
			}
			if cont {
				return nil
			}
			cmd.SilenceUsage = true
			cmd.SilenceErrors = true
			os.Exit(1)
			return nil
		},
	}
	c.Flags().StringVar(&policy, "policy", "escalate", "unfixable policy: escalate | halt | waiver")
	c.Flags().StringVar(&block, "block", "", "unfixable findings block (markdown lines)")
	c.Flags().StringVar(&task, "task", "", "pipeline task description (for parity)")
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().StringVar(&haFile, "human-action-file", "", "explicit HUMAN_ACTION_REQUIRED.md path override")
	return c
}

// humanActionPath is defined in drift.go — the shared resolver matches the
// bash $HUMAN_ACTION_FILE convention every CLI subcommand that writes to
// HUMAN_ACTION_REQUIRED.md must honor.
