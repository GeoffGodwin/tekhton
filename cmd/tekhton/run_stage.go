package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
	stagearchitect "github.com/geoffgodwin/tekhton/internal/stages/architect"
	stagecleanup "github.com/geoffgodwin/tekhton/internal/stages/cleanup"
	stagecoder "github.com/geoffgodwin/tekhton/internal/stages/coder"
	stagedocs "github.com/geoffgodwin/tekhton/internal/stages/docs"
	stageintake "github.com/geoffgodwin/tekhton/internal/stages/intake"
	stagereview "github.com/geoffgodwin/tekhton/internal/stages/review"
	stagesecurity "github.com/geoffgodwin/tekhton/internal/stages/security"
	stagetester "github.com/geoffgodwin/tekhton/internal/stages/tester"
	"github.com/geoffgodwin/tekhton/internal/stagerunner"
	"github.com/geoffgodwin/tekhton/internal/runner"
	"github.com/spf13/cobra"
)

// newRunStageCmd wires `tekhton run-stage <name>` — invokes a single stage
// via the BashAdapter and prints its stage.result.v1 envelope to stdout.
//
// Used for parity testing and one-off stage runs from the bash side. The
// per-attempt scheduler uses internal/pipeline.Runner directly.
func newRunStageCmd() *cobra.Command {
	var (
		requestFile string
		tekhtonHome string
		projectDir  string
	)
	c := &cobra.Command{
		Use:   "run-stage <name>",
		Short: "Run a single pipeline stage as a bash subprocess (m18).",
		Long: "Reads a tekhton.stage.request.v1 envelope from --request-file,\n" +
			"invokes the matching stages/<name>.sh, and prints the\n" +
			"resulting stage.result.v1 envelope to stdout.",
		Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			stage := args[0]
			if !proto.IsKnownStage(stage) {
				return errExitCode{code: exitUsage, err: fmt.Errorf("unknown stage: %s", stage)}
			}

			req, err := loadStageRequest(requestFile, stage)
			if err != nil {
				return errExitCode{code: exitUsage, err: err}
			}

			home := tekhtonHome
			if home == "" {
				home = os.Getenv("TEKHTON_HOME")
			}
			if home == "" {
				return errExitCode{code: exitUsage, err: fmt.Errorf("--tekhton-home or TEKHTON_HOME must be set")}
			}
			proj := projectDir
			if proj == "" {
				proj = os.Getenv("PROJECT_DIR")
			}
			if proj == "" {
				wd, _ := os.Getwd()
				proj = wd
			}

			// Wire per-stage providers into every Go-native stage package.
			// `tekhton run` does this through buildRunner; `tekhton run-stage`
			// is the parity/test entry point and must do the same or stages
			// that call provider.RunAgent crash with a nil-pointer panic.
			// PROVIDER_<STAGE>= env vars are honored per stage (m19).
			if err := setStageProviders(stage); err != nil {
				return errExitCode{code: exitUsage, err: err}
			}

			adapter := &stagerunner.BashAdapter{
				TekhtonHome: home,
				ProjectDir:  proj,
				LogWriter:   os.Stderr,
			}
			res, runErr := adapter.Run(context.Background(), req)
			// Always emit the envelope (even on subprocess error) so
			// callers can read the verdict.
			if res != nil {
				b, mErr := res.MarshalIndented()
				if mErr != nil {
					return mErr
				}
				fmt.Println(string(b))
			}
			return runErr
		},
	}
	c.Flags().StringVar(&requestFile, "request-file", "", "path to a tekhton.stage.request.v1 JSON file (required)")
	c.Flags().StringVar(&tekhtonHome, "tekhton-home", "", "tekhton repo root (defaults to $TEKHTON_HOME)")
	c.Flags().StringVar(&projectDir, "project-dir", "", "target project directory (defaults to $PROJECT_DIR or CWD)")
	return c
}

// loadStageRequest reads and validates a stage.request.v1 envelope from disk.
// Returns a synthetic minimal request when path is empty (so callers can run
// stages without a request file for smoke testing).
func loadStageRequest(path, stage string) (*proto.StageRequestV1, error) {
	if path == "" {
		// Synthesize a minimal request so the subcommand stays usable.
		return &proto.StageRequestV1{
			Proto:      proto.StageRequestProtoV1,
			Stage:      stage,
			Task:       os.Getenv("TEKHTON_TASK"),
			ResultFile: filepath.Join(os.TempDir(), fmt.Sprintf("tekhton-stage-%s.json", stage)),
		}, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read request file: %w", err)
	}
	req := &proto.StageRequestV1{}
	if err := json.Unmarshal(b, req); err != nil {
		return nil, fmt.Errorf("parse request file: %w", err)
	}
	if req.Stage == "" {
		req.Stage = stage
	}
	if req.Stage != stage {
		return nil, fmt.Errorf("request file stage %q does not match arg %q", req.Stage, stage)
	}
	if req.Proto == "" {
		req.Proto = proto.StageRequestProtoV1
	}
	if err := req.Validate(); err != nil {
		return nil, err
	}
	return req, nil
}

// setStageProviders resolves and injects the provider for each Go-native stage
// package using per-stage PROVIDER_<STAGE>= env overrides (m19). The single
// stage being run is resolved first; all others get the same resolution so
// that stages which delegate to sub-stages (e.g. tester → tdd) see a
// consistent provider.
func setStageProviders(primaryStage string) error {
	stageNames := []string{
		"intake", "cleanup", "docs", "security",
		"architect", "review", "tester", "coder",
	}
	for _, name := range stageNames {
		prov, err := runner.ResolveProvider(name)
		if err != nil {
			return fmt.Errorf("resolve provider for stage %q: %w", name, err)
		}
		setOneStageProvider(name, prov)
	}
	_ = primaryStage
	return nil
}

func setOneStageProvider(name string, prov provider.Provider) {
	switch name {
	case "intake":
		stageintake.SetProvider(prov)
	case "cleanup":
		stagecleanup.SetProvider(prov)
	case "docs":
		stagedocs.SetProvider(prov)
	case "security":
		stagesecurity.SetProvider(prov)
	case "architect":
		stagearchitect.SetProvider(prov)
	case "review":
		stagereview.SetProvider(prov)
	case "tester":
		stagetester.SetProvider(prov)
	case "coder":
		stagecoder.SetProvider(prov)
	}
}
