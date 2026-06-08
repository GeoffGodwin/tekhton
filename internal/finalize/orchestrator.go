package finalize

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

// hookOrder is the authoritative registration order — must mirror
// lib/finalize.sh:218-243 byte-for-byte. Tests assert this list cannot
// be reordered without an accompanying bash-side update.
//
// Several hooks have implicit ordering dependencies that aren't obvious
// from names:
//   - _hook_resolve_notes must run before _hook_archive_reports
//     (archive moves the notes file out of the working dir).
//   - _hook_emit_run_summary reads state that _hook_clear_state would
//     erase if reordered ahead of it.
//   - _hook_commit reads _CACHED_DISPOSITION populated by Run() before
//     the chain enters _hook_clear_state.
//
// Treat lib/finalize.sh as authoritative. Do not "optimize" the order.
var hookOrder = []string{
	"_hook_baseline_cleanup",
	"_hook_note_acceptance",
	"_hook_final_checks",
	"_hook_drift_artifacts",
	"_hook_record_metrics",
	"_hook_causal_log_finalize",
	// m25 follow-up: re-instates the bash _resolve_addressed_nonblocking_notes
	// pass that lib/drift_cleanup.sh used to own. Without it,
	// `tekhton --fix nb` never transitions [ ] → [x] post-coder, so each
	// pass net-adds notes (reviewer adds new ones; nothing resolves the
	// addressed ones). MUST run before _hook_cleanup_resolved, which
	// sweeps the [x] entries this hook produces.
	"_hook_resolve_addressed_nonblocking",
	// Drift parallel to the nonblocking hook above: ticks `[ ]` → `[x]`
	// on drift observations whose body names a coder-modified file, then
	// sweeps every `- [x]` entry into the Resolved section. Lets the
	// drift log carry the same checkbox semantics as NON_BLOCKING_LOG.md
	// (architect or coder can self-tick; this hook catches misses).
	"_hook_resolve_addressed_drift",
	"_hook_cleanup_resolved",
	"_hook_resolve_notes",
	// m25: clarify cleanup runs just before archive_reports so the
	// stale CLARIFICATIONS.md file is gone before the archive sweep
	// captures it. The hook is gated on pipeline success; failure
	// preserves the file so the next run can resume.
	"_hook_clarify_finalize",
	"_hook_archive_reports",
	"_hook_health_reassess",
	"_hook_emit_run_summary",
	"_hook_emit_run_memory",
	"_hook_emit_timing_report",
	"_hook_failure_context",
	"_hook_express_persist",
	"_hook_project_version_bump",
	"_hook_changelog_append",
	"_hook_commit",
	// "Completion bookkeeping" hooks — mark_done / cleanup_milestone /
	// clear_state — run AFTER _hook_commit and are gated by the
	// `.tekhton/.commit_decision` sentinel that _hook_commit writes.
	// Pre-2026-05 these ran before _hook_commit, which meant declining
	// the interactive commit prompt (or a crash between mark_done and
	// commit) left the manifest in a "done" state with no commit to
	// back it up — the next `tekhton --milestone m23` then produced a
	// no-op coder run because m23 was already "done." Moving them
	// after commit + sentinel-gating them ensures milestone state
	// changes only persist when the user actually committed the work.
	"_hook_mark_done",
	"_hook_cleanup_milestone",
	"_hook_clear_state",
	"_hook_project_version_tag",
	"_hook_update_check",
	"_hook_final_dashboard_status",
	"_hook_tui_complete",
	"_hook_failure_context_reset",
}

// HookOrder returns the canonical hook registration order. Exported so the
// order-mismatch test and external tooling (parity gate) can compare against
// the bash side.
func HookOrder() []string {
	out := make([]string, len(hookOrder))
	copy(out, hookOrder)
	return out
}

// goNativeHooks is the set of hook names implemented as pure-Go bodies in
// internal/finalize/. Every other hook in hookOrder is invoked through the
// bash shim dispatcher. Follow-up milestones (m22..m25) move names out of
// the shim dispatcher and onto this list as their underlying bash
// subsystems port. m21 landed eight pure-Go bodies; m23 added TUI
// complete; m24 added the six notes-touching bodies.
var goNativeHooks = map[string]func() Hook{
	"_hook_clear_state":         func() Hook { return &ClearState{} },
	"_hook_archive_reports":     func() Hook { return &ArchiveReports{} },
	"_hook_mark_done":           func() Hook { return &MarkDone{} },
	"_hook_cleanup_milestone":   func() Hook { return &CleanupMilestone{} },
	"_hook_emit_run_memory":     func() Hook { return &EmitRunMemory{} },
	"_hook_emit_run_summary":    func() Hook { return &EmitRunSummary{} },
	"_hook_emit_timing_report":  func() Hook { return &EmitTimingReport{} },
	"_hook_causal_log_finalize": func() Hook { return &CausalLogFinalize{} },
	// m23: TUI complete hook ported to Go alongside the TUI writer subsystem.
	"_hook_tui_complete": func() Hook { return &TUIComplete{} },
	// m24: notes subsystem ported to Go. Three pure-Go bodies (notes-only
	// work) and three Go bodies that delegate the cross-subsystem work
	// (test_baseline, express, failure_context) to narrow bash invocations
	// until those subsystems port in their own milestones. The bash case
	// arm in lib/finalize_shim.sh for these six hooks is removed.
	"_hook_baseline_cleanup":       func() Hook { return &BaselineCleanup{} },
	"_hook_express_persist":        func() Hook { return &ExpressPersist{} },
	"_hook_note_acceptance":        func() Hook { return &NoteAcceptance{} },
	"_hook_failure_context_reset":  func() Hook { return &FailureContextReset{} },
	"_hook_resolve_addressed_nonblocking": func() Hook { return &ResolveAddressedNonblocking{} },
	"_hook_resolve_addressed_drift":       func() Hook { return &ResolveAddressedDrift{} },
	"_hook_cleanup_resolved":              func() Hook { return &CleanupResolved{} },
	"_hook_resolve_notes":                 func() Hook { return &ResolveNotes{} },
	// m25: drift subsystem ported to Go. The drift_artifacts hook
	// runs pure-Go now; the new clarify_finalize hook clears stale
	// CLARIFICATIONS.md on success. failure_context_reset already
	// existed (m24) but now uses the in-process Context.Reset
	// rather than shelling out to lib/failure_context.sh.
	"_hook_drift_artifacts":   func() Hook { return &DriftArtifacts{} },
	"_hook_clarify_finalize":  func() Hook { return &ClarifyFinalize{} },
}

