package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/geoffgodwin/tekhton/internal/gates"
	"github.com/spf13/cobra"
)

// newGateCmd wires `tekhton gate` — an internal developer subcommand
// surface that lib/gates*.sh delegated to after m31.1's port. The parent
// command is Hidden so end users browsing `tekhton --help` don't see it
// (gates are an internal seam, invoked transitively by `tekhton run` and
// the legacy bash compatibility shim). Once the user descends to
// `tekhton gate --help`, the three subcommands ARE visible — the m31.1
// acceptance criterion required that listing.
//
// Three subcommands:
//   - `tekhton gate build --stage-label <label>` — runs the five-phase
//     build gate (analyze + compile + constraints + ui_test +
//     ui_validation). Exits 0 on pass, 1 on fail.
//   - `tekhton gate completion` — runs the completion gate (coder
//     self-report verification + TEST_CMD). Exits 0 on pass, 1 on fail.
//   - `tekhton gate ui` — stub; m31.2 will fill in. Exits 64 (EX_USAGE)
//     with a descriptive message so callers can distinguish "not
//     implemented" from a real gate failure.
func newGateCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "gate",
		Short:  "Run a build-pipeline gate (internal — developer tool)",
		Hidden: true,
	}
	c.AddCommand(newGateBuildCmd())
	c.AddCommand(newGateCompletionCmd())
	c.AddCommand(newGateUICmd())
	return c
}

// newGateBuildCmd registers `tekhton gate build`.
func newGateBuildCmd() *cobra.Command {
	var stageLabel string
	c := &cobra.Command{
		Use:   "build",
		Short: "Run the build gate (analyze + compile + constraints + ui_test + ui_validation)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if stageLabel == "" {
				stageLabel = "unknown"
			}
			ctx := context.Background()
			g := buildGateFromEnv(stageLabel)
			err := g.Run(ctx, stageLabel)
			if err == nil {
				return nil
			}
			fmt.Fprintln(cmd.ErrOrStderr(), "tekhton gate build:", err)
			return errExitCode{code: 1, err: err}
		},
	}
	c.Flags().StringVar(&stageLabel, "stage-label", "", "human-readable stage label written into BUILD_ERRORS.md")
	return c
}

// newGateCompletionCmd registers `tekhton gate completion`.
func newGateCompletionCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "completion",
		Short: "Run the completion gate (coder self-report verification + TEST_CMD)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := context.Background()
			g := completionGateFromEnv()
			g.Logger = func(format string, args ...interface{}) {
				fmt.Fprintln(cmd.ErrOrStderr(), "Warning: "+fmt.Sprintf(format, args...))
			}
			err := g.Run(ctx)
			if err == nil {
				return nil
			}
			fmt.Fprintln(cmd.ErrOrStderr(), "tekhton gate completion:", err)
			return errExitCode{code: 1, err: err}
		},
	}
	return c
}

// newGateUICmd registers `tekhton gate ui` — m31.2 stub.
func newGateUICmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "ui",
		Short: "Run the UI test gate (stub — implemented in m31.2)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return errExitCode{
				code: exitUsage,
				err:  errors.New("gate ui: implemented in m31.2"),
			}
		},
	}
	return c
}

