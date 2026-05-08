package main

import (
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/geoffgodwin/tekhton/internal/config"
	"github.com/spf13/cobra"
)

// newConfigCmd wires `tekhton config …` subcommands. The bash shim in
// lib/config.sh execs `config load --emit shell` and sources the output;
// operators reach `config show` and `config validate` directly.
//
// Exit codes:
//
//	0                — success
//	exitNotFound (1) — pipeline.conf missing
//	exitCorrupt  (2) — pipeline.conf parse error or required key missing
//	exitUsage   (64) — caller-side argument error
func newConfigCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "config",
		Short: "Tekhton pipeline.conf loader, validator, and emitter.",
	}
	c.AddCommand(newConfigLoadCmd(), newConfigShowCmd(), newConfigValidateCmd(), newConfigDefaultsCmd())
	return c
}

// configCommonFlags carries the flags shared by load/show/validate.
type configCommonFlags struct {
	path          string
	projectDir    string
	milestoneMode bool
	noWarn        bool
}

func bindCommon(cmd *cobra.Command, f *configCommonFlags) {
	cmd.Flags().StringVar(&f.path, "path", "", "Path to pipeline.conf (default: $PROJECT_DIR/.claude/pipeline.conf).")
	cmd.Flags().StringVar(&f.projectDir, "project-dir", "", "PROJECT_DIR for relative-path resolution. Defaults to $PROJECT_DIR or path's grandparent.")
	cmd.Flags().BoolVar(&f.milestoneMode, "milestone-mode", false, "Apply MILESTONE_* overrides on top of base config.")
	cmd.Flags().BoolVar(&f.noWarn, "no-warn", false, "Suppress validation/clamp warnings on stderr.")
}

func newConfigLoadCmd() *cobra.Command {
	var (
		f      configCommonFlags
		emit   string
		indent bool
	)
	c := &cobra.Command{
		Use:   "load",
		Short: "Load pipeline.conf and emit the resolved environment as shell or JSON.",
		Long: "Reads pipeline.conf, applies defaults, runs CI auto-detection, validates,\n" +
			"clamps, and resolves paths. Emits the resulting environment so the bash\n" +
			"shim in lib/config.sh can source it. Default --emit is shell.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := loadConfigForCmd(f)
			if err != nil {
				return err
			}
			if !f.noWarn {
				printDiagnostics(cmd.ErrOrStderr(), cfg)
			}
			switch emit {
			case "shell":
				return cfg.EmitShell(cmd.OutOrStdout())
			case "json":
				return cfg.EmitJSON(cmd.OutOrStdout(), indent)
			default:
				return errExitCode{code: exitUsage, err: fmt.Errorf("--emit must be shell|json (got %q)", emit)}
			}
		},
	}
	bindCommon(c, &f)
	c.Flags().StringVar(&emit, "emit", "shell", "Output format: shell | json.")
	c.Flags().BoolVar(&indent, "indent", false, "Pretty-print JSON output.")
	return c
}

func newConfigShowCmd() *cobra.Command {
	var (
		f      configCommonFlags
		indent bool
	)
	c := &cobra.Command{
		Use:   "show",
		Short: "Print the loaded config as JSON (alias for `config load --emit json --indent`).",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := loadConfigForCmd(f)
			if err != nil {
				return err
			}
			if !f.noWarn {
				printDiagnostics(cmd.ErrOrStderr(), cfg)
			}
			return cfg.EmitJSON(cmd.OutOrStdout(), indent)
		},
	}
	bindCommon(c, &f)
	c.Flags().BoolVar(&indent, "indent", true, "Pretty-print output.")
	return c
}

