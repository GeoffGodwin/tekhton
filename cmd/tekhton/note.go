package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/notes"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/spf13/cobra"
)

// newNoteCmd wires `tekhton note` — the user-facing note management
// surface that supersedes lib/notes_cli.sh. Visible (not Hidden):
// this is the only Phase 5 subcommand authored as part of m24's
// "user-facing utilities are visible" rule of thumb.
//
// Subcommand tree (matches the bash dispatch in lib/notes_cli.sh +
// lib/notes_cli_write.sh, plus the rollback / migrate / triage
// commands that previously lived as separate `tekhton --triage` etc.):
//
//	tekhton note add      [--tag TAG] [--priority P] [--description TEXT] TITLE
//	tekhton note list     [--tag TAG] [--state STATE] [--format md|json]
//	tekhton note done     <ID>
//	tekhton note reopen   <ID>
//	tekhton note claim    <ID>
//	tekhton note unclaim  <ID>
//	tekhton note triage   [--tag TAG]
//	tekhton note migrate
//	tekhton note rollback <SNAPSHOT_ID>
//	tekhton note resolve  [--tag TAG]
//	tekhton note extract  [--tag TAG]     # bash-callable: stdout-only
//
// The Extract subcommand is the m24 replacement for the bash
// `extract_human_notes` function: it prints the unchecked-notes block
// to stdout in the same shape that lib/notes.sh produced, so
// stages/coder.sh can substitute `$(tekhton note extract --tag ...)`
// without touching the prompt engine.
func newNoteCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "note",
		Short: "Manage HUMAN_NOTES.md entries",
		Long: "Manage HUMAN_NOTES.md entries — the three-state note queue " +
			"(`[ ]` pending, `[~]` active, `[x]` done) that drives the\n" +
			"--with-notes / --human pipeline modes.\n\n" +
			"Examples:\n" +
			"  tekhton note add --tag BUG 'logging breaks on rotated handle'\n" +
			"  tekhton note list --tag FEAT\n" +
			"  tekhton note done n07\n" +
			"  tekhton note list --format json | jq '.entries[].title'",
	}
	c.AddCommand(newNoteAddCmd())
	c.AddCommand(newNoteListCmd())
	c.AddCommand(newNoteDoneCmd())
	c.AddCommand(newNoteReopenCmd())
	c.AddCommand(newNoteClaimCmd())
	c.AddCommand(newNoteUnclaimCmd())
	c.AddCommand(newNoteTriageCmd())
	c.AddCommand(newNoteMigrateCmd())
	c.AddCommand(newNoteRollbackCmd())
	c.AddCommand(newNoteResolveCmd())
	c.AddCommand(newNoteExtractCmd())
	if registerHumanModeSubcommands != nil {
		registerHumanModeSubcommands(c)
	}
	return c
}

// noteCommonFlags wires the shared --project-dir / --notes-file flag
// pair every subcommand exposes. Returns getters that resolve to
// either the flag value or the appropriate environment default.
func noteCommonFlags(c *cobra.Command) (projectDir *string, notesFile *string) {
	pd := ""
	nf := ""
	c.Flags().StringVar(&pd, "project-dir", "", "project directory (defaults to cwd)")
	c.Flags().StringVar(&nf, "notes-file", "", "HUMAN_NOTES.md path (overrides default + $HUMAN_NOTES_FILE)")
	return &pd, &nf
}

// resolveProject resolves the project directory + notes path from the
// flag values + env. Mirrors the bash convention of falling back to
// $HUMAN_NOTES_FILE then to PROJECT_DIR/HUMAN_NOTES.md.
func resolveProject(projectDirFlag, notesFileFlag string) (string, string) {
	projectDir := projectDirFlag
	if projectDir == "" {
		projectDir, _ = os.Getwd()
	}
	notesPath := notesFileFlag
	if notesPath == "" {
		notesPath = os.Getenv("HUMAN_NOTES_FILE")
	}
	if notesPath == "" {
		notesPath = notes.DefaultNotesFileName
	}
	return projectDir, notes.ResolvePath(projectDir, notesPath)
}

// loadOrCreate loads the notes file, creating it from the standard
// template when missing. Used by `add` (which always wants a writable
// document) and `migrate` (which needs the file present).
func loadOrCreate(notesPath, projectName string) (*notes.Document, error) {
	d, err := notes.Load(notesPath)
	if err == nil {
		return d, nil
	}
	if !errors.Is(err, notes.ErrNotFound) {
		return nil, err
	}
	return notes.EnsureFile(notesPath, projectName)
}

// loadOrFail returns the document or a typed exit-code error suitable
// for the CLI's "missing notes file" message.
func loadOrFail(notesPath string) (*notes.Document, error) {
	d, err := notes.Load(notesPath)
	if err == nil {
		return d, nil
	}
	if errors.Is(err, notes.ErrNotFound) {
		return nil, errExitCode{code: exitNotFound,
			err: fmt.Errorf("no HUMAN_NOTES.md at %s — try `tekhton note add` first", notesPath)}
	}
	return nil, err
}

