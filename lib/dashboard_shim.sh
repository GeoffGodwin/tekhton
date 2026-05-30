#!/usr/bin/env bash
# =============================================================================
# dashboard_shim.sh — bash compatibility shims that exec the Go dashboard
# subsystem (m33.1).
#
# Replaces the deleted lib/dashboard.sh + lib/dashboard_emitters.sh. Every
# function name the legacy bash callers know about is preserved; the bodies
# now exec `tekhton dashboard <subcommand>` so the canonical implementation
# lives in internal/dashboard.
#
# The new call sites in lib/finalize_dashboard_hooks.sh exec the Go binary
# directly per m33.1 AC; this file exists for the other bash callers
# (tekhton-legacy.sh, lib/agent_spinner.sh, lib/dry_run.sh,
# lib/finalize_shim.sh, lib/diagnose_output_extra.sh) which still use the
# original function names.
#
# Sourced by tekhton.sh (via tekhton-legacy.sh) — do not run directly.
# Expects: PROJECT_DIR, TEKHTON_HOME (set by caller/config)
#
# m33.2: the bash parsers (lib/dashboard_parsers*.sh) are gone; the Go
# StatusReader behind `tekhton dashboard parse <kind>` is the canonical
# read side. This shim retains only the enable check + emit-side delegators.
# =============================================================================
set -euo pipefail

# --- Enable check (still bash for `set -u` safety in legacy callers) ---------

is_dashboard_enabled() {
    [[ "${DASHBOARD_ENABLED:-true}" = "true" ]]
}

# _dashboard_bin — locates the tekhton binary or returns nonzero. Callers
# silently no-op when the binary is absent so this file stays usable in
# build-from-source / no-binary-yet workflows.
_dashboard_bin() {
    local bin="${TEKHTON_BIN:-${TEKHTON_HOME:-.}/bin/tekhton}"
    [[ -x "$bin" ]] || return 1
    printf '%s' "$bin"
}

# _dashboard_exec KIND
# Common shim body: exec `tekhton dashboard emit <kind>`. Silently no-ops
# when the Go binary is absent (same fail-closed shape the bash form had).
_dashboard_exec() {
    local kind="$1"
    local bin
    bin=$(_dashboard_bin) || return 0
    "$bin" dashboard emit "$kind" --project-dir "${PROJECT_DIR:-.}" 2>/dev/null || true
}

# --- Lifecycle shims ---------------------------------------------------------

init_dashboard() {
    local bin
    bin=$(_dashboard_bin) || return 0
    "$bin" dashboard init --project-dir "${1:-${PROJECT_DIR:-.}}" 2>/dev/null || true
}

sync_dashboard_static_files() {
    local bin
    bin=$(_dashboard_bin) || return 0
    "$bin" dashboard sync --project-dir "${1:-${PROJECT_DIR:-.}}" 2>/dev/null || true
}

cleanup_dashboard() {
    local bin
    bin=$(_dashboard_bin) || return 0
    "$bin" dashboard cleanup --project-dir "${1:-${PROJECT_DIR:-.}}" 2>/dev/null || true
}

# --- Per-kind emit shims -----------------------------------------------------

emit_dashboard_run_state()     { _dashboard_exec run-state; }
emit_dashboard_timeline()      { _dashboard_exec timeline; }
# Pre-m33.1 internal name some tests still reference.
_regenerate_timeline_js()      { _dashboard_exec timeline; }
emit_dashboard_milestones()    { _dashboard_exec milestones; }
emit_dashboard_security()      { _dashboard_exec security; }
emit_dashboard_reports()       { _dashboard_exec reports; }
emit_dashboard_metrics()       { _dashboard_exec metrics; }
emit_dashboard_health()        { _dashboard_exec health; }
emit_dashboard_init()          { _dashboard_exec init; }
emit_dashboard_inbox()         { _dashboard_exec inbox; }
emit_dashboard_action_items()  { _dashboard_exec action-items; }
emit_dashboard_notes()         { _dashboard_exec notes; }
emit_draft_milestones_data()   { _dashboard_exec draft-milestones; }

# emit_dashboard_team_state TEAM_ID
# Parallel-mode hook. The Go side serializes the _TEAM_* env state into
# the team payload during run-state emit, so this just delegates.
emit_dashboard_team_state() {
    [[ -n "${1:-}" ]] || { warn "emit_dashboard_team_state: team_id required" 2>/dev/null || true; return 1; }
    _dashboard_exec run-state
}
