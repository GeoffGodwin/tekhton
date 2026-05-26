package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/notes"
	"github.com/spf13/cobra"
)

// note_human.go — m24 CLI subcommands that drive the --human mode
// pipeline loop in tekhton-legacy.sh. These mirror the bash helpers
// the deleted lib/notes_single.sh and lib/notes_triage_flow.sh used to
// provide (pick_next_note, _find_note_by_id, count_unchecked_notes,
// triage_before_claim, claim_human_notes, resolve_human_notes,
// clear_completed_human_notes).
//
// Every subcommand here is Hidden — they're internal seams the bash
// shim uses, not user-facing surface. The visible commands stay in
// note.go / note_ops.go.

func init() {
	registerHumanModeSubcommands = func(parent *cobra.Command) {
		parent.AddCommand(newNotePickNextCmd())
		parent.AddCommand(newNoteFindCmd())
		parent.AddCommand(newNoteCountCmd())
		parent.AddCommand(newNoteClaimBulkCmd())
		parent.AddCommand(newNoteResolveBulkCmd())
		parent.AddCommand(newNoteClearCompletedCmd())
		parent.AddCommand(newNoteDoneFuzzyCmd())
		parent.AddCommand(newNoteShouldClaimCmd())
	}
}

// registerHumanModeSubcommands is set by init() so newNoteCmd can
// attach these without a forward-declared dependency.
var registerHumanModeSubcommands func(*cobra.Command)

// newNotePickNextCmd implements `tekhton note pick-next`. Prints the
// raw line of the highest-priority Pending note, or empty when none
// matches. Mirrors `pick_next_note` from lib/notes_single.sh.
func newNotePickNextCmd() *cobra.Command {
	var tag string
	c := &cobra.Command{
		Use:    "pick-next",
		Short:  "Print raw line of next Pending note (bash-callable)",
		Hidden: true,
	}
	pd, nf := noteCommonFlags(c)
	c.Flags().StringVar(&tag, "tag", "", "filter by tag")
	c.RunE = func(cmd *cobra.Command, _ []string) error {
		_, path := resolveProject(*pd, *nf)
		d, err := notes.Load(path)
		if err != nil {
			if errors.Is(err, notes.ErrNotFound) {
				return nil
			}
			return err
		}
		n := notes.PickNext(d, tag)
		if n == nil {
			return nil
		}
		// Print the verbatim line so claim_single_note's exact-match
		// semantic carries over.
		fmt.Fprintln(cmd.OutOrStdout(), d.Lines[n.LineIdx].Raw)
		return nil
	}
	return c
}

// newNoteFindCmd implements `tekhton note find <ID>`. Prints the raw
// line for a note ID, or empty when not found. Mirrors `_find_note_by_id`.
func newNoteFindCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "find ID",
		Short:  "Print raw line for note ID (bash-callable)",
		Args:   cobra.ExactArgs(1),
		Hidden: true,
	}
	pd, nf := noteCommonFlags(c)
	c.RunE = func(cmd *cobra.Command, args []string) error {
		_, path := resolveProject(*pd, *nf)
		d, err := notes.Load(path)
		if err != nil {
			if errors.Is(err, notes.ErrNotFound) {
				return nil
			}
			return err
		}
		n, err := d.FindByID(args[0])
		if err != nil {
			return nil
		}
		fmt.Fprintln(cmd.OutOrStdout(), d.Lines[n.LineIdx].Raw)
		return nil
	}
	return c
}