func newConfigValidateCmd() *cobra.Command {
	var (
		f      configCommonFlags
		strict bool
	)
	c := &cobra.Command{
		Use:   "validate",
		Short: "Validate pipeline.conf and exit nonzero on errors.",
		Long: "Loads pipeline.conf with the same loader as `config load`. With --strict,\n" +
			"warnings are promoted to errors so the command fails on any clamp,\n" +
			"reset-to-default, or unknown-value diagnostic.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := loadConfigForCmd(f)
			if err != nil {
				return err
			}
			printDiagnostics(cmd.ErrOrStderr(), cfg)
			if strict && len(cfg.Warnings) > 0 {
				return errExitCode{code: exitUsage, err: fmt.Errorf("config validate: %d warning(s) (strict mode)", len(cfg.Warnings))}
			}
			fmt.Fprintf(cmd.OutOrStdout(), "ok — %d keys, %d warnings\n",
				len(cfg.Values), len(cfg.Warnings))
			return nil
		},
	}
	bindCommon(c, &f)
	c.Flags().BoolVar(&strict, "strict", false, "Promote warnings to errors.")
	return c
}

// newConfigDefaultsCmd emits just the defaults (no pipeline.conf). Used by
// the lib/config_defaults.sh shim and by tests that need the bare defaults
// environment without any user overrides. Optionally takes --project-dir
// and --milestone-mode for context-sensitive defaults.
func newConfigDefaultsCmd() *cobra.Command {
	var (
		projectDir    string
		milestoneMode bool
		emit          string
	)
	c := &cobra.Command{
		Use:   "defaults",
		Short: "Emit the default environment without reading pipeline.conf.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg := &config.Config{
				ProjectDir: projectDir,
				Values:     map[string]string{},
				KeysSet:    map[string]bool{},
			}
			cfg.LoadDefaultsOnly(config.LoadOptions{
				ProjectDir:          projectDir,
				MilestoneMode:       milestoneMode,
				SuppressDiagnostics: true,
			})
			switch emit {
			case "shell":
				return cfg.EmitShell(cmd.OutOrStdout())
			case "json":
				return cfg.EmitJSON(cmd.OutOrStdout(), true)
			default:
				return errExitCode{code: exitUsage, err: fmt.Errorf("--emit must be shell|json (got %q)", emit)}
			}
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "PROJECT_DIR for relative-path resolution.")
	c.Flags().BoolVar(&milestoneMode, "milestone-mode", false, "Apply MILESTONE_* overrides.")
	c.Flags().StringVar(&emit, "emit", "shell", "Output format: shell | json.")
	return c
}

// loadConfigForCmd resolves common flags and invokes config.Load. Maps Go
// errors to the project's exit codes.
func loadConfigForCmd(f configCommonFlags) (*config.Config, error) {
	path := f.path
	if path == "" {
		pd := f.projectDir
		if pd == "" {
			pd = os.Getenv("PROJECT_DIR")
		}
		if pd == "" {
			return nil, errExitCode{code: exitUsage, err: errors.New("config: --path or $PROJECT_DIR required")}
		}
		path = pd + "/.claude/pipeline.conf"
	}
	projectDir := f.projectDir
	if projectDir == "" {
		projectDir = os.Getenv("PROJECT_DIR")
	}

	cfg, err := config.Load(path, config.LoadOptions{
		ProjectDir:    projectDir,
		MilestoneMode: f.milestoneMode,
	})
	if err != nil {
		switch {
		case errors.Is(err, config.ErrNotFound):
			return nil, errExitCode{code: exitNotFound, err: err}
		case errors.Is(err, config.ErrParse), errors.Is(err, config.ErrMissingRequired):
			return nil, errExitCode{code: exitCorrupt, err: err}
		default:
			return nil, err
		}
	}
	return cfg, nil
}

// printDiagnostics writes accumulated warnings to stderr — one per line,
// matching the bash side's `warn()` formatting (no color codes — those would
// corrupt the parity check).
func printDiagnostics(w io.Writer, cfg *config.Config) {
	for _, line := range cfg.Warnings {
		fmt.Fprintln(w, line)
	}
}
