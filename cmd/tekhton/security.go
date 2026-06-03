package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/security"
	"github.com/spf13/cobra"
)

// newSecurityCmd wires `tekhton security ...` subcommands. The parent
// command is visible after m35.2 — operators use `parse-findings` and
// `meets-threshold` to inspect SECURITY_REPORT.md by hand. `build-block`
// and `is-docs-only` stay Hidden as debug-only tools. `handle-unfixable`
// was a shim-only entry point and is removed in m35.2 (the Go stage calls
// security.Escalator.HandleUnfixable in-process). Retention precedent:
// m17 kept `tekhton diagnose classify` after the bash classifier ported.
func newSecurityCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "security",
		Short: "Inspect SECURITY_REPORT.md and security-stage findings",
	}
	c.AddCommand(newSecurityParseFindingsCmd())
	c.AddCommand(newSecurityMeetsThresholdCmd())
	c.AddCommand(newSecurityBuildBlockCmd())
	c.AddCommand(newSecurityIsDocsOnlyCmd())
	return c
}

// newSecurityParseFindingsCmd emits SECURITY_REPORT.md rows as TSV or JSON.
// Operator-facing after m35.2 — inspect what `internal/security.ParseReport`
// saw without reading the report by hand. TSV format: three tab-separated
// columns (severity, fixable, description); descriptions containing a tab
// will mis-split, which matched the bash shim's vulnerability before m35.2.
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
// forms (fixable / unfixable / notes) to stdout. Debug-only — the Go stage
// calls internal/security.BuildFixableBlock etc. in-process. Kept Hidden for
// hand-driven block inspection from a debugging shell.
func newSecurityBuildBlockCmd() *cobra.Command {
	var report, kind, threshold string
	c := &cobra.Command{
		Use:    "build-block",
		Short:  "Build one of fixable | unfixable | notes from SECURITY_REPORT.md",
		Hidden: true,
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
// present or the summary is missing. Debug-only — the Go stage calls
// internal/security.IsDocsOnly in-process. Kept Hidden for hand-driven
// checks from a debugging shell.
func newSecurityIsDocsOnlyCmd() *cobra.Command {
	var summary string
	c := &cobra.Command{
		Use:    "is-docs-only",
		Short:  "Exit 0 when every file in --summary is docs/config/assets",
		Hidden: true,
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

// m35.2: handle-unfixable was a shim-only subcommand; deleted alongside
// lib/security_helpers.sh. The Go stage calls
// internal/security.Escalator.HandleUnfixable directly via the in-process
// seam. Operators who want to write an escalation row by hand should use
// `tekhton drift human-action append` instead.
