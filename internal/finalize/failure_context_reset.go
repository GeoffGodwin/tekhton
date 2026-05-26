package finalize

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/notes"
)

// FailureContextReset is the Go body of _hook_failure_context_reset.
// Two concerns mix in this hook:
//
//  1. Notes-side: any stale Active markers from a failed prior run
//     get reset to Pending so the next pipeline starts clean. m24
//     ports this branch to pure Go via notes.ClearActive.
//
//  2. Drift-side: failure-cause slot state lives in
//     lib/failure_context.sh and is shared between notes and drift.
//     The drift port lands in m25, which is where
//     lib/failure_context.sh is removed; until then this hook
//     delegates to the existing bash `reset_failure_cause_context`
//     via runBashHookFn.
//
// Gates: only runs on pipeline success (matches bash semantics — the
// reset prevents leaking primary/secondary cause slot values into a
// subsequent same-shell invocation, e.g. --auto-advance chains).
type FailureContextReset struct{}

// Name implements Hook.
func (h *FailureContextReset) Name() string { return "_hook_failure_context_reset" }

// Run executes both branches. Returns nil — chain semantics.
func (h *FailureContextReset) Run(ctx context.Context, in *Input) error {
	if in.ExitCode != 0 {
		return nil
	}
	// Notes branch (pure Go).
	path := notesFilePath(in)
	if d, err := notes.Load(path); err == nil {
		if reset := notes.ClearActive(d); reset > 0 {
			if err := d.Save(); err != nil {
				fmt.Fprintf(logWriter(in), "failure_context_reset: save notes: %v\n", err)
			} else {
				fmt.Fprintf(logWriter(in),
					"failure_context_reset: cleared %d active note marker(s)\n", reset)
			}
		}
	} else if !errors.Is(err, notes.ErrNotFound) {
		fmt.Fprintf(logWriter(in), "failure_context_reset: load notes: %v\n", err)
	}

	// Drift branch — delegate to bash. lib/failure_context.sh is
	// owned by m25; m24 does not touch it.
	if in.TekhtonHome == "" {
		return nil
	}
	script := filepath.Join(in.TekhtonHome, "lib", "failure_context.sh")
	if !fileExists(script) {
		return nil
	}
	runBashHookFn(ctx, in, script, "reset_failure_cause_context")
	return nil
}
