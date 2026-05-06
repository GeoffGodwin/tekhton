// Command tekhton is the Go entry point for the Tekhton pipeline.
//
// In V4 (Ship-of-Theseus migration from Bash) this binary is a stub root.
// Subcommands (tekhton causal, tekhton supervise, ...) are wired in by the
// Phase 1+ wedges. Today the binary exists so it can be built, shipped via
// CI, and reached on $PATH during self-hosted pipeline runs — no production
// bash code path invokes it yet.
package main

import (
	"errors"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/version"
	"github.com/spf13/cobra"
)

func newRootCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "tekhton",
		Short: "Tekhton — multi-agent development pipeline (Go entry point)",
		Long: "Tekhton is a multi-agent development pipeline. The Go binary is the\n" +
			"V4 entry point and currently exposes only --version and --help; all\n" +
			"runtime behavior is still driven by tekhton.sh and the Bash pipeline.",
		Version:       version.String(),
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			_ = cmd.Help()
			return errors.New("no subcommand specified")
		},
	}
	cmd.SetVersionTemplate("{{.Version}}\n")
	cmd.AddCommand(newCausalCmd())
	cmd.AddCommand(newStateCmd())
	cmd.AddCommand(newSuperviseCmd())
	cmd.AddCommand(newQuotaCmd())
	cmd.AddCommand(newOrchestrateCmd())
	cmd.AddCommand(newManifestCmd())
	return cmd
}

// exitCoder is implemented by errors that carry a non-default exit code
// (currently used by `state read` to distinguish missing vs corrupt files).
type exitCoder interface{ ExitCode() int }

func main() {
	if err := newRootCmd().Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "tekhton:", err)
		var ec exitCoder
		if errors.As(err, &ec) {
			os.Exit(ec.ExitCode())
		}
		os.Exit(1)
	}
}
