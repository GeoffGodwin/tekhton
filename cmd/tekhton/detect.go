package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/detect"
	"github.com/spf13/cobra"
)

// newDetectCmd wires `tekhton detect` — an internal developer subcommand
// mirroring the m21 `tekhton finalize` / m22 `tekhton preflight` shape.
// In m29.1 the surface is intentionally minimal: a single `summary`
// subcommand that runs the Go engine and emits markdown (default) or
// JSON for downstream consumers.
//
// Hidden because end users do not invoke detection directly today — the
// bash detect subsystem is still the canonical path for callers
// (lib/init.sh, lib/express.sh, lib/rescan.sh, lib/health_checks*.sh,
// tekhton-legacy.sh). m29.2 will rewrite those callers to exec this
// subcommand and delete the bash detect files.
func newDetectCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "detect",
		Short:  "Detect project tech stack and emit structured findings (internal — developer tool)",
		Hidden: true,
		Long: "Internal Cobra root for the m29 detect port. m29.1 ships the engine, " +
			"the markdown report formatter, and the languages detector. m29.2 will " +
			"register the eight remaining domain detectors (commands, workspaces, " +
			"services, ci, infrastructure, test_frameworks, doc_quality, ai_artifacts) " +
			"and atomically cut every bash caller over. Not intended for direct user " +
			"invocation today.",
	}
	c.AddCommand(newDetectSummaryCmd())
	return c
}

func newDetectSummaryCmd() *cobra.Command {
	var (
		projectDir string
		asJSON     bool
		asMD       bool
	)
	c := &cobra.Command{
		Use:   "summary",
		Short: "Run all registered detectors and emit a unified summary",
		Long: "Runs the Engine.Run loop against --project-dir (default $PWD) and " +
			"emits the unified Summary. Default output is markdown matching the " +
			"shape lib/detect_report.sh::format_detection_report produces. Pass " +
			"--json to emit the Summary as a tekhton.detect.summary.v1 JSON " +
			"envelope candidate (the proto promotion itself is a seeds-forward " +
			"item; m29.1 ships the struct as-is).",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if projectDir == "" {
				dir, err := os.Getwd()
				if err != nil {
					return fmt.Errorf("detect summary: resolve cwd: %w", err)
				}
				projectDir = dir
			}
			if asJSON && asMD {
				return errExitCode{code: exitUsage, err: fmt.Errorf("--json and --markdown are mutually exclusive")}
			}

			e := detect.New()
			e.Register(detect.LanguagesDetector{})
			// m29.2 will register the remaining eight detectors here.

			s, err := e.Run(context.Background(), projectDir)
			if err != nil {
				return fmt.Errorf("detect summary: %w", err)
			}

			if asJSON {
				enc := json.NewEncoder(cmd.OutOrStdout())
				enc.SetIndent("", "  ")
				return enc.Encode(s)
			}
			_, err = fmt.Fprint(cmd.OutOrStdout(), detect.Render(s))
			return err
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().BoolVar(&asJSON, "json", false, "emit JSON instead of markdown")
	c.Flags().BoolVar(&asMD, "markdown", false, "emit markdown (default)")
	return c
}
