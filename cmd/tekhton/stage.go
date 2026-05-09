package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/spf13/cobra"
)

// newStageCmd wires `tekhton stage …` subcommands.
//
// `tekhton stage emit` is the bash shim's escape hatch from hand-rolling JSON.
// Each stages/*.sh tail block calls `tekhton stage emit --verdict ... --stage ...`
// and the binary writes a stage.result.v1 envelope to stdout (or to
// $TEKHTON_STAGE_RESULT_FILE when --to-result-file is passed).
func newStageCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "stage",
		Short: "Stage envelope helpers (m18).",
	}
	c.AddCommand(newStageEmitCmd())
	return c
}

func newStageEmitCmd() *cobra.Command {
	var (
		stage        string
		verdict      string
		exitReason   string
		agentCalls   int
		duration     int
		nextAction   string
		filesTouched string
		humanAction  bool
		errorMessage string
		toResultFile bool
	)
	c := &cobra.Command{
		Use:   "emit",
		Short: "Write a stage.result.v1 envelope to stdout or $TEKHTON_STAGE_RESULT_FILE.",
		Long: "Used by stages/*.sh tail blocks via lib/stage_envelope.sh.\n" +
			"Pass --to-result-file to write to $TEKHTON_STAGE_RESULT_FILE (no-op when unset).",
		RunE: func(_ *cobra.Command, _ []string) error {
			if stage == "" {
				return errExitCode{code: exitUsage, err: fmt.Errorf("--stage is required")}
			}
			if !proto.IsKnownStage(stage) {
				return errExitCode{code: exitUsage, err: fmt.Errorf("unknown stage: %s", stage)}
			}
			if verdict == "" {
				return errExitCode{code: exitUsage, err: fmt.Errorf("--verdict is required")}
			}
			if !proto.IsKnownVerdict(verdict) {
				return errExitCode{code: exitUsage, err: fmt.Errorf("unknown verdict: %s", verdict)}
			}
			res := &proto.StageResultV1{
				Proto:        proto.StageResultProtoV1,
				Stage:        stage,
				Verdict:      verdict,
				ExitReason:   exitReason,
				AgentCalls:   agentCalls,
				DurationSec:  duration,
				NextAction:   nextAction,
				HumanAction:  humanAction,
				Error:        errorMessage,
				FilesTouched: parseCommaSeparated(filesTouched),
			}
			b, err := res.MarshalIndented()
			if err != nil {
				return err
			}
			if toResultFile {
				path := os.Getenv("TEKHTON_STAGE_RESULT_FILE")
				if path == "" {
					return errExitCode{code: exitUsage, err: fmt.Errorf("--to-result-file set but TEKHTON_STAGE_RESULT_FILE unset")}
				}
				if err := os.WriteFile(path, append(b, '\n'), 0o644); err != nil {
					return err
				}
				return nil
			}
			fmt.Println(string(b))
			return nil
		},
	}
	c.Flags().StringVar(&stage, "stage", "", "stage name (intake|coder|security|review|tester|cleanup|docs)")
	c.Flags().StringVar(&verdict, "verdict", "", "verdict (pass|fail|rework|block|skip)")
	c.Flags().StringVar(&exitReason, "exit-reason", "", "short human-readable exit reason")
	c.Flags().IntVar(&agentCalls, "agent-calls", 0, "number of agent invocations during this stage")
	c.Flags().IntVar(&duration, "duration", 0, "duration in seconds")
	c.Flags().StringVar(&nextAction, "next-action", "", "stage-specific next-action hint")
	c.Flags().StringVar(&filesTouched, "files-touched", "", "comma-separated files modified by this stage")
	c.Flags().BoolVar(&humanAction, "human-action", false, "set when human action is required")
	c.Flags().StringVar(&errorMessage, "error", "", "error message when verdict=fail/block")
	c.Flags().BoolVar(&toResultFile, "to-result-file", false, "write to $TEKHTON_STAGE_RESULT_FILE instead of stdout")
	return c
}

// parseCommaSeparated returns a slice from a comma-separated string,
// trimming whitespace and dropping empty entries.
func parseCommaSeparated(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
