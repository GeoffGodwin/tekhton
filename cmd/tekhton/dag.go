package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/dag"
	"github.com/geoffgodwin/tekhton/internal/manifest"
	"github.com/spf13/cobra"
)

// newDagCmd wires `tekhton dag …` subcommands. The bash shim in
// lib/milestone_dag.sh execs these for state-machine operations
// (frontier/active/advance/validate) and one-shot tasks (migrate, rewrite-
// pointer). All commands respect $MILESTONE_MANIFEST_FILE / $MILESTONE_DIR
// for path resolution, with --path / --milestone-dir overrides.
func newDagCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "dag",
		Short: "Milestone DAG state machine — frontier, active, advance, validate, migrate.",
	}
	c.AddCommand(
		newDagFrontierCmd(),
		newDagActiveCmd(),
		newDagAdvanceCmd(),
		newDagValidateCmd(),
		newDagMigrateCmd(),
		newDagRewritePointerCmd(),
	)
	return c
}

func newDagFrontierCmd() *cobra.Command {
	var path string
	c := &cobra.Command{
		Use:   "frontier",
		Short: "Print IDs of milestones that are ready to run.",
		Long: "A milestone is on the frontier when its status is actionable " +
			"(not done, not split) and all of its dependencies have status=done.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := loadDagState(path)
			if err != nil {
				return err
			}
			for _, e := range s.Frontier() {
				fmt.Println(e.ID)
			}
			return nil
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $MILESTONE_MANIFEST_FILE.")
	return c
}

func newDagActiveCmd() *cobra.Command {
	var path string
	c := &cobra.Command{
		Use:   "active",
		Short: "Print IDs of milestones with status=in_progress.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := loadDagState(path)
			if err != nil {
				return err
			}
			for _, e := range s.Active() {
				fmt.Println(e.ID)
			}
			return nil
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $MILESTONE_MANIFEST_FILE.")
	return c
}

func newDagAdvanceCmd() *cobra.Command {
	var path string
	c := &cobra.Command{
		Use:   "advance <id> <status>",
		Short: "Apply a status transition to one milestone, atomically.",
		Long: "Validates the transition against the m14 transition table:\n" +
			"  pending|todo → in_progress | skipped\n" +
			"  in_progress  → done | skipped | split | todo | pending\n" +
			"  done|skipped|split → terminal (only same-status idempotent updates)\n",
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := loadDagState(path)
			if err != nil {
				return err
			}
			if err := s.Advance(args[0], args[1]); err != nil {
				return mapDagError(err)
			}
			return s.Manifest().Save()
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $MILESTONE_MANIFEST_FILE.")
	return c
}

func newDagValidateCmd() *cobra.Command {
	var (
		path         string
		milestoneDir string
	)
	c := &cobra.Command{
		Use:   "validate",
		Short: "Validate manifest: cycles, missing deps, unknown statuses, missing files.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := loadDagState(path)
			if err != nil {
				return err
			}
			if milestoneDir == "" && path != "" {
				milestoneDir = filepath.Dir(path)
			}
			vErrs := s.Validate(milestoneDir)
			for _, e := range vErrs {
				fmt.Fprintln(os.Stderr, e.Msg)
			}
			if len(vErrs) > 0 {
				return errExitCode{code: exitCorrupt, err: fmt.Errorf("%d validation error(s)", len(vErrs))}
			}
			return nil
		},
	}
	c.Flags().StringVar(&path, "path", "", "Override $MILESTONE_MANIFEST_FILE.")
	c.Flags().StringVar(&milestoneDir, "milestone-dir", "",
		"Directory containing milestone files (defaults to dirname of --path).")
	return c
}

func newDagMigrateCmd() *cobra.Command {
	var (
		claudeMD     string
		milestoneDir string
		manifestName string
		writePointer bool
	)
	c := &cobra.Command{
		Use:   "migrate",
		Short: "Extract inline milestones from CLAUDE.md into the DAG file format.",
		Long: "Walks CLAUDE.md, writes one milestone-per-file plus a fresh " +
			"MANIFEST.cfg. Idempotent: if MANIFEST.cfg already exists, the " +
			"command exits 0 with no changes.\n\n" +
			"Future tekhton releases may run this on first invocation, but " +
			"today it's a manual operation.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if claudeMD == "" {
				claudeMD = "CLAUDE.md"
			}
			if milestoneDir == "" {
				if env := os.Getenv("MILESTONE_DIR"); env != "" {
					milestoneDir = env
				} else {
					milestoneDir = ".claude/milestones"
				}
			}
			n, err := dag.Migrate(dag.MigrateOptions{
				ClaudeMD:     claudeMD,
				MilestoneDir: milestoneDir,
				ManifestName: manifestName,
			})
			if errors.Is(err, dag.ErrMigrateAlreadyDone) {
				fmt.Fprintf(os.Stderr,
					"manifest already exists at %s — skipping migration\n",
					filepath.Join(milestoneDir, defaultManifestName(manifestName)))
				return nil
			}
			if err != nil {
				return err
			}
			fmt.Fprintf(os.Stderr, "Migrated %d milestone(s) to %s\n", n, milestoneDir)
			if writePointer {
				if err := dag.RewritePointer(claudeMD); err != nil {
					return err
				}
			}
			return nil
		},
	}
	c.Flags().StringVar(&claudeMD, "inline-claude-md", "",
		"Source CLAUDE.md (defaults to ./CLAUDE.md).")
	c.Flags().StringVar(&milestoneDir, "milestone-dir", "",
		"Destination directory (defaults to $MILESTONE_DIR or .claude/milestones).")
	c.Flags().StringVar(&manifestName, "manifest-name", "",
		"Override the manifest filename (default MANIFEST.cfg).")
	c.Flags().BoolVar(&writePointer, "rewrite-pointer", false,
		"After migration, rewrite CLAUDE.md milestone blocks as a pointer comment.")
	return c
}

func newDagRewritePointerCmd() *cobra.Command {
	var claudeMD string
	c := &cobra.Command{
		Use:   "rewrite-pointer",
		Short: "Replace inline milestone blocks in CLAUDE.md with a pointer comment.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if claudeMD == "" {
				claudeMD = "CLAUDE.md"
			}
			return dag.RewritePointer(claudeMD)
		},
	}
	c.Flags().StringVar(&claudeMD, "inline-claude-md", "",
		"Source CLAUDE.md (defaults to ./CLAUDE.md).")
	return c
}

// loadDagState resolves the manifest path (--path > $MILESTONE_MANIFEST_FILE)
// and loads it into a dag.State. The not-found / empty / corrupt error mapping
// matches the manifest CLI.
func loadDagState(path string) (*dag.State, error) {
	path = resolveManifestPath(path)
	if path == "" {
		return nil, fmt.Errorf("dag: --path or $MILESTONE_MANIFEST_FILE required")
	}
	m, err := manifest.Load(path)
	if err != nil {
		return nil, mapManifestError(err)
	}
	return dag.New(m), nil
}

// mapDagError translates dag sentinels into typed exit codes for the CLI.
func mapDagError(err error) error {
	switch {
	case errors.Is(err, dag.ErrNotFound):
		return errExitCode{code: exitNotFound, err: err}
	case errors.Is(err, dag.ErrUnknownStatus), errors.Is(err, dag.ErrInvalidTransition):
		return errExitCode{code: exitUsage, err: err}
	default:
		return err
	}
}

// defaultManifestName mirrors dag.Migrate's internal default — used only for
// the "already exists" log line when the user provided no --manifest-name.
func defaultManifestName(override string) string {
	if override != "" {
		return override
	}
	return "MANIFEST.cfg"
}
