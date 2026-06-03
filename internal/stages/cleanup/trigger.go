// Package cleanup is the Go-native cleanup stage. m34.2 ports it from
// stages/cleanup.sh as the second child of the m34 stage-port arc, applying
// the pattern m34.1 established (StageImpl entry, internal/stages/<name>/
// layout, staglog helper, parity harness).
//
// The stage is success-path-only — every code path returns verdict=skip or
// verdict=pass. Verdict=fail is never returned; build-gate failure becomes
// a warning + selective revert of cleanup-touched files, not a stage
// failure, mirroring the bash semantics where every branch of
// run_stage_cleanup ends with `return 0`.
package cleanup

import (
	"github.com/geoffgodwin/tekhton/internal/notes"
)

// shouldRun ports lib/cleanup.sh::should_run_cleanup. Both trigger
// conditions must hold:
//
//  1. CLEANUP_ENABLED=true
//  2. UnresolvedCount(doc) >= CLEANUP_TRIGGER_THRESHOLD (default 5)
//
// The pipeline-level "ran on success-path" precondition is enforced by
// the runner that invokes the stage, not by this function — matching
// bash where run_stage_cleanup did not check the prior stages' verdicts.
func shouldRun(doc *notes.Document) bool {
	if !envBool("CLEANUP_ENABLED", false) {
		return false
	}
	unresolved := notes.UnresolvedCount(doc)
	threshold := envInt("CLEANUP_TRIGGER_THRESHOLD", 5)
	// Bash predicate at stages/cleanup.sh: `[ "$unresolved" -lt
	// "$threshold" ] && skip` — fires when count is AT OR ABOVE threshold,
	// not strictly greater. Originally ported as `>`, which left the
	// threshold-equal case skipping when bash would run — surfaced in
	// the m34.2 full-flow tests during the auto-advance commit recovery.
	return unresolved >= threshold
}
