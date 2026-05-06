package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/geoffgodwin/tekhton/internal/orchestrate"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/spf13/cobra"
)

// newOrchestrateCmd wires `tekhton orchestrate` and its subcommands. m12 is
// the wedge that lifts the outer pipeline loop from lib/orchestrate.sh into
// internal/orchestrate. Subcommands:
//
//	classify  — pure recovery dispatch (input: stage outcome JSON; output:
//	            recovery class string). Used by parity tests + the bash shim
//	            when it wants the Go classifier without driving stages.
//	run-attempt — drive the outer loop. m12 ships the scaffold; the bash
//	            stage runner is wired in incrementally as follow-up wedges
//	            (m13/m14) reduce the bash↔Go boundary.
func newOrchestrateCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "orchestrate",
		Short: "Orchestration loop subcommands (m12 wedge — replaces lib/orchestrate.sh).",
		Long: "The outer pipeline loop ported from lib/orchestrate.sh. The bash\n" +
			"front-end (tekhton.sh) renders task / milestone context, then\n" +
			"hands an attempt.request.v1 envelope to `tekhton orchestrate\n" +
			"run-attempt`. Stages themselves remain bash for m12 (CLAUDE.md\n" +
			"Rule 9 wedge discipline: port the loop, not the stages).",
		SilenceErrors: true,
		SilenceUsage:  true,
	}
	c.AddCommand(newOrchestrateClassifyCmd())
	c.AddCommand(newOrchestrateRunAttemptCmd())
	return c
}

// newOrchestrateClassifyCmd wires `tekhton orchestrate classify`. The input
// is a stage-outcome JSON envelope on stdin (or --outcome-file); the output
// is a single-line recovery class on stdout. Exit code is always 0 unless
// the envelope is malformed (exitUsage) or stdout fails (exitSoftware).
func newOrchestrateClassifyCmd() *cobra.Command {
	var outcomeFile string
	var envGateRetried bool
	var mixedBuildRetried bool
	c := &cobra.Command{
		Use:   "classify",
		Short: "Classify a stage outcome into a recovery action (pure dispatch).",
		Long: "Reads a stage-outcome JSON object from stdin or --outcome-file and\n" +
			"prints the recovery action string (save_exit | split | bump_review\n" +
			"| retry_coder_build | retry_ui_gate_env). Pure function — no\n" +
			"side effects. Used by scripts/orchestrate-parity-check.sh.",
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			outcome, err := readOrchestrateOutcome(outcomeFile, cmd.InOrStdin())
			if err != nil {
				return errExitCode{code: exitUsage, err: err}
			}
			cfg := orchestrate.DefaultConfig()
			loop := orchestrate.New(nil, cfg)
			// Persistent guards may be passed as flags so callers can simulate
			// the second-attempt branch of the recovery dispatch.
			loop.SetEnvGateRetried(envGateRetried)
			loop.SetMixedBuildRetried(mixedBuildRetried)
			recovery := loop.Classify(*outcome, cfg)
			if _, err := fmt.Fprintln(cmd.OutOrStdout(), recovery); err != nil {
				return errExitCode{code: exitSoftware, err: err}
			}
			return nil
		},
	}
	c.Flags().StringVar(&outcomeFile, "outcome-file", "", "Path to outcome JSON. Reads stdin when omitted.")
	c.Flags().BoolVar(&envGateRetried, "env-gate-retried", false, "Simulate _ORCH_ENV_GATE_RETRIED=1 — env gate already retried this run.")
	c.Flags().BoolVar(&mixedBuildRetried, "mixed-build-retried", false, "Simulate _ORCH_MIXED_BUILD_RETRIED=1 — mixed-uncertain build classification already retried.")
	return c
}

// newOrchestrateRunAttemptCmd wires `tekhton orchestrate run-attempt`. m12
// ships the entry point with a documented stub StageRunner — the bash front
// end of tekhton.sh continues to drive stages directly until follow-up
// wedges (m13/m14) carve down the boundary. Callers may pass --no-stages
// to skip RunStages entirely (parity-test path).
func newOrchestrateRunAttemptCmd() *cobra.Command {
	var requestFile string
	var noStages bool
	c := &cobra.Command{
		Use:   "run-attempt",
		Short: "Run a pipeline attempt (m12 — outer loop in Go, stages still in bash).",
		Long: "Reads a tekhton.attempt.request.v1 envelope on stdin or from\n" +
			"--request-file and prints a tekhton.attempt.result.v1 envelope on\n" +
			"stdout. Exit code 0 on success; safety-bound and recoverable-failure\n" +
			"results print the result envelope and exit 0; unrecoverable\n" +
			"failures print the result envelope and exit 1.\n\n" +
			"--no-stages skips stage execution and emits a synthetic\n" +
			"\"stages_skipped\" result. Used by the parity test harness so the\n" +
			"loop's safety-bound + envelope shape can be asserted without\n" +
			"shelling back to bash.",
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			req, err := readAttemptRequest(requestFile, cmd.InOrStdin())
			if err != nil {
				if errors.Is(err, proto.ErrInvalidAttemptRequest) {
					return errExitCode{code: exitUsage, err: err}
				}
				return errExitCode{code: exitSoftware, err: err}
			}
			if err := req.Validate(); err != nil {
				return errExitCode{code: exitUsage, err: err}
			}

			runner := newDefaultStageRunner(noStages)
			loop := orchestrate.New(runner, orchestrate.DefaultConfig())
			res, err := loop.RunAttempt(context.Background(), req)
			if err != nil && res == nil {
				return errExitCode{code: exitSoftware, err: err}
			}
			res.EnsureProto()
			data, marshalErr := res.MarshalIndented()
			if marshalErr != nil {
				return errExitCode{code: exitSoftware, err: fmt.Errorf("orchestrate: marshal result: %w", marshalErr)}
			}
			if _, werr := fmt.Fprintln(cmd.OutOrStdout(), string(data)); werr != nil {
				return errExitCode{code: exitSoftware, err: werr}
			}
			if res.Outcome == proto.AttemptOutcomeFailureSaveExit {
				return errExitCode{code: 1, err: fmt.Errorf("attempt failed: %s", res.Recovery)}
			}
			return nil
		},
	}
	c.Flags().StringVar(&requestFile, "request-file", "", "Path to attempt.request.v1 JSON. Reads stdin when omitted.")
	c.Flags().BoolVar(&noStages, "no-stages", false, "Skip stage execution; emit a synthetic \"stages_skipped\" result.")
	return c
}