// buildGateFromEnv assembles a BuildGate using the env contract m26
// populated. Each phase reads its own env keys; missing keys reduce to
// StatusSkip via empty-string defaults.
func buildGateFromEnv(stageLabel string) *gates.BuildGate {
	timeout := envSeconds("BUILD_GATE_TIMEOUT", 600)
	analyzeTO := envSeconds("BUILD_GATE_ANALYZE_TIMEOUT", 300)
	compileTO := envSeconds("BUILD_GATE_COMPILE_TIMEOUT", 120)
	constraintTO := envSeconds("BUILD_GATE_CONSTRAINT_TIMEOUT", 60)
	tekhtonDir := envOr("TEKHTON_DIR", ".tekhton")
	projectDir := os.Getenv("PROJECT_DIR")
	errsFile := resolveUnder(projectDir, envOr("BUILD_ERRORS_FILE", filepath.Join(tekhtonDir, "BUILD_ERRORS.md")))
	rawFile := resolveUnder(projectDir, envOr("BUILD_RAW_ERRORS_FILE", filepath.Join(tekhtonDir, "BUILD_RAW_ERRORS.txt")))
	uiTestErrs := resolveUnder(projectDir, envOr("UI_TEST_ERRORS_FILE", filepath.Join(tekhtonDir, "UI_TEST_ERRORS.md")))

	writer := &gates.FSErrorsWriter{
		ErrorsFile:       errsFile,
		RawErrorsFile:    rawFile,
		UITestErrorsFile: uiTestErrs,
	}
	runner := gates.ExecRunner{}
	rem := &gates.BashRemediator{TekhtonHome: os.Getenv("TEKHTON_HOME")}

	validationCmd := readValidationCmd(os.Getenv("DEPENDENCY_CONSTRAINTS_FILE"))

	factories := map[string]func() gates.Phase{
		"analyze": func() gates.Phase {
			return &gates.AnalyzePhase{
				Cmd:          os.Getenv("ANALYZE_CMD"),
				ErrorPattern: envOr("ANALYZE_ERROR_PATTERN", "error"),
				Timeout:      analyzeTO,
				Runner:       runner,
				Remediator:   rem,
				Errors:       writer,
			}
		},
		"compile": func() gates.Phase {
			return &gates.CompilePhase{
				Cmd:          os.Getenv("BUILD_CHECK_CMD"),
				ErrorPattern: envOr("BUILD_ERROR_PATTERN", "ERROR"),
				Timeout:      compileTO,
				Runner:       runner,
				Remediator:   rem,
				Errors:       writer,
			}
		},
		"constraints": func() gates.Phase {
			return &gates.ConstraintsPhase{
				ValidationCmd: validationCmd,
				Timeout:       constraintTO,
				Runner:        runner,
				Errors:        writer,
			}
		},
		"ui_test": func() gates.Phase {
			uiCmd := os.Getenv("UI_TEST_CMD")
			if uiCmd == "" {
				return &gates.UIBashShim{} // Skip
			}
			return &gates.UIBashShim{
				UITestCmd:  uiCmd,
				BashRunner: newUIBashRunner(stageLabel),
			}
		},
		"ui_validation": func() gates.Phase {
			// m31.2: native validation. m31.1 always skips.
			return &gates.UIValidationPhase{}
		},
	}
	return gates.NewBuildGate(factories, gates.BuildGateOptions{
		Timeout: timeout,
		Errors:  writer,
	})
}

// completionGateFromEnv assembles a CompletionGate from the env contract.
func completionGateFromEnv() *gates.CompletionGate {
	tekhtonDir := envOr("TEKHTON_DIR", ".tekhton")
	projectDir := os.Getenv("PROJECT_DIR")
	dump := resolveUnder(projectDir, filepath.Join(tekhtonDir, "COMPLETION_GATE_LAST_FAILURE.log"))
	summary := resolveUnder(projectDir, envOr("CODER_SUMMARY_FILE", filepath.Join(tekhtonDir, "CODER_SUMMARY.md")))
	g := &gates.CompletionGate{
		SummaryFile:       summary,
		TestCmd:           os.Getenv("TEST_CMD"),
		TestEnabled:       envBool("COMPLETION_GATE_TEST_ENABLED", true),
		PassOnPreexisting: envBool("TEST_BASELINE_PASS_ON_PREEXISTING", false),
		Runner:            gates.ExecRunner{},
		DumpPath:          dump,
		Milestone:         os.Getenv("_CURRENT_MILESTONE"),
	}
	if cwd, err := os.Getwd(); err == nil {
		g.Cwd = cwd
	}
	return g
}

// resolveUnder joins a relative path under projectDir. Absolute paths
// are returned unchanged. Empty projectDir leaves the path unchanged
// (the bash gate also tolerated unset PROJECT_DIR).
func resolveUnder(projectDir, path string) string {
	if path == "" || filepath.IsAbs(path) || projectDir == "" {
		return path
	}
	return filepath.Join(projectDir, path)
}

// envOr returns os.Getenv(key) when non-empty, fallback otherwise.
func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envSeconds parses an integer-seconds env value, returning a Duration.
// Empty or unparseable values return fallback seconds.
func envSeconds(key string, fallback int) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return time.Duration(fallback) * time.Second
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return time.Duration(fallback) * time.Second
	}
	return time.Duration(n) * time.Second
}

// envBool parses a tri-state ("true"/"false"/anything else) env value.
// Defaults match the bash pipeline.conf convention of [[ "$v" == "true" ]].
func envBool(key string, fallback bool) bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv(key)))
	switch v {
	case "":
		return fallback
	case "true", "1", "yes":
		return true
	}
	return false
}

// readValidationCmd extracts the `validation_command:` value from a
// dependency constraints manifest. Empty path or missing file returns "".
// Mirrors the bash `grep ... | sed ... | tr -d '"'` pipeline.
func readValidationCmd(path string) string {
	if path == "" {
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		if !strings.HasPrefix(line, "validation_command:") {
			continue
		}
		v := strings.TrimPrefix(line, "validation_command:")
		v = strings.TrimSpace(v)
		v = strings.Trim(v, `"'`)
		return v
	}
	return ""
}
