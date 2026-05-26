package finalize

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/notes"
)

// NoteAcceptance is the Go body of _hook_note_acceptance. m24 port of
// `_hook_note_acceptance` (lib/finalize_aux.sh) and the underlying
// `run_note_acceptance` (lib/notes_acceptance.sh).
//
// Gates: only runs on pipeline success (ExitCode == 0) and only when
// NOTES_FILTER is set (no tag filter → no tag-scoped acceptance).
type NoteAcceptance struct{}

// Name implements Hook.
func (h *NoteAcceptance) Name() string { return "_hook_note_acceptance" }

// Run executes the tag-specific acceptance heuristics. Warnings are
// appended to CODER_SUMMARY.md and stored back to per-claimed-note
// metadata. Always returns nil — the bash version was warning-only.
func (h *NoteAcceptance) Run(ctx context.Context, in *Input) error {
	if in.ExitCode != 0 {
		return nil
	}
	tag := envValue(in, "NOTES_FILTER")
	if tag == "" {
		return nil
	}
	opts := notes.AcceptanceOptions{
		ProjectDir:       in.ProjectDir,
		CoderSummaryFile: coderSummaryFile(in),
	}
	res, err := notes.RunAcceptance(ctx, tag, opts)
	if err != nil {
		fmt.Fprintf(logWriter(in), "note_acceptance: %v\n", err)
		return nil
	}
	if res.Code == "pass" {
		fmt.Fprintf(logWriter(in), "note_acceptance [%s]: pass\n", tag)
		writeAcceptanceToMetadata(in, "pass", "")
		return nil
	}
	fmt.Fprintf(logWriter(in), "note_acceptance [%s]: warnings found\n", tag)
	for _, w := range res.Warnings {
		fmt.Fprintf(logWriter(in), "  %s\n", w)
	}
	appendAcceptanceToCoderSummary(opts.CoderSummaryFile, res.Warnings, in)
	writeAcceptanceToMetadata(in, res.Code, strings.Join(res.Warnings, "\n"))
	return nil
}

// coderSummaryFile returns the path to CODER_SUMMARY.md from the
// supplied input. Mirrors the bash `${CODER_SUMMARY_FILE}` resolution.
func coderSummaryFile(in *Input) string {
	override := envValue(in, "CODER_SUMMARY_FILE")
	if override == "" {
		return filepath.Join(in.ProjectDir, ".tekhton", "CODER_SUMMARY.md")
	}
	if filepath.IsAbs(override) {
		return override
	}
	return filepath.Join(in.ProjectDir, override)
}

// appendAcceptanceToCoderSummary appends an `## Acceptance Warnings`
// section to CODER_SUMMARY.md (when the file exists). Mirrors the
// bash `cat >> "${CODER_SUMMARY_FILE}"` heredoc.
func appendAcceptanceToCoderSummary(path string, warnings []string, in *Input) {
	if _, err := os.Stat(path); err != nil {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Fprintf(logWriter(in), "note_acceptance: open coder summary: %v\n", err)
		return
	}
	defer f.Close()
	fmt.Fprintln(f, "")
	fmt.Fprintln(f, "## Acceptance Warnings")
	for _, w := range warnings {
		fmt.Fprintf(f, "- %s\n", w)
	}
}

// writeAcceptanceToMetadata persists the acceptance result on each
// claimed note. Mirrors the bash `_store_acceptance_result` function
// from lib/notes_acceptance_helpers.sh — sets `acceptance:CODE` and
// `reviewer_skipped:BOOL` metadata fields.
func writeAcceptanceToMetadata(in *Input, code, _ string) {
	claimed := splitClaimedIDs(envValue(in, "CLAIMED_NOTE_IDS"))
	if len(claimed) == 0 {
		return
	}
	path := notesFilePath(in)
	d, err := notes.Load(path)
	if err != nil {
		return
	}
	skipped := envValue(in, "REVIEWER_SKIPPED")
	if skipped == "" {
		skipped = "false"
	}
	mutated := false
	for _, id := range claimed {
		n, err := d.FindByID(id)
		if err != nil {
			continue
		}
		n.SetMetadata(d, "acceptance", code)
		n.SetMetadata(d, "reviewer_skipped", skipped)
		mutated = true
	}
	if mutated {
		_ = d.Save()
	}
}