func readAttemptRequest(path string, stdin io.Reader) (*proto.AttemptRequestV1, error) {
	var data []byte
	var err error
	if path != "" {
		data, err = os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read --request-file: %w", err)
		}
	} else {
		data, err = io.ReadAll(stdin)
		if err != nil {
			return nil, fmt.Errorf("read stdin: %w", err)
		}
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("%w: empty request", proto.ErrInvalidAttemptRequest)
	}
	var req proto.AttemptRequestV1
	if err := json.Unmarshal(data, &req); err != nil {
		return nil, fmt.Errorf("%w: parse: %v", proto.ErrInvalidAttemptRequest, err)
	}
	return &req, nil
}

// stageOutcomeJSON is the wire shape for `tekhton orchestrate classify` input.
// Field names match orchestrate.StageOutcome's JSON form.
type stageOutcomeJSON struct {
	Success             bool   `json:"success,omitempty"`
	TurnsUsed           int    `json:"turns_used,omitempty"`
	AgentCalls          int    `json:"agent_calls,omitempty"`
	ErrorCategory       string `json:"error_category,omitempty"`
	ErrorSubcategory    string `json:"error_subcategory,omitempty"`
	ErrorMessage        string `json:"error_message,omitempty"`
	Verdict             string `json:"verdict,omitempty"`
	PrimaryCat          string `json:"primary_cat,omitempty"`
	PrimarySub          string `json:"primary_sub,omitempty"`
	PrimarySignal       string `json:"primary_signal,omitempty"`
	SecondaryCat        string `json:"secondary_cat,omitempty"`
	SecondarySub        string `json:"secondary_sub,omitempty"`
	BuildClassification string `json:"build_classification,omitempty"`
	BuildErrorsPresent  bool   `json:"build_errors_present,omitempty"`
}

func readOrchestrateOutcome(path string, stdin io.Reader) (*orchestrate.StageOutcome, error) {
	var data []byte
	var err error
	if path != "" {
		data, err = os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read --outcome-file: %w", err)
		}
	} else {
		data, err = io.ReadAll(stdin)
		if err != nil {
			return nil, fmt.Errorf("read stdin: %w", err)
		}
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("classify: empty outcome")
	}
	var w stageOutcomeJSON
	if err := json.Unmarshal(data, &w); err != nil {
		return nil, fmt.Errorf("classify: parse: %w", err)
	}
	return &orchestrate.StageOutcome{
		Success:             w.Success,
		TurnsUsed:           w.TurnsUsed,
		AgentCalls:          w.AgentCalls,
		ErrorCategory:       w.ErrorCategory,
		ErrorSubcategory:    w.ErrorSubcategory,
		ErrorMessage:        w.ErrorMessage,
		Verdict:             w.Verdict,
		PrimaryCat:          w.PrimaryCat,
		PrimarySub:          w.PrimarySub,
		PrimarySignal:       w.PrimarySignal,
		SecondaryCat:        w.SecondaryCat,
		SecondarySub:        w.SecondarySub,
		BuildClassification: w.BuildClassification,
		BuildErrorsPresent:  w.BuildErrorsPresent,
	}, nil
}

// defaultStageRunner is the m12 stub StageRunner. It always returns
// success=true so the loop's outer-frame behavior can be asserted by the
// parity test harness without shelling back to bash. Future wedges (m13+)
// replace this with an exec into tekhton.sh --run-stages.
type defaultStageRunner struct {
	skip bool
}

func newDefaultStageRunner(skip bool) *defaultStageRunner {
	return &defaultStageRunner{skip: skip}
}

func (r *defaultStageRunner) RunStages(ctx context.Context, req *proto.AttemptRequestV1, attempt int) (orchestrate.StageOutcome, error) {
	if r.skip {
		return orchestrate.StageOutcome{
			Success:    true,
			AgentCalls: 0,
			TurnsUsed:  0,
		}, nil
	}
	// m12 ships the loop scaffold; the production stage runner lands in a
	// follow-up wedge (m13/m14) once the milestone-DAG and stage-runner
	// boundaries are themselves carved into Go. For now, RunStages returns
	// a sentinel that the bash shim recognizes and falls back on for stage
	// execution.
	return orchestrate.StageOutcome{
		Success:          false,
		ErrorCategory:    "PIPELINE",
		ErrorSubcategory: "stage_runner_not_wired",
		ErrorMessage:     "orchestrate run-attempt: stage runner not yet wired (m12 wedge ships the loop; stage execution remains in tekhton.sh until m13+)",
	}, nil
}
