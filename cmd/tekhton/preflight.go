package main

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/preflight"
	"github.com/spf13/cobra"
)

// newPreflightCmd wires `tekhton preflight` — an internal developer
// subcommand for two use cases mirroring m21's `tekhton finalize` shape:
//
//  1. The bash legacy compatibility shim in tekhton-legacy.sh delegates
//     here so the V3 entry-point's `run_preflight_checks` call site keeps
//     working after the bash preflight subsystem is deleted.
//  2. The m22 parity gate (tests/test_preflight_parity.sh) drives this
//     subcommand against frozen fixtures to assert byte-identical output
//     vs the captured bash baselines.
//
// Hidden because end users only see preflight transitively via
// `tekhton run`.
func newPreflightCmd() *cobra.Command {
	var (
		projectDir string
		home       string
	)
	c := &cobra.Command{
		Use:   "preflight",
		Short: "Run pre-flight environment checks (internal — developer tool)",
		Long: "Internal subcommand used by the V3 legacy entry point's " +
			"`run_preflight_checks` shim and the m22 parity gate. Not intended " +
			"for direct user invocation.\n\n" +
			"Behavior: constructs internal/preflight.Orchestrator and drives the " +
			"five registered check families (foundation, ui_audit, env, " +
			"services_infer, services). Exits non-zero when any check returns a " +
			"blocking finding (HasBlockers).",
		Hidden: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if projectDir == "" {
				projectDir, _ = os.Getwd()
			}
			if home == "" {
				home = os.Getenv("TEKHTON_HOME")
			}
			o := preflight.NewOrchestrator(home, projectDir)
			o.Log = cmd.ErrOrStderr()
			ctx := context.Background()
			if _, err := o.Run(ctx); err != nil {
				return fmt.Errorf("preflight: %w", err)
			}
			fmt.Fprintln(cmd.ErrOrStderr(), o.SummaryLine())
			if o.HasBlockers() {
				return errExitCode{
					code: 1,
					err:  errors.New("preflight: blocking issues found — see PREFLIGHT_REPORT.md"),
				}
			}
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().StringVar(&home, "home", "", "TEKHTON_HOME (defaults to $TEKHTON_HOME)")
	return c
}
