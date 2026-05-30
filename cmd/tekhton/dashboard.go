package main

import (
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/dashboard"
	"github.com/spf13/cobra"
)

// newDashboardCmd wires the `tekhton dashboard` parent command and its
// init / sync / cleanup / emit sub-arms. Hidden because end users only
// see dashboard transitively via `tekhton run` (or via the bash hooks
// that rewire to these subcommands).
func newDashboardCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "dashboard",
		Short:  "Watchtower dashboard data emit (internal — developer tool)",
		Long:   "Internal subcommand owning the Watchtower dashboard data layer.",
		Hidden: true,
	}
	c.AddCommand(newDashboardInitCmd())
	c.AddCommand(newDashboardSyncCmd())
	c.AddCommand(newDashboardCleanupCmd())
	c.AddCommand(newDashboardEmitCmd())
	c.AddCommand(newDashboardParseCmd())
	return c
}

func newDashboardInitCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "init",
		Short: "Create .claude/dashboard/ + seed data/ files",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if projectDir == "" {
				projectDir, _ = os.Getwd()
			}
			templatesDir := dashboardTemplatesDir()
			return dashboard.Init(projectDir, dashDirEnv(), templatesDir)
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	return c
}

func newDashboardSyncCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "sync",
		Short: "Re-copy static UI files into existing dashboard dir",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if projectDir == "" {
				projectDir, _ = os.Getwd()
			}
			return dashboard.SyncStaticFiles(projectDir, dashDirEnv(), dashboardTemplatesDir())
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	return c
}

func newDashboardCleanupCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "cleanup",
		Short: "Remove .claude/dashboard/ tree",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if projectDir == "" {
				projectDir, _ = os.Getwd()
			}
			return dashboard.Cleanup(projectDir, dashDirEnv())
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	return c
}

// newDashboardEmitCmd builds the `tekhton dashboard emit` parent and its
// 10 emit-kind sub-subcommands. Each sub-subcommand constructs an Emitter
// and invokes the matching method.
func newDashboardEmitCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "emit",
		Short: "Re-emit one Watchtower data file",
		Long:  "Re-generates one of the data/*.js files from current process state + env vars.",
	}
	for _, k := range emitKinds {
		c.AddCommand(newDashboardEmitKindCmd(k))
	}
	return c
}

// emitKind binds a sub-subcommand name to the Emitter method it invokes.
type emitKind struct {
	name string
	fn   func(*dashboard.Emitter) error
}

var emitKinds = []emitKind{
	{"run-state", (*dashboard.Emitter).EmitRunState},
	{"timeline", (*dashboard.Emitter).EmitTimeline},
	{"milestones", (*dashboard.Emitter).EmitMilestones},
	{"security", (*dashboard.Emitter).EmitSecurity},
	{"reports", (*dashboard.Emitter).EmitReports},
	{"metrics", (*dashboard.Emitter).EmitMetrics},
	{"health", (*dashboard.Emitter).EmitHealth},
	{"diagnosis", (*dashboard.Emitter).EmitDiagnosis},
	{"init", (*dashboard.Emitter).EmitInit},
	{"inbox", (*dashboard.Emitter).EmitInbox},
	{"action-items", (*dashboard.Emitter).EmitActionItems},
	{"notes", (*dashboard.Emitter).EmitNotes},
	{"draft-milestones", (*dashboard.Emitter).EmitDraftMilestones},
}

func newDashboardEmitKindCmd(k emitKind) *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   k.name,
		Short: fmt.Sprintf("Emit data/%s.js", emitKindFileBase(k.name)),
		RunE: func(cmd *cobra.Command, _ []string) error {
			if projectDir == "" {
				projectDir, _ = os.Getwd()
			}
			e := dashboard.NewEmitter(projectDir)
			if err := k.fn(e); err != nil {
				return fmt.Errorf("dashboard emit %s: %w", k.name, err)
			}
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	return c
}

// emitKindFileBase maps a sub-subcommand name to the on-disk file's base
// name. Most match directly; the action-items / draft-milestones ones
// translate dashes to underscores.
func emitKindFileBase(name string) string {
	switch name {
	case "run-state":
		return "run_state"
	case "action-items":
		return "action_items"
	case "draft-milestones":
		return "draft_milestones"
	default:
		return name
	}
}

func dashDirEnv() string {
	if v := os.Getenv("DASHBOARD_DIR"); v != "" {
		return v
	}
	return ".claude/dashboard"
}

func dashboardTemplatesDir() string {
	if v := os.Getenv("TEKHTON_HOME"); v != "" {
		return v + "/templates/watchtower"
	}
	return ""
}
