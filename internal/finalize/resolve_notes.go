package finalize

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/notes"
)

// ResolveNotes is the Go body of _hook_resolve_notes. m24 port of the
// bash function in lib/finalize_core_hooks.sh: walks the active
// CLAIMED_NOTE_IDS list and transitions each note to Done or Pending
// based on the pipeline exit code, then sweeps any leftover Active
// markers ("orphans") with the same outcome.
//
// The bash version read `$CLAIMED_NOTE_IDS` and `$_PIPELINE_EXIT_CODE`
// from the environment. The Go body reads CLAIMED_NOTE_IDS from
// Input.Env (the finalize shim envelope) and the exit code from
// Input.ExitCode.
type ResolveNotes struct{}

// Name implements Hook.
func (h *ResolveNotes) Name() string { return "_hook_resolve_notes" }

// Run executes the hook. Always returns nil — note resolution failures
// are warnings, not errors (chain semantics).
func (h *ResolveNotes) Run(_ context.Context, in *Input) error {
	path := notesFilePath(in)
	d, err := notes.Load(path)
	if err != nil {
		if errors.Is(err, notes.ErrNotFound) {
			return nil
		}
		fmt.Fprintf(logWriter(in), "resolve_notes: load %s: %v\n", path, err)
		return nil
	}
	claimed := splitClaimedIDs(envValue(in, "CLAIMED_NOTE_IDS"))
	res := notes.ResolveActive(d, notes.ResolveOptions{
		ExitCode:   in.ExitCode,
		ClaimedIDs: claimed,
	})
	if res.ResolvedByID == 0 && res.OrphansSwept == 0 {
		return nil
	}
	if err := d.Save(); err != nil {
		fmt.Fprintf(logWriter(in), "resolve_notes: save: %v\n", err)
		return nil
	}
	verb := "completed"
	if in.ExitCode != 0 {
		verb = "reset for next run"
	}
	if res.ResolvedByID > 0 {
		fmt.Fprintf(logWriter(in), "resolve_notes: %d note(s) %s by ID\n", res.ResolvedByID, verb)
	}
	if res.OrphansSwept > 0 {
		fmt.Fprintf(logWriter(in), "resolve_notes: %d orphan(s) swept (%s)\n", res.OrphansSwept, verb)
	}
	return nil
}

// notesFilePath returns the HUMAN_NOTES.md path for the given Input.
// Mirrors the bash convention of `${HUMAN_NOTES_FILE}` resolution: an
// absolute env path wins, otherwise the path is joined to ProjectDir,
// otherwise default to ProjectDir/HUMAN_NOTES.md.
func notesFilePath(in *Input) string {
	override := envValue(in, "HUMAN_NOTES_FILE")
	return notes.ResolvePath(in.ProjectDir, override)
}

// envValue searches Input.EnvKV (m26 contract) first, then
// Input.Env (legacy), then the process environment. Returns the
// first matching key.
func envValue(in *Input, key string) string {
	prefix := key + "="
	for _, kv := range in.EnvKV {
		if strings.HasPrefix(kv, prefix) {
			return kv[len(prefix):]
		}
	}
	for _, kv := range in.Env {
		if strings.HasPrefix(kv, prefix) {
			return kv[len(prefix):]
		}
	}
	return os.Getenv(key)
}

// splitClaimedIDs splits the bash `CLAIMED_NOTE_IDS` space-separated
// string into a slice. Empty input → nil slice.
func splitClaimedIDs(raw string) []string {
	if raw == "" {
		return nil
	}
	fields := strings.Fields(raw)
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		if f != "" {
			out = append(out, f)
		}
	}
	return out
}

// logWriter returns the io.Writer the hook should log to. Defaults to
// os.Stderr when Input.Log is nil.
func logWriter(in *Input) io.Writer {
	if in.Log != nil {
		return in.Log
	}
	return os.Stderr
}
