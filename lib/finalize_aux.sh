#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# finalize_aux.sh — Auxiliary finalize hooks (express persist, note
# acceptance, baseline cleanup, failure-context reset).
#
# Sourced by lib/finalize.sh — do not run directly. Hooks are kept here to
# leave finalize.sh under the 300-line ceiling. Each hook follows the
# `_hook_*` interface — first arg is the pipeline exit code; return 0 always.
# =============================================================================

# o. Express mode: persist auto-detected config on success
_hook_express_persist() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    [[ "${EXPRESS_MODE_ACTIVE:-false}" != "true" ]] && return 0

    if [[ "${EXPRESS_PERSIST_CONFIG:-true}" == "true" ]]; then
        persist_express_config "${PROJECT_DIR}"
    fi
    if [[ "${EXPRESS_PERSIST_ROLES:-false}" == "true" ]]; then
        persist_express_roles "${PROJECT_DIR}"
        log "Built-in role templates copied to .claude/agents/."
    fi
}

# o2. Note acceptance checks (M42) — before final checks
_hook_note_acceptance() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    if command -v run_note_acceptance &>/dev/null; then
        run_note_acceptance || true
    fi
}

# q. Baseline cleanup (M63) — remove stale baselines from prior runs
_hook_baseline_cleanup() {
    # shellcheck disable=SC2034  # exit_code used for hook interface
    local exit_code="$1"
    if command -v cleanup_stale_baselines &>/dev/null; then
        cleanup_stale_baselines 2>/dev/null || true
    fi
}

# r. Reset failure-cause slots on success (M129)
# Prevents stale primary/secondary slot values from leaking into a subsequent
# same-shell invocation (e.g. --auto-advance chain, multi-pass --complete).
_hook_failure_context_reset() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    if declare -f reset_failure_cause_context &>/dev/null; then
        reset_failure_cause_context
    fi
}