// newNoteAddCmd implements `tekhton note add`.
func newNoteAddCmd() *cobra.Command {
	var (
		tag         string
		priority    string
		description string
		source      string
		inboxFile   string
	)
	c := &cobra.Command{
		Use:   "add [flags] TITLE",
		Short: "Add a new note to HUMAN_NOTES.md",
		Long: "Add a new note. TITLE is required. Tags default to FEAT and " +
			"must be one of the registered tag set (BUG, FEAT, POLISH, or " +
			"any custom tags loaded from pipeline.conf).\n\n" +
			"Examples:\n" +
			"  tekhton note add 'add CSV export to settings'\n" +
			"  tekhton note add --tag BUG --priority high 'login loop after token refresh'\n" +
			"  tekhton note add --tag POLISH --description 'matches new brand kit' 'recolor primary button'",
		Args: cobra.MinimumNArgs(1),
	}
	pd, nf := noteCommonFlags(c)
	c.Flags().StringVar(&tag, "tag", "", "tag (BUG / FEAT / POLISH / custom)")
	c.Flags().StringVar(&priority, "priority", "", "priority (low / medium / high)")
	c.Flags().StringVar(&description, "description", "", "indented description block")
	c.Flags().StringVar(&source, "source", "cli", "source attribution for metadata")
	c.Flags().StringVar(&inboxFile, "inbox-file", "", "watchtower inbox basename (advanced)")
	c.RunE = func(cmd *cobra.Command, args []string) error {
		title := strings.Join(args, " ")
		projectDir, notesPath := resolveProject(*pd, *nf)
		projectName := os.Getenv("PROJECT_NAME")
		if projectName == "" {
			projectName = projectDirBase(projectDir)
		}
		d, err := loadOrCreate(notesPath, projectName)
		if err != nil {
			return err
		}
		d.Path = notesPath
		n, err := d.Add(notes.AddOpts{
			Title:       title,
			Tag:         tag,
			Priority:    priority,
			Source:      source,
			Description: description,
			InboxFile:   inboxFile,
		})
		if err != nil {
			if errors.Is(err, notes.ErrInvalidTag) || errors.Is(err, notes.ErrEmptyTitle) {
				return errExitCode{code: exitUsage, err: err}
			}
			return err
		}
		if err := d.Save(); err != nil {
			return err
		}
		fmt.Fprintf(cmd.OutOrStdout(), "Added [%s] note (%s): %s\n", n.Tag, n.ID, n.Title)
		return nil
	}
	return c
}

// newNoteListCmd implements `tekhton note list`.
func newNoteListCmd() *cobra.Command {
	var (
		tag    string
		state  string
		format string
	)
	c := &cobra.Command{
		Use:   "list",
		Short: "List notes",
		Long: "List notes by tag and/or state. Default emits markdown; " +
			"`--format json` emits the `" + proto.NotesListProtoV1 + "` envelope.",
	}
	pd, nf := noteCommonFlags(c)
	c.Flags().StringVar(&tag, "tag", "", "filter by tag")
	c.Flags().StringVar(&state, "state", "pending", "filter by state (pending / active / done / all)")
	c.Flags().StringVar(&format, "format", "md", "output format (md / json)")
	c.RunE = func(cmd *cobra.Command, _ []string) error {
		_, notesPath := resolveProject(*pd, *nf)
		d, err := notes.Load(notesPath)
		if err != nil && !errors.Is(err, notes.ErrNotFound) {
			return err
		}
		opts := notes.ExtractOpts{FilterTag: tag, IncludeMetadata: true}
		switch strings.ToLower(state) {
		case "pending":
			opts.OnlyState = notes.Pending
		case "active":
			opts.OnlyState = notes.Active
		case "done":
			opts.OnlyState = notes.Done
		case "all":
			opts.IncludeAll = true
		default:
			return errExitCode{code: exitUsage,
				err: fmt.Errorf("unknown --state %q (allowed: pending, active, done, all)", state)}
		}
		switch format {
		case "json":
			return emitNotesJSON(cmd, d, opts, notesPath, tag)
		case "md":
			return emitNotesMD(cmd, d, opts)
		default:
			return errExitCode{code: exitUsage,
				err: fmt.Errorf("unknown --format %q (allowed: md, json)", format)}
		}
	}
	return c
}

// emitNotesMD prints a markdown bullet list (one note per line) to
// stdout. Matches the legacy `list_human_notes_cli` shape with the
// non-color path (tests run without TTY).
func emitNotesMD(cmd *cobra.Command, d *notes.Document, opts notes.ExtractOpts) error {
	w := cmd.OutOrStdout()
	if d == nil {
		fmt.Fprintln(w, "No HUMAN_NOTES.md found.")
		return nil
	}
	for _, n := range d.Notes {
		if !opts.IncludeAll && n.State != opts.OnlyState {
			continue
		}
		if opts.FilterTag != "" && n.Tag != opts.FilterTag {
			continue
		}
		fmt.Fprintf(w, "%s [%s] %s", n.State.Checkbox(), n.Tag, n.Title)
		if n.ID != "" {
			fmt.Fprintf(w, "  (%s)", n.ID)
		}
		fmt.Fprintln(w)
	}
	return nil
}

// emitNotesJSON writes the NotesListV1 envelope.
func emitNotesJSON(cmd *cobra.Command, d *notes.Document, opts notes.ExtractOpts, path, filter string) error {
	env := &proto.NotesListV1{Proto: proto.NotesListProtoV1, Path: path, Filter: filter}
	if d != nil {
		for _, n := range d.Notes {
			if !opts.IncludeAll && n.State != opts.OnlyState {
				continue
			}
			if opts.FilterTag != "" && n.Tag != opts.FilterTag {
				continue
			}
			env.Entries = append(env.Entries, &proto.NoteEntryV1{
				ID:       n.ID,
				Tag:      n.Tag,
				State:    strings.ToLower(n.State.String()),
				Title:    n.Title,
				Section:  n.SectionHeading,
				Priority: n.Metadata["priority"],
				Source:   n.Metadata["source"],
				Created:  n.Metadata["created"],
				Triage:   n.Metadata["triage"],
			})
		}
	}
	env.Total = len(env.Entries)
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(env)
}
