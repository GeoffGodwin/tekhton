package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/drift"
	"github.com/spf13/cobra"
)

// newDriftCmd wires `tekhton drift ...` subcommands. Hidden — these
// are internal seams during the m25 migration, not user-facing
// utilities. The bash callers that used to source lib/drift*.sh
// reach Go through these subcommands or by importing internal/drift
// from another Go binary.
func newDriftCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "drift",
		Short:  "Drift log management (m25 internal seam)",
		Hidden: true,
	}
	c.AddCommand(newDriftObserveCmd())
	c.AddCommand(newDriftResolveCmd())
	c.AddCommand(newDriftListCmd())
	c.AddCommand(newDriftPruneCmd())
	c.AddCommand(newDriftAuditStatusCmd())
	c.AddCommand(newDriftCountCmd())
	c.AddCommand(newDriftEntriesCmd())
	c.AddCommand(newDriftResolveAllCmd())
	c.AddCommand(newDriftResetAuditCmd())
	c.AddCommand(newDriftHumanActionCmd())
	c.AddCommand(newDriftNonblockingCmd())
	return c
}

// nonBlockingPath resolves NON_BLOCKING_LOG.md the same way driftLogPath
// resolves DRIFT_LOG.md: --project-dir or cwd, optional NON_BLOCKING_LOG_FILE
// override. Matches the bash artifact_defaults.sh:25 convention so callers
// see identical resolution regardless of which side answers.
func nonBlockingPath(projectDir string) string {
	if projectDir == "" {
		projectDir, _ = os.Getwd()
	}
	override := os.Getenv("NON_BLOCKING_LOG_FILE")
	if override == "" {
		override = filepath.Join(".tekhton", "NON_BLOCKING_LOG.md")
	}
	if filepath.IsAbs(override) {
		return override
	}
	return filepath.Join(projectDir, override)
}

// newDriftNonblockingCmd groups subcommands that drive the
// internal/drift/nonblocking.go file. Today only `count` is exposed
// (it's the load-bearing callsite the bash port lost track of when m25
// deleted lib/drift_cleanup.sh); other operations on NON_BLOCKING_LOG.md
// happen through the in-process Go callers (finalize hooks, reviewer
// stage) and don't need a CLI shim.
func newDriftNonblockingCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "nonblocking",
		Short: "Manage NON_BLOCKING_LOG.md (count)",
	}
	c.AddCommand(newDriftNonblockingCountCmd())
	return c
}

func newDriftNonblockingCountCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "count",
		Short: "Print the count of open `- [ ]` non-blocking notes",
		RunE: func(cmd *cobra.Command, _ []string) error {
			n := drift.NewNonBlocking(nonBlockingPath(projectDir))
			c, err := n.CountOpen()
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%d\n", c)
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	return c
}

// driftLogPath resolves DRIFT_LOG.md given the supplied --project-dir
// flag (or cwd) and an optional override via $DRIFT_LOG_FILE. Matches
// the bash convention.
func driftLogPath(projectDir string) string {
	if projectDir == "" {
		projectDir, _ = os.Getwd()
	}
	override := os.Getenv("DRIFT_LOG_FILE")
	if override == "" {
		override = "DRIFT_LOG.md"
	}
	if filepath.IsAbs(override) {
		return override
	}
	return filepath.Join(projectDir, override)
}

