package finalize

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/clarify"
)

// ClarifyFinalize is the m25 finalize hook that clears stale
// CLARIFICATIONS.md entries on successful pipeline completion. The
// new hook fills a previously-implicit TODO in the bash chain: the
// pre-m25 archive hook moved the file aside, but a partially-cleared
// state could survive into the next run. Clearing fully-answered
// state explicitly on success keeps each pipeline run starting
// from a clean clarify queue.
//
// The hook is gated on pipeline success (ExitCode == 0). On failure
// the file is left alone so a re-run can resume the same clarify
// session if needed.
type ClarifyFinalize struct{}

// Name implements Hook.
func (h *ClarifyFinalize) Name() string { return "_hook_clarify_finalize" }

// Run executes the hook. Returns nil — chain semantics.
func (h *ClarifyFinalize) Run(_ context.Context, in *Input) error {
	if in.ExitCode != 0 {
		return nil
	}
	projectDir := in.ProjectDir
	if projectDir == "" {
		var err error
		projectDir, err = os.Getwd()
		if err != nil {
			return nil
		}
	}
	override := envValue(in, "CLARIFICATIONS_FILE")
	if override == "" {
		override = "CLARIFICATIONS.md"
	}
	var path string
	if filepath.IsAbs(override) {
		path = override
	} else {
		path = filepath.Join(projectDir, override)
	}
	removed, err := clarify.ClearStaleEntries(path)
	if err != nil {
		fmt.Fprintf(logWriter(in), "clarify_finalize: %v\n", err)
		return nil
	}
	if removed {
		fmt.Fprintf(logWriter(in), "clarify_finalize: cleared stale %s\n", path)
	}
	return nil
}
