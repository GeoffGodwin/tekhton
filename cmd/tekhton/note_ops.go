package main

import (
	"errors"
	"fmt"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/notes"
	"github.com/spf13/cobra"
)

// projectDirBase returns the basename of the project directory, used as
// a fallback for PROJECT_NAME during note-file creation.
func projectDirBase(projectDir string) string {
	if projectDir == "" {
		return "project"
	}
	return filepath.Base(projectDir)
}

// runIDCommand factors the common shape shared by done / reopen / claim
// / unclaim: load → look up by ID → mutate → save. The mutate closure
// returns the success message that the CLI prints to stdout.
func runIDCommand(verb string, mutate func(*notes.Document, string) error) func(*cobra.Command, []string) error {
	return func(cmd *cobra.Command, args []string) error {
		id := args[0]
		// project + path resolution lives on the parent command's
		// flags — fetch them from cmd via Flags().Lookup so this
		// helper can serve every variant.
		pd, _ := cmd.Flags().GetString("project-dir")
		nf, _ := cmd.Flags().GetString("notes-file")
		_, path := resolveProject(pd, nf)
		d, err := loadOrFail(path)
		if err != nil {
			return err
		}
		if err := mutate(d, id); err != nil {
			if errors.Is(err, notes.ErrNoteNotFound) {
				return errExitCode{code: exitNotFound, err: err}
			}
			return err
		}
		if err := d.Save(); err != nil {
			return err
		}
		fmt.Fprintf(cmd.OutOrStdout(), "%s: %s\n", verb, id)
		return nil
	}
}

func newNoteDoneCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "done ID",
		Short: "Mark a note done ([x])",
		Args:  cobra.ExactArgs(1),
	}
	_, _ = noteCommonFlags(c)
	c.RunE = runIDCommand("done", (*notes.Document).MarkDone)
	return c
}

func newNoteReopenCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "reopen ID",
		Short: "Reopen a note ([x] → [ ])",
		Args:  cobra.ExactArgs(1),
	}
	_, _ = noteCommonFlags(c)
	c.RunE = runIDCommand("reopen", (*notes.Document).MarkPending)
	return c
}

func newNoteClaimCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "claim ID",
		Short: "Claim a note for the current run ([ ] → [~])",
		Args:  cobra.ExactArgs(1),
	}
	_, _ = noteCommonFlags(c)
	c.RunE = runIDCommand("claim", (*notes.Document).Claim)
	return c
}

func newNoteUnclaimCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "unclaim ID",
		Short: "Release a claimed note ([~] → [ ])",
		Args:  cobra.ExactArgs(1),
	}
	_, _ = noteCommonFlags(c)
	c.RunE = runIDCommand("unclaim", (*notes.Document).Unclaim)
	return c
}

func newNoteResolveCmd() *cobra.Command {
	var tag string
	c := &cobra.Command{
		Use:   "resolve",
		Short: "Bulk-resolve all Pending notes for a tag",
		Long: "Mark every Pending note matching --tag as Done. Use with " +
			"care — there is no undo. Without --tag this is a no-op " +
			"(the bash version refused to operate on all tags at once " +
			"and the Go port matches).",
	}
	pd, nf := noteCommonFlags(c)
	c.Flags().StringVar(&tag, "tag", "", "tag to resolve (required)")
	c.RunE = func(cmd *cobra.Command, _ []string) error {
		if tag == "" {
			return errExitCode{code: exitUsage,
				err: fmt.Errorf("--tag is required to avoid resolving the whole queue")}
		}
		_, path := resolveProject(*pd, *nf)
		d, err := loadOrFail(path)
		if err != nil {
			return err
		}
		count := d.ResolveByTag(tag)
		if err := d.Save(); err != nil {
			return err
		}
		fmt.Fprintf(cmd.OutOrStdout(), "Resolved %d [%s] note(s)\n", count, tag)
		return nil
	}
	return c
}

