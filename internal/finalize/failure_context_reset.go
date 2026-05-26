package finalize

import (
	"context"
	"errors"
	"fmt"

	"github.com/geoffgodwin/tekhton/internal/failure_context"
	"github.com/geoffgodwin/tekhton/internal/notes"
)

// FailureContextReset is the Go body of _hook_failure_context_reset.
// Two concerns mix in this hook:
//
//  1. Notes-side: any stale Active markers from a failed prior run
//     get reset to Pending so the next pipeline starts clean. m24
//     ported this branch via notes.ClearActive.
//
//  2. Drift-side: the failure-cause primary/secondary slot state
//     that lives across stages must reset between runs so the next
//     invocation does not inherit stale cause context. m25 ports
//     this to internal/failure_context — the lib/failure_context.sh
//     delegation that m24 carried is gone now.
//
// Gates: only runs on pipeline success (matches bash semantics — the
// reset prevents leaking primary/secondary cause slot values into a
// subsequent same-shell invocation, e.g. --auto-advance chains).
type FailureContextReset struct{}

// Name implements Hook.
func (h *FailureContextReset) Name() string { return "_hook_failure_context_reset" }

// Run executes both branches. Returns nil — chain semantics.
func (h *FailureContextReset) Run(_ context.Context, in *Input) error {
	if in.ExitCode != 0 {
		return nil
	}
	// 1. Notes branch (pure Go).
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

	// 2. Drift-side: zero the failure-cause slots (m25 port — no
	//    bash delegation). The in-process Context is constructed
	//    fresh; Reset() is called for symmetry with the bash
	//    function name even though a fresh Context starts zeroed.
	//
	//    The slots themselves are owned by the diagnose/orchestrate
	//    writer subsystem; this hook is the bookkeeping reset that
	//    finalize runs at run-end so any same-shell next invocation
	//    does not inherit stale state. The Context lives in the
	//    runner across the run — its Reset call must mutate the
	//    shared instance, not a local one. m25 wires the runner's
	//    instance into Input.FailureContext (added by this milestone)
	//    when available; for callers that didn't supply one (legacy
	//    `tekhton finalize` debug, isolated tests), the hook is a
	//    no-op — there's no shared state to reset.
	if in.FailureContext != nil {
		in.FailureContext.Reset()
	}
	return nil
}

// Compile-time assertion that *failure_context.Context still
// satisfies the field type — keeps test failures next to the API
// drift rather than at runtime.
var _ failureContextResetter = (*failure_context.Context)(nil)

// failureContextResetter is the interface FailureContextReset needs
// from the runner-owned context. Defined here (not in
// internal/failure_context) so the package depends on a typed value
// rather than a circular interface — the lone Reset method is the
// stable surface the m25 hook calls.
type failureContextResetter interface {
	Reset()
}
