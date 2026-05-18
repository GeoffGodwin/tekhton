#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# finalize.sh — m21 shim. Orchestrator + registry moved to Go
# (internal/finalize.Orchestrator). Legacy bash callers
# (lib/orchestrate_iteration.sh, lib/orchestrate_save.sh, tekhton-legacy.sh)
# still invoke `finalize_run` by name — this file keeps that name callable by
# delegating to the Go orchestrator via `tekhton finalize`.
#
# Sourced by tekhton-legacy.sh and lib/finalize_shim.sh. The Go runner never
# sources this file — it calls finalize.Orchestrator directly.
#
# The five core hook bodies that used to live here (final_checks /
# drift_artifacts / record_metrics / cleanup_resolved / resolve_notes) moved
# to lib/finalize_core_hooks.sh — sourced from here so any bash caller that
# expects the function names to be loaded after sourcing this file still
# sees them defined.
# =============================================================================

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/finalize_display.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/finalize_core_hooks.sh"

# finalize_run PIPELINE_EXIT_CODE
# Legacy entry point. Builds a minimal RunResultV1 envelope and execs
# `tekhton finalize` so the Go orchestrator drives the chain. When the Go
# binary is unavailable (developer machine without `make build`), falls back
# to a no-op with a warning — the legacy `finalize_run` body is gone and
# there is no in-bash chain to run anymore.
finalize_run() {
    local pipeline_exit_code="${1:-0}"
    local tekhton_bin="${TEKHTON_BIN:-${TEKHTON_HOME:-.}/bin/tekhton}"
    if [[ ! -x "$tekhton_bin" ]]; then
        echo "finalize_run: tekhton binary not found at ${tekhton_bin}" >&2
        echo "finalize_run: skipping finalize chain (post-m21 Go orchestrator required)" >&2
        return 0
    fi
    "$tekhton_bin" finalize \
        --exit-code "$pipeline_exit_code" \
        --project-dir "${PROJECT_DIR:-$(pwd)}" \
        --home "${TEKHTON_HOME:-$(pwd)}" \
        --milestone "${_CURRENT_MILESTONE:-}" \
        --milestone-mode "${MILESTONE_MODE:-false}" \
        --milestone-disposition "${_CACHED_DISPOSITION:-}" \
        --log-dir "${LOG_DIR:-}" \
        --timestamp "${TIMESTAMP:-}"
}