func newNoteExtractCmd() *cobra.Command {
	var (
		tag             string
		includeMetadata bool
	)
	c := &cobra.Command{
		Use:    "extract",
		Short:  "Print the HUMAN_NOTES_BLOCK content (replaces bash extract_human_notes)",
		Hidden: true, // bash-callable seam, not a primary user command
	}
	pd, nf := noteCommonFlags(c)
	c.Flags().StringVar(&tag, "tag", "", "filter by tag")
	c.Flags().BoolVar(&includeMetadata, "include-metadata", false, "keep `<!-- note:... -->` trailer")
	c.RunE = func(cmd *cobra.Command, _ []string) error {
		_, path := resolveProject(*pd, *nf)
		d, err := notes.Load(path)
		if err != nil {
			if errors.Is(err, notes.ErrNotFound) {
				return nil
			}
			return err
		}
		body := notes.Extract(d, notes.ExtractOpts{
			FilterTag:       tag,
			OnlyState:       notes.Pending,
			IncludeMetadata: includeMetadata,
		})
		if body != "" {
			fmt.Fprintln(cmd.OutOrStdout(), body)
		}
		return nil
	}
	return c
}

func newNoteMigrateCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "migrate",
		Short: "Upgrade legacy HUMAN_NOTES.md to the v2 format (adds IDs + marker)",
		Long: "Idempotent. Running on a v2 file is a no-op (exit 0 with a " +
			"one-line message). Always writes a `.v1-backup` snapshot " +
			"before mutating.",
	}
	pd, nf := noteCommonFlags(c)
	c.RunE = func(cmd *cobra.Command, _ []string) error {
		_, path := resolveProject(*pd, *nf)
		d, err := loadOrFail(path)
		if err != nil {
			return err
		}
		// Snapshot first so a crash mid-migrate is recoverable.
		if _, err := notes.WriteBackup(path); err != nil {
			return err
		}
		res, err := notes.Migrate(d)
		if errors.Is(err, notes.ErrAlreadyMigrated) {
			fmt.Fprintln(cmd.OutOrStdout(), "HUMAN_NOTES.md already in v2 format — nothing to do")
			return nil
		}
		if err != nil {
			return err
		}
		if err := d.Save(); err != nil {
			return err
		}
		fmt.Fprintf(cmd.OutOrStdout(),
			"Migrated %d note(s) to v2 format. Backup: %s\n",
			res.Migrated, res.BackupPath)
		return nil
	}
	return c
}

func newNoteRollbackCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "rollback SNAPSHOT_ID",
		Short: "Restore note state from a snapshot under .claude/notes_snapshots/",
		Args:  cobra.ExactArgs(1),
	}
	pd, nf := noteCommonFlags(c)
	c.RunE = func(cmd *cobra.Command, args []string) error {
		projectDir, path := resolveProject(*pd, *nf)
		d, err := loadOrFail(path)
		if err != nil {
			return err
		}
		sn, err := notes.ReadSnapshot(projectDir, args[0])
		if err != nil {
			return err
		}
		reset := notes.RestoreStates(d, sn)
		if err := d.Save(); err != nil {
			return err
		}
		fmt.Fprintf(cmd.OutOrStdout(), "Restored %d note(s) from snapshot %s\n", reset, args[0])
		return nil
	}
	return c
}

func newNoteTriageCmd() *cobra.Command {
	var tag string
	c := &cobra.Command{
		Use:   "triage",
		Short: "Score Pending notes for fit/oversized disposition",
	}
	pd, nf := noteCommonFlags(c)
	c.Flags().StringVar(&tag, "tag", "", "filter by tag")
	c.RunE = func(cmd *cobra.Command, _ []string) error {
		_, path := resolveProject(*pd, *nf)
		d, err := notes.Load(path)
		if err != nil {
			if errors.Is(err, notes.ErrNotFound) {
				fmt.Fprintln(cmd.OutOrStdout(), "No HUMAN_NOTES.md found.")
				return nil
			}
			return err
		}
		report := notes.TriageReport(d, tag)
		if len(report) == 0 {
			fmt.Fprintln(cmd.OutOrStdout(), "No Pending notes to triage.")
			return nil
		}
		fmt.Fprintf(cmd.OutOrStdout(), "%-6s %-8s %-12s %-11s %s\n",
			"ID", "Tag", "Disposition", "Est. Turns", "Score")
		for _, r := range report {
			n, _ := d.FindByID(r.NoteID)
			tagText := ""
			if n != nil {
				tagText = n.Tag
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%-6s %-8s %-12s %-11d %d\n",
				r.NoteID, tagText, r.Disposition, r.EstTurns, r.Score)
		}
		return nil
	}
	return c
}