// Orchestrator owns the hook registry and the run loop. Constructed by
// NewOrchestrator with the bash shim invoker wired up; tests construct it
// directly with fakes substituted into the hooks slice.
type Orchestrator struct {
	hooks []Hook
	log   io.Writer
	now   func() time.Time
}

// NewOrchestrator builds an Orchestrator with the canonical 26-hook
// registration. Pure-Go hooks come from goNativeHooks; every other name
// becomes a BashShimHook that execs lib/finalize_shim.sh.
func NewOrchestrator(tekhtonHome, projectDir string) *Orchestrator {
	o := &Orchestrator{
		log: os.Stderr,
		now: time.Now,
	}
	o.hooks = make([]Hook, 0, len(hookOrder))
	for _, name := range hookOrder {
		if ctor, ok := goNativeHooks[name]; ok {
			o.hooks = append(o.hooks, ctor())
			continue
		}
		o.hooks = append(o.hooks, &BashShimHook{
			HookName:    name,
			TekhtonHome: tekhtonHome,
			ProjectDir:  projectDir,
		})
	}
	return o
}

// SetLog overrides the log destination — defaults to os.Stderr.
func (o *Orchestrator) SetLog(w io.Writer) { o.log = w }

// SetNow overrides the clock — defaults to time.Now. Tests use this to pin
// duration measurements.
func (o *Orchestrator) SetNow(now func() time.Time) {
	if now != nil {
		o.now = now
	}
}

// Hooks returns the registered hooks in execution order. Mostly used by
// tests; in production the chain is driven through Run.
func (o *Orchestrator) Hooks() []Hook { return o.hooks }

// Run executes every registered hook in order against the same Input. Hook
// errors are logged but never abort the chain — this mirrors the bash
// finalize_run loop, where each hook is responsible for its own
// warnings/skips and the chain never short-circuits.
func (o *Orchestrator) Run(ctx context.Context, in *Input) Summary {
	if in.Log == nil {
		in.Log = o.log
	}
	// m50 — Mark the finalize chain as active. Pre-commit guards (in both
	// bash lib/finalize_commit.sh::_check_manifest_write_guard and the Go
	// observability defense in cmd/tekhton/run.go) consult this sentinel
	// to allow MANIFEST.cfg writes that legitimately come from
	// _hook_mark_done. Cleared in the deferred tail so a panic mid-finalize
	// doesn't poison subsequent runs by leaving the sentinel set and
	// silently legitimizing a rogue stage-time commit.
	if cleanup := writeFinalizeActiveSentinel(in); cleanup != nil {
		defer cleanup()
	}
	start := o.now()
	sum := Summary{Hooks: make([]HookResult, 0, len(o.hooks))}
	for _, h := range o.hooks {
		hookStart := o.now()
		err := h.Run(ctx, in)
		dur := o.now().Sub(hookStart)
		sum.Hooks = append(sum.Hooks, HookResult{
			Name:     h.Name(),
			Duration: dur,
			Err:      err,
		})
		if err != nil {
			fmt.Fprintf(o.log, "finalize: hook %q failed (continuing): %v\n", h.Name(), err)
		}
	}
	sum.Duration = o.now().Sub(start)
	return sum
}

// writeFinalizeActiveSentinel writes the .tekhton/.finalize_active sentinel
// at the top of Orchestrator.Run and returns a cleanup closure that removes
// it (callers wire the closure into defer so a panic mid-finalize doesn't
// strand the sentinel). The sentinel marks the active window during which
// MANIFEST.cfg writes are legitimate; the bash pre-commit guard in
// lib/finalize_commit.sh and the Go-side defense in cmd/tekhton/run.go
// consult it to distinguish finalize-initiated commits from stage-initiated
// commits (the m48 / 51aff09 incident class).
//
// Returns nil when ProjectDir is empty — that's the debug-subcommand case
// where there's no on-disk repo to write to. Non-fatal failures are logged
// to in.Log and the function still returns a cleanup closure so the deferred
// remove still runs (no-op if the file never landed).
func writeFinalizeActiveSentinel(in *Input) func() {
	if in == nil || in.ProjectDir == "" {
		return nil
	}
	sentinelPath := filepath.Join(in.ProjectDir, ".tekhton", ".finalize_active")
	if err := os.MkdirAll(filepath.Dir(sentinelPath), 0o755); err != nil {
		if in.Log != nil {
			fmt.Fprintf(in.Log, "finalize: warning: mkdir %s: %v\n", filepath.Dir(sentinelPath), err)
		}
		return nil
	}
	payload := in.Timestamp
	if payload == "" {
		payload = "active"
	}
	if err := os.WriteFile(sentinelPath, []byte(payload+"\n"), 0o644); err != nil {
		if in.Log != nil {
			fmt.Fprintf(in.Log, "finalize: warning: write %s: %v\n", sentinelPath, err)
		}
		return nil
	}
	return func() {
		_ = os.Remove(sentinelPath)
	}
}
