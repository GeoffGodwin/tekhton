package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/pipeline"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/stagerunner"
	"github.com/spf13/cobra"
)

// newPipelineCmd wires `tekhton pipeline …` subcommands. m18's primary entry
// is `pipeline run-attempt`, the per-attempt scheduler that replaces
// _run_pipeline_stages in lib/orchestrate_iteration.sh.
func newPipelineCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "pipeline",
		Short: "Per-attempt pipeline scheduler (m18).",
	}
	c.AddCommand(newPipelineRunAttemptCmd())
	return c
}

func newPipelineRunAttemptCmd() *cobra.Command {
	var (
		requestFile string
		tekhtonHome string
		projectDir  string
		analyzeCmd  string
		compileCmd  string
		testCmd     string
		resultDir   string
		logDir      string
	)
	c := &cobra.Command{
		Use:   "run-attempt",
		Short: "Run one pipeline attempt and print a tekhton.pipeline.attempt.result.v1 envelope.",
		Long: "Reads a tekhton.pipeline.attempt.request.v1 envelope from --request-file,\n" +
			"schedules each stage in Order via the bash stage adapter, applies\n" +
			"build- and completion-gate policies, and prints the result envelope.\n" +
			"\n" +
			"Note: m18 ports the gate policy to Go but the build-fix continuation\n" +
			"loop (M128) inside coder.sh stays bash.",
		RunE: func(_ *cobra.Command, _ []string) error {
			req, err := loadPipelineRequest(requestFile)
			if err != nil {
				return errExitCode{code: exitUsage, err: err}
			}

			home := tekhtonHome
			if home == "" {
				home = os.Getenv("TEKHTON_HOME")
			}
			if home == "" {
				return errExitCode{code: exitUsage, err: fmt.Errorf("--tekhton-home or TEKHTON_HOME required")}
			}
			proj := projectDir
			if proj == "" {
				proj = req.ProjectDir
			}

			adapter := &stagerunner.BashAdapter{
				TekhtonHome: home,
				ProjectDir:  proj,
				LogWriter:   os.Stderr,
				TekhtonBin:  resolveTekhtonBin(),
			}

			opts := pipeline.Options{ResultDir: resultDir, LogDir: logDir}
			if analyzeCmd != "" || compileCmd != "" {
				opts.Gate = &pipeline.BuildGate{
					AnalyzeCmd: analyzeCmd,
					CompileCmd: compileCmd,
				}
			}
			if testCmd != "" {
				opts.CompletionGate = &pipeline.CompletionGate{TestCmd: testCmd}
			}

			r, err := pipeline.New(adapter, opts)
			if err != nil {
				return err
			}
			res, err := r.RunAttempt(context.Background(), req)
			if res != nil {
				b, mErr := res.MarshalIndented()
				if mErr != nil {
					return mErr
				}
				fmt.Println(string(b))
			}
			return err
		},
	}
	c.Flags().StringVar(&requestFile, "request-file", "", "path to a tekhton.pipeline.attempt.request.v1 JSON file (required)")
	c.Flags().StringVar(&tekhtonHome, "tekhton-home", "", "tekhton repo root (defaults to $TEKHTON_HOME)")
	c.Flags().StringVar(&projectDir, "project-dir", "", "target project directory (defaults to request.project_dir)")
	c.Flags().StringVar(&analyzeCmd, "analyze-cmd", "", "build-gate analyze command (default: skip)")
	c.Flags().StringVar(&compileCmd, "compile-cmd", "", "build-gate compile command (default: skip)")
	c.Flags().StringVar(&testCmd, "test-cmd", "", "completion-gate test command (default: skip)")
	c.Flags().StringVar(&resultDir, "result-dir", "", "directory for per-stage result files")
	c.Flags().StringVar(&logDir, "log-dir", "", "directory for per-stage log files")
	return c
}

// resolveTekhtonBin returns the path the bash subprocess should use to call
// back into this binary via $TEKHTON_BIN. Honors an explicit override via
// the env, then falls back to os.Args[0] resolved to an absolute path.
func resolveTekhtonBin() string {
	if v := os.Getenv("TEKHTON_BIN"); v != "" {
		return v
	}
	if len(os.Args) > 0 {
		if abs, err := filepath.Abs(os.Args[0]); err == nil {
			return abs
		}
		return os.Args[0]
	}
	return "tekhton"
}

func loadPipelineRequest(path string) (*proto.PipelineAttemptRequestV1, error) {
	if path == "" {
		return nil, fmt.Errorf("--request-file is required")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read request file: %w", err)
	}
	req := &proto.PipelineAttemptRequestV1{}
	if err := json.Unmarshal(b, req); err != nil {
		return nil, fmt.Errorf("parse request file: %w", err)
	}
	if req.Proto == "" {
		req.Proto = proto.PipelineAttemptRequestProtoV1
	}
	if err := req.Validate(); err != nil {
		return nil, err
	}
	return req, nil
}