// newNoteCountCmd implements `tekhton note count`. Mirrors
// `count_human_notes` / `count_unchecked_notes`. Honors NOTES_FILTER
// env when --tag is not supplied so the bash callsites carry over
// without rewriting their wrapper.
func newNoteCountCmd() *cobra.Command {
	var (
		tag   string
		state string
	)
	c := &cobra.Command{
		Use:    "count",
		Short:  "Print count of notes (bash-callable)",
		Hidden: true,
	}
	pd, nf := noteCommonFlags(c)
	c.Flags().StringVar(&tag, "tag", "", "filter by tag (defaults to $NOTES_FILTER)")
	c.Flags().StringVar(&state, "state", "pending", "filter by state (pending / active / done / all)")
	c.RunE = func(cmd *cobra.Command, _ []string) error {
		if tag == "" {
			tag = os.Getenv("NOTES_FILTER")
		}
		_, path := resolveProject(*pd, *nf)
		d, err := notes.Load(path)
		if err != nil {
			if errors.Is(err, notes.ErrNotFound) {
				fmt.Fprintln(cmd.OutOrStdout(), "0")
				return nil
			}
			return err
		}
		var target notes.State
		all := false
		switch strings.ToLower(state) {
		case "pending":
			target = notes.Pending
		case "active":
			target = notes.Active
		case "done":
			target = notes.Done
		case "all":
			all = true
		default:
			return errExitCode{code: exitUsage,
				err: fmt.Errorf("unknown --state %q", state)}
		}
		count := 0
		for _, n := range d.Notes {
			if !all && n.State != target {
				continue
			}
			if tag != "" && n.Tag != tag {
				continue
			}
			count++
		}
		fmt.Fprintln(cmd.OutOrStdout(), count)
		return nil
	}
	return c
}

// newNoteClaimBulkCmd implements `tekhton note claim-bulk`. Mirrors
// `claim_human_notes` / `claim_notes_batch` — claims every Pending note
// matching --tag (or $NOTES_FILTER) as Active and prints the
// space-separated claimed IDs to stdout. Callers capture this into
// CLAIMED_NOTE_IDS for the finalize chain.
func newNoteClaimBulkCmd() *cobra.Command {
	var tag string
	c := &cobra.Command{
		Use:    "claim-bulk",
		Short:  "Bulk-claim Pending notes; print claimed IDs (bash-callable)",
		Hidden: true,
	}
	pd, nf := noteCommonFlags(c)
	c.Flags().StringVar(&tag, "tag", "", "filter by tag (defaults to $NOTES_FILTER)")
	c.RunE = func(cmd *cobra.Command, _ []string) error {
		if tag == "" {
			tag = os.Getenv("NOTES_FILTER")
		}
		_, path := resolveProject(*pd, *nf)
		d, err := notes.Load(path)
		if err != nil {
			if errors.Is(err, notes.ErrNotFound) {
				return nil
			}
			return err
		}
		ids := d.ClaimMatching(tag)
		if err := d.Save(); err != nil {
			return err
		}
		if len(ids) > 0 {
			fmt.Fprintln(cmd.OutOrStdout(), strings.Join(ids, " "))
		}
		return nil
	}
	return c
}

// newNoteResolveBulkCmd implements `tekhton note resolve-bulk`. Mirrors
// `resolve_human_notes` — given a pipeline exit code and the list of
// claimed IDs, transitions Active notes to Done (exit 0) or back to
// Pending (non-zero). Orphan `[~]` notes (claimed via paths the
// finalize chain didn't see) are swept the same way.
func newNoteResolveBulkCmd() *cobra.Command {
	var (
		exitCode int
		ids      string
	)
	c := &cobra.Command{
		Use:    "resolve-bulk",
		Short:  "Bulk-resolve claimed notes by exit code (bash-callable)",
		Hidden: true,
	}
	pd, nf := noteCommonFlags(c)
	c.Flags().IntVar(&exitCode, "exit-code", 1, "pipeline exit code (0 → Done; non-zero → Pending)")
	c.Flags().StringVar(&ids, "ids", "", "space-separated claimed IDs (defaults to $CLAIMED_NOTE_IDS)")
	c.RunE = func(cmd *cobra.Command, _ []string) error {
		if ids == "" {
			ids = os.Getenv("CLAIMED_NOTE_IDS")
		}
		_, path := resolveProject(*pd, *nf)
		d, err := notes.Load(path)
		if err != nil {
			if errors.Is(err, notes.ErrNotFound) {
				return nil
			}
			return err
		}
		res := notes.ResolveActive(d, notes.ResolveOptions{
			ExitCode:   exitCode,
			ClaimedIDs: strings.Fields(ids),
		})
		if err := d.Save(); err != nil {
			return err
		}
		fmt.Fprintf(cmd.OutOrStdout(), "resolved=%d orphans=%d state=%s\n",
			res.ResolvedByID, res.OrphansSwept, strings.ToLower(res.OutcomeState.String()))
		return nil
	}
	return c
}

