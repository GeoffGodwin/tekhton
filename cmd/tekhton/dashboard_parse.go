// dashboard_parse.go — `tekhton dashboard parse <kind>` Cobra arms.
//
// Each parse arm runs a StatusReader method against a fixture file and
// prints the resulting JSON payload to stdout. Used by the m33.2 parity
// gate and as a developer-facing debug entry point. Hidden because end
// users address the parsers transitively via emit, not directly.

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/dashboard"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/spf13/cobra"
)

// newDashboardParseCmd builds the `tekhton dashboard parse` parent and its
// five sub-subcommands (security/intake/coder/reviewer/runs).
func newDashboardParseCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "parse",
		Short:  "Parse a stage report file and print the typed payload as JSON",
		Long:   "Internal subcommand owning the Watchtower dashboard data parsers.",
		Hidden: true,
	}
	c.AddCommand(newDashboardParseSecurityCmd())
	c.AddCommand(newDashboardParseIntakeCmd())
	c.AddCommand(newDashboardParseCoderCmd())
	c.AddCommand(newDashboardParseReviewerCmd())
	c.AddCommand(newDashboardParseRunsCmd())
	return c
}

func newDashboardParseSecurityCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "security <file>",
		Short: "Parse SECURITY_REPORT.md and print findings",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			r := &dashboard.StatusReader{}
			payload, err := r.ParseSecurity(args[0])
			if err != nil {
				return fmt.Errorf("dashboard parse security: %w", err)
			}
			return printJSONTo(cmd.OutOrStdout(), payload)
		},
	}
}

func newDashboardParseIntakeCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "intake <file>",
		Short: "Parse INTAKE_REPORT.md and print verdict/confidence/task_text",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			r := &dashboard.StatusReader{}
			payload, err := r.ParseIntake(args[0])
			if err != nil {
				return fmt.Errorf("dashboard parse intake: %w", err)
			}
			return printJSONTo(cmd.OutOrStdout(), payload)
		},
	}
}

func newDashboardParseCoderCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "coder <file>",
		Short: "Parse CODER_SUMMARY.md and print status/files_modified",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			r := &dashboard.StatusReader{}
			payload, err := r.ParseCoder(args[0])
			if err != nil {
				return fmt.Errorf("dashboard parse coder: %w", err)
			}
			return printJSONTo(cmd.OutOrStdout(), payload)
		},
	}
}

func newDashboardParseReviewerCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "reviewer <file>",
		Short: "Parse REVIEWER_REPORT.md and print verdict",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			r := &dashboard.StatusReader{}
			payload, err := r.ParseReviewer(args[0])
			if err != nil {
				return fmt.Errorf("dashboard parse reviewer: %w", err)
			}
			return printJSONTo(cmd.OutOrStdout(), payload)
		},
	}
}

func newDashboardParseRunsCmd() *cobra.Command {
	var metrics, summaries string
	var depth int
	c := &cobra.Command{
		Use:   "runs",
		Short: "Parse metrics.jsonl (primary) or RUN_SUMMARY_*.json (fallback)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			r := &dashboard.StatusReader{}
			if summaries == "" && metrics != "" {
				// When only --metrics is supplied, fall the summaries dir
				// back to the same parent (matches lib/dashboard_parsers_runs.sh
				// which derives both from the single `dir` arg).
				summaries = filepath.Dir(metrics)
			}
			runs, err := r.ParseRunSummaries(metrics, summaries, depth)
			if err != nil {
				return fmt.Errorf("dashboard parse runs: %w", err)
			}
			if runs == nil {
				runs = []proto.DashboardRunSummary{}
			}
			return printJSONTo(cmd.OutOrStdout(), runs)
		},
	}
	c.Flags().StringVar(&metrics, "metrics", "", "path to metrics.jsonl (primary path)")
	c.Flags().StringVar(&summaries, "summaries", "", "directory of RUN_SUMMARY_*.json files (fallback path)")
	c.Flags().IntVar(&depth, "depth", 50, "maximum number of records to return")
	return c
}

// printJSONTo marshals payload and writes it followed by a newline.
func printJSONTo(w io.Writer, payload any) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	_, err = w.Write(append(b, '\n'))
	return err
}
