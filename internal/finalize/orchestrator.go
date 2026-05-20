package finalize

import (
	"context"
	"fmt"
	"io"
	"os"
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
	"_hook_cleanup_resolved",
	"_hook_resolve_notes",
	"_hook_archive_reports",
	"_hook_mark_done",
	"_hook_cleanup_milestone",
	"_hook_clear_state",
	"_hook_health_reassess",
	"_hook_emit_run_summary",
	"_hook_emit_run_memory",
	"_hook_emit_timing_report",
	"_hook_failure_context",
	"_hook_express_persist",
	"_hook_project_version_bump",
	"_hook_changelog_append",
	"_hook_commit",
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
// subsystems port. m21 lands eight pure-Go bodies; eighteen hooks remain
// in bash behind the shim.
var goNativeHooks = map[string]func() Hook{
	"_hook_clear_state":         func() Hook { return &ClearState{} },
	"_hook_archive_reports":     func() Hook { return &ArchiveReports{} },
	"_hook_mark_done":           func() Hook { return &MarkDone{} },
	"_hook_cleanup_milestone":   func() Hook { return &CleanupMilestone{} },
	"_hook_emit_run_memory":     func() Hook { return &EmitRunMemory{} },
	"_hook_emit_run_summary":    func() Hook { return &EmitRunSummary{} },
	"_hook_emit_timing_report":  func() Hook { return &EmitTimingReport{} },
	"_hook_causal_log_finalize": func() Hook { return &CausalLogFinalize{} },
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
