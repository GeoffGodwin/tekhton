package finalize

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/drift"
)

// ResolveAddressedDrift is the drift parallel to
// ResolveAddressedNonblocking. It does two things in sequence:
//
//  1. Heuristic resolution: tick `[ ]` → `[x]` on any unresolved drift
//     observation whose body mentions a file the coder declared in
//     CODER_SUMMARY.md's "## Files Modified" section. Mirrors the
//     nonblocking hook so a coder run that fixes the code underlying
//     an observation gets credit even without the agent self-ticking.
//
//  2. Sweep: move every `- [x] ...` entry out of Unresolved Observations
//     into the Resolved section. The architect-driven path (where the
//     agent self-ticks observations during its review) and the coder-
//     driven path (heuristic above) both produce `[x]` entries; this
//     sweep handles both uniformly so the on-disk format converges to
//     the nonblocking shape.
//
// Gates on pipeline success (ExitCode == 0). Runs before
// _hook_cleanup_resolved so the swept entries land in `## Resolved`
// before the startup-cleanup sweep on the NEXT run wipes them — keeps
// one cycle of resolved entries visible for inspection.
type ResolveAddressedDrift struct{}

// Name implements Hook.
func (h *ResolveAddressedDrift) Name() string {
	return "_hook_resolve_addressed_drift"
}

// Run executes the hook. Failures are logged but do not abort the
// chain (continue-on-error contract).
func (h *ResolveAddressedDrift) Run(_ context.Context, in *Input) error {
	if in.ExitCode != 0 {
		return nil
	}
	driftPath := driftLogPath(in)
	if driftPath == "" {
		return nil
	}
	l := drift.NewLog(driftPath)

	files, err := readCoderSummaryFiles(in)
	if err != nil {
		fmt.Fprintf(logWriter(in), "resolve_addressed_drift: read coder summary: %v\n", err)
		// Don't bail — the architect-ticked entries still want a sweep.
		files = nil
	}
	if len(files) > 0 {
		ticked, err := l.ResolveByModifiedFiles(files)
		if err != nil {
			fmt.Fprintf(logWriter(in), "resolve_addressed_drift: heuristic tick: %v\n", err)
		} else if ticked > 0 {
			fmt.Fprintf(logWriter(in),
				"resolve_addressed_drift: ticked %d drift observation(s) by modified-files heuristic\n",
				ticked)
		}
	}

	moved, err := l.MoveTickedToResolved()
	if err != nil {
		fmt.Fprintf(logWriter(in), "resolve_addressed_drift: sweep: %v\n", err)
		return nil
	}
	if moved > 0 {
		fmt.Fprintf(logWriter(in),
			"resolve_addressed_drift: moved %d ticked observation(s) into the Resolved section\n",
			moved)
	}
	return nil
}

// driftLogPath resolves DRIFT_LOG.md the same way the cleanup_resolved
// hook resolves NON_BLOCKING_LOG.md. Returns the empty string when
// the file is not present so callers can no-op cleanly.
func driftLogPath(in *Input) string {
	override := envValue(in, "DRIFT_LOG_FILE")
	if override == "" {
		override = filepath.Join(".tekhton", "DRIFT_LOG.md")
	}
	var path string
	if filepath.IsAbs(override) {
		path = override
	} else {
		path = filepath.Join(in.ProjectDir, override)
	}
	if _, err := os.Stat(path); err != nil {
		return ""
	}
	return path
}
