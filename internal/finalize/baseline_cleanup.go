package finalize

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/notes"
)

// BaselineCleanup is the Go body of _hook_baseline_cleanup. The bash
// version called `cleanup_stale_baselines` from lib/test_baseline.sh.
// Two concerns mix in this hook:
//
//  1. Notes-side: any leftover Active (`[~]`) markers from a prior
//     crashed run get reset to Pending so the next pipeline sees a
//     clean queue. m24 ports this branch to pure Go.
//
//  2. Test-baseline-side: stale `.test_baseline_*` fingerprints get
//     removed. The test-baseline subsystem ports in a later milestone
//     (it is not part of m24's notes scope), so we delegate to a
//     narrow bash exec until that lands. Failure here is logged and
//     the chain continues.
type BaselineCleanup struct{}

// Name implements Hook.
func (h *BaselineCleanup) Name() string { return "_hook_baseline_cleanup" }

// Run executes both branches. Returns nil — chain semantics.
func (h *BaselineCleanup) Run(ctx context.Context, in *Input) error {
	// Notes branch.
	path := notesFilePath(in)
	if d, err := notes.Load(path); err == nil {
		if reset := notes.ClearActive(d); reset > 0 {
			if err := d.Save(); err != nil {
				fmt.Fprintf(logWriter(in), "baseline_cleanup: save notes: %v\n", err)
			} else {
				fmt.Fprintf(logWriter(in),
					"baseline_cleanup: reset %d stale [~] note(s) from prior run\n", reset)
			}
		}
	} else if !errors.Is(err, notes.ErrNotFound) {
		fmt.Fprintf(logWriter(in), "baseline_cleanup: load notes: %v\n", err)
	}

	// Test-baseline branch — delegate to bash. The function lives in
	// lib/test_baseline.sh. A narrow `bash -c` keeps the orchestrator
	// in charge while reusing the existing implementation.
	if in.TekhtonHome != "" {
		script := filepath.Join(in.TekhtonHome, "lib", "test_baseline.sh")
		if fileExists(script) {
			runBashHookFn(ctx, in, script, "cleanup_stale_baselines")
		}
	}
	return nil
}