// newNoteClearCompletedCmd implements `tekhton note clear-completed`.
// Mirrors `clear_completed_human_notes` / `clear_completed_notes` —
// removes every Done note and its description block from the file.
func newNoteClearCompletedCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "clear-completed",
		Short:  "Remove [x] Done notes from HUMAN_NOTES.md (bash-callable)",
		Hidden: true,
	}
	pd, nf := noteCommonFlags(c)
	c.RunE = func(cmd *cobra.Command, _ []string) error {
		_, path := resolveProject(*pd, *nf)
		d, err := notes.Load(path)
		if err != nil {
			if errors.Is(err, notes.ErrNotFound) {
				return nil
			}
			return err
		}
		removed := notes.RemoveDone(d)
		if removed == 0 {
			return nil
		}
		if err := d.Save(); err != nil {
			return err
		}
		fmt.Fprintf(cmd.OutOrStdout(), "cleared %d completed note(s)\n", removed)
		return nil
	}
	return c
}

// newNoteDoneFuzzyCmd implements `tekhton note done-fuzzy`. Mirrors
// `complete_human_note` — accepts either a 1-based ordinal or a
// case-insensitive substring of the title and marks the matching note
// Done. Exits non-zero on ambiguous text match.
func newNoteDoneFuzzyCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "done-fuzzy NUM_OR_TEXT",
		Short:  "Mark a note done by ordinal or substring (bash-callable)",
		Args:   cobra.MinimumNArgs(1),
		Hidden: true,
	}
	pd, nf := noteCommonFlags(c)
	c.RunE = func(cmd *cobra.Command, args []string) error {
		needle := strings.Join(args, " ")
		_, path := resolveProject(*pd, *nf)
		d, err := loadOrFail(path)
		if err != nil {
			return err
		}
		var target *notes.Note
		if n, err := strconv.Atoi(needle); err == nil && n > 0 {
			// Ordinal — index into Pending notes in document order.
			idx := 0
			for _, note := range d.Notes {
				if note.State != notes.Pending {
					continue
				}
				idx++
				if idx == n {
					target = note
					break
				}
			}
			if target == nil {
				return errExitCode{code: exitNotFound,
					err: fmt.Errorf("no Pending note at ordinal %d", n)}
			}
		} else {
			lower := strings.ToLower(needle)
			matches := 0
			for _, note := range d.Notes {
				if note.State != notes.Pending {
					continue
				}
				if strings.Contains(strings.ToLower(note.Title), lower) {
					target = note
					matches++
				}
			}
			if matches == 0 {
				return errExitCode{code: exitNotFound,
					err: fmt.Errorf("no Pending note matches %q", needle)}
			}
			if matches > 1 {
				return errExitCode{code: exitUsage,
					err: fmt.Errorf("ambiguous match for %q (%d candidates)", needle, matches)}
			}
		}
		target.SetState(d, notes.Done)
		if err := d.Save(); err != nil {
			return err
		}
		fmt.Fprintf(cmd.OutOrStdout(), "done: %s (%s)\n", target.ID, target.Title)
		return nil
	}
	return c
}

// newNoteShouldClaimCmd implements `tekhton note should-claim`. Pure
// predicate — exits 0 if WITH_NOTES=true, HUMAN_MODE=true, or
// NOTES_FILTER non-empty. Mirrors `should_claim_notes` from lib/notes.sh.
func newNoteShouldClaimCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "should-claim",
		Short:  "Exit 0 if notes should be claimed for this run (bash-callable)",
		Hidden: true,
	}
	c.RunE = func(_ *cobra.Command, _ []string) error {
		if os.Getenv("WITH_NOTES") == "true" ||
			os.Getenv("HUMAN_MODE") == "true" ||
			os.Getenv("NOTES_FILTER") != "" {
			return nil
		}
		// Silent non-zero exit — main() suppresses the empty error message.
		return errExitCode{code: 1}
	}
	return c
}