func newDriftObserveCmd() *cobra.Command {
	var (
		projectDir string
		tag        string
		detail     string
	)
	c := &cobra.Command{
		Use:   "observe",
		Short: "Append a drift observation to DRIFT_LOG.md",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if detail == "" {
				return errExitCode{code: exitUsage, err: fmt.Errorf("--detail is required")}
			}
			task := tag
			if task == "" {
				task = "cli"
			}
			l := drift.NewLog(driftLogPath(projectDir))
			return l.AppendObservations(task, "- "+detail)
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().StringVar(&tag, "tag", "", "task tag recorded with the observation")
	c.Flags().StringVar(&detail, "detail", "", "observation body")
	return c
}

func newDriftResolveCmd() *cobra.Command {
	var (
		projectDir string
		all        bool
	)
	c := &cobra.Command{
		Use:   "resolve [PATTERN ...]",
		Short: "Move matching unresolved observations to ## Resolved",
		RunE: func(cmd *cobra.Command, args []string) error {
			l := drift.NewLog(driftLogPath(projectDir))
			if all {
				return l.ResolveAllObservations()
			}
			if len(args) == 0 {
				return errExitCode{code: exitUsage, err: fmt.Errorf("at least one PATTERN required (or --all)")}
			}
			return l.ResolveObservations(args)
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().BoolVar(&all, "all", false, "resolve every unresolved entry")
	return c
}

func newDriftListCmd() *cobra.Command {
	var (
		projectDir string
		state      string
		format     string
	)
	c := &cobra.Command{
		Use:   "list",
		Short: "List drift observations",
		RunE: func(cmd *cobra.Command, _ []string) error {
			l := drift.NewLog(driftLogPath(projectDir))
			var entries []string
			switch state {
			case "resolved":
				e, err := l.GetResolved()
				if err != nil {
					return err
				}
				entries = e
			case "open", "":
				// open == unresolved.
				body, err := os.ReadFile(l.Path)
				if err != nil {
					if os.IsNotExist(err) {
						return nil
					}
					return err
				}
				entries = collectUnresolved(string(body))
			default:
				return errExitCode{code: exitUsage,
					err: fmt.Errorf("unknown --state %q (open|resolved)", state)}
			}
			switch format {
			case "json":
				enc := json.NewEncoder(cmd.OutOrStdout())
				enc.SetIndent("", "  ")
				return enc.Encode(map[string]any{
					"state":   stateLabel(state),
					"entries": entries,
				})
			case "md", "":
				for _, e := range entries {
					fmt.Fprintln(cmd.OutOrStdout(), e)
				}
				return nil
			default:
				return errExitCode{code: exitUsage,
					err: fmt.Errorf("unknown --format %q (md|json)", format)}
			}
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().StringVar(&state, "state", "open", "filter by state (open|resolved)")
	c.Flags().StringVar(&format, "format", "md", "output format (md|json)")
	return c
}

func stateLabel(s string) string {
	if s == "" {
		return "open"
	}
	return s
}

// collectUnresolved walks the markdown body and returns every
// unresolved-section bullet entry.
func collectUnresolved(body string) []string {
	var out []string
	in := false
	for _, line := range splitLines(body) {
		if hasPrefix(line, "## Unresolved Observations") {
			in = true
			continue
		}
		if in && hasPrefix(line, "## ") && !hasPrefix(line, "### ") {
			break
		}
		if in && hasPrefix(line, "- [") {
			out = append(out, line)
		}
	}
	return out
}

// hasPrefix is a tiny local helper so we don't add an import for a
// single strings.HasPrefix call.
func hasPrefix(s, p string) bool { return len(s) >= len(p) && s[:len(p)] == p }

// splitLines splits on "\n" without trailing-newline weirdness.
func splitLines(s string) []string {
	out := []string{""}
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			out = append(out, "")
			continue
		}
		out[len(out)-1] += string(s[i])
	}
	return out
}

func newDriftPruneCmd() *cobra.Command {
	var (
		projectDir  string
		maxResolved int
		archivePath string
	)
	c := &cobra.Command{
		Use:   "prune",
		Short: "Archive old resolved entries past --max-resolved",
		RunE: func(cmd *cobra.Command, _ []string) error {
			l := drift.NewLog(driftLogPath(projectDir))
			if archivePath == "" {
				archivePath = filepath.Join(filepath.Dir(l.Path), "DRIFT_ARCHIVE.md")
			}
			pruned, err := l.Prune(drift.PruneOptions{
				KeepCount:   maxResolved,
				ArchivePath: archivePath,
			})
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "pruned %d entry(ies)\n", pruned)
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().IntVar(&maxResolved, "max-resolved", 20, "max resolved entries to retain")
	c.Flags().StringVar(&archivePath, "archive", "", "archive file path (defaults to DRIFT_ARCHIVE.md alongside the log)")
	return c
}

func newDriftCountCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "count",
		Short: "Print the count of unresolved observations",
		RunE: func(cmd *cobra.Command, _ []string) error {
			l := drift.NewLog(driftLogPath(projectDir))
			n, err := l.CountUnresolved()
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%d\n", n)
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	return c
}

func newDriftEntriesCmd() *cobra.Command {
	var (
		projectDir string
		entries    []string
	)
	c := &cobra.Command{
		Use:   "entries",
		Short: "Append raw text entries to unresolved (architect re-add)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if len(entries) == 0 {
				return errExitCode{code: exitUsage, err: fmt.Errorf("--entry required at least once")}
			}
			l := drift.NewLog(driftLogPath(projectDir))
			return l.AppendEntries(entries)
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().StringSliceVar(&entries, "entry", nil, "entry body (repeatable)")
	return c
}

func newDriftResolveAllCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "resolve-all",
		Short: "Move every unresolved observation to ## Resolved",
		RunE: func(cmd *cobra.Command, _ []string) error {
			l := drift.NewLog(driftLogPath(projectDir))
			return l.ResolveAllObservations()
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	return c
}

func newDriftResetAuditCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "reset-audit",
		Short: "Reset runs-since-audit counter and stamp last audit date",
		RunE: func(cmd *cobra.Command, _ []string) error {
			l := drift.NewLog(driftLogPath(projectDir))
			if err := l.ResetRunsSinceAudit(); err != nil {
				return err
			}
			archive := filepath.Join(filepath.Dir(l.Path), "DRIFT_ARCHIVE.md")
			_, err := l.Prune(drift.PruneOptions{KeepCount: 20, ArchivePath: archive})
			return err
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	return c
}

// humanActionPath resolves HUMAN_ACTION_REQUIRED.md given project-dir
// and the $HUMAN_ACTION_FILE env override.
func humanActionPath(projectDir string) string {
	if projectDir == "" {
		projectDir, _ = os.Getwd()
	}
	override := os.Getenv("HUMAN_ACTION_FILE")
	if override == "" {
		override = "HUMAN_ACTION_REQUIRED.md"
	}
	if filepath.IsAbs(override) {
		return override
	}
	return filepath.Join(projectDir, override)
}

func newDriftHumanActionCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "human-action",
		Short: "Manage HUMAN_ACTION_REQUIRED.md (append/count/consolidate-legacy)",
	}
	c.AddCommand(newDriftHumanActionAppendCmd())
	c.AddCommand(newDriftHumanActionCountCmd())
	c.AddCommand(newDriftHumanActionConsolidateLegacyCmd())
	return c
}

// newDriftHumanActionConsolidateLegacyCmd exposes
// HumanAction.ConsolidateLegacy via the CLI. The bash entry point
// `consolidate_legacy_human_action` lived in lib/drift_artifacts.sh
// and was deleted by m25; tekhton-legacy.sh:2271 still calls it during
// startup cleanup to fold a stale root-level HUMAN_ACTION_REQUIRED.md
// into the canonical .tekhton/ path. Without this shim the legacy
// startup path fails with "command not found" on any project where
// the legacy file exists or m25 ran without a clean rebuild.
//
// Default --legacy-path is the workspace root sibling of the
// canonical path, matching the pre-m25 behavior. Prints the merged
// item count to stdout (0 on no-op).
func newDriftHumanActionConsolidateLegacyCmd() *cobra.Command {
	var (
		projectDir string
		legacyPath string
	)
	c := &cobra.Command{
		Use:   "consolidate-legacy",
		Short: "Merge a legacy HUMAN_ACTION_REQUIRED.md into the canonical path",
		RunE: func(cmd *cobra.Command, _ []string) error {
			canonical := humanActionPath(projectDir)
			if legacyPath == "" {
				// Default: the root-of-project sibling, used pre-m25
				// when HUMAN_ACTION_FILE lived at PROJECT_DIR root
				// rather than under .tekhton/.
				pd := projectDir
				if pd == "" {
					pd, _ = os.Getwd()
				}
				legacyPath = filepath.Join(pd, "HUMAN_ACTION_REQUIRED.md")
			}
			h := drift.NewHumanAction(canonical)
			merged, err := h.ConsolidateLegacy(legacyPath)
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%d\n", merged)
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().StringVar(&legacyPath, "legacy-path", "", "legacy file path (defaults to PROJECT_DIR/HUMAN_ACTION_REQUIRED.md)")
	return c
}

func newDriftHumanActionAppendCmd() *cobra.Command {
	var (
		projectDir  string
		source      string
		description string
	)
	c := &cobra.Command{
		Use:   "append",
		Short: "Add an action item to HUMAN_ACTION_REQUIRED.md",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if source == "" || description == "" {
				return errExitCode{code: exitUsage, err: fmt.Errorf("--source and --description are required")}
			}
			h := drift.NewHumanAction(humanActionPath(projectDir))
			return h.Append(source, description)
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().StringVar(&source, "source", "", "source label (e.g. \"security\", \"architect\")")
	c.Flags().StringVar(&description, "description", "", "human-action description body")
	return c
}

func newDriftHumanActionCountCmd() *cobra.Command {
	var projectDir string
	c := &cobra.Command{
		Use:   "count",
		Short: "Print the count of unchecked human-action items",
		RunE: func(cmd *cobra.Command, _ []string) error {
			h := drift.NewHumanAction(humanActionPath(projectDir))
			n, err := h.CountUnchecked()
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%d\n", n)
			return nil
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	return c
}

func newDriftAuditStatusCmd() *cobra.Command {
	var (
		projectDir   string
		obsThreshold int
		runsThresh   int
	)
	c := &cobra.Command{
		Use:   "audit-status",
		Short: "Report runs_since_audit + threshold status",
		RunE: func(cmd *cobra.Command, _ []string) error {
			l := drift.NewLog(driftLogPath(projectDir))
			runs, err := l.GetRunsSinceAudit()
			if err != nil {
				return err
			}
			obs, err := l.CountUnresolved()
			if err != nil {
				return err
			}
			trigger, err := l.ShouldTriggerAudit(obsThreshold, runsThresh)
			if err != nil {
				return err
			}
			enc := json.NewEncoder(cmd.OutOrStdout())
			enc.SetIndent("", "  ")
			return enc.Encode(map[string]any{
				"runs_since_audit":     runs,
				"unresolved":           obs,
				"obs_threshold":        obsThreshold,
				"runs_threshold":       runsThresh,
				"should_trigger_audit": trigger,
			})
		},
	}
	c.Flags().StringVar(&projectDir, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().IntVar(&obsThreshold, "obs-threshold", 8, "unresolved threshold")
	c.Flags().IntVar(&runsThresh, "runs-threshold", 5, "runs-since-audit threshold")
	return c
}
