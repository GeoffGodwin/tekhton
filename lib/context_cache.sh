#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# context_cache.sh — Intra-run context cache (Milestone 47)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: _safe_read_file(), _wrap_file_content() from prompts.sh
#          log(), warn() from common.sh
#          load_clarifications_content() from clarify.sh
#          extract_human_notes(), should_claim_notes() from notes.sh
#          build_milestone_window() from milestone_window.sh
#          _phase_start(), _phase_end() from common.sh
#
# Provides:
#   preload_context_cache   — read shared context files once at startup
#   invalidate_drift_cache  — clear drift log cache (after review appends)
#   invalidate_milestone_cache — clear milestone window cache (after advance)
#
# DESIGN NOTES (vs. spec §1-2):
# ------
# Spec §1 lists _CACHED_HUMAN_NOTES_BLOCK as a cache target. NOT implemented
# because human notes filtering is lightweight (grep + pattern matching) and
# called once per stage. Caching the filtered block would require either:
#   (a) Pre-computing with unknown filters (stage-specific claiming patterns vary)
#   (b) Invalidating after each stage (defeats the purpose of persistent cache)
# Instead, stages call extract_human_notes() directly with explicit arguments,
# making the data flow transparent and avoiding implicit cache coupling.
#
# Spec §2 proposes modifying render_prompt() to check for _CACHED_* before disk
# reads. IMPLEMENTATION CHOSEN: Explicit _get_cached_*() accessor functions
# called by stages, with fallback to disk reads in planning mode. Rationale:
# (1) Avoids implicit state in a shared template function
# (2) Makes cache invalidation explicit: invalidate_drift_cache() called after
#     review appends, preventing stale reads
# (3) Easier to reason about: cache semantics are localized, not hidden in
#     render_prompt() side effects
# This approach is superior to the implicit approach and is documented in each
# stage's comment block where cache getters are used.
# =============================================================================

# Sentinel value distinguishing "cache loaded but file was empty/missing"
# from "cache not yet initialized". An empty string means the file was
# legitimately absent; _CONTEXT_CACHE_LOADED tracks initialization state.
_CONTEXT_CACHE_LOADED="false"
export _CONTEXT_CACHE_LOADED

# preload_context_cache — Reads shared context files into _CACHED_* variables.
# Call once after config load and startup cleanup. Subsequent stages use the
# cached values instead of re-reading from disk.
#
# Cached variables (all exported):
#   _CACHED_ARCHITECTURE_CONTENT — wrapped architecture file content
#   _CACHED_ARCHITECTURE_RAW     — raw (unwrapped) architecture file content
#   _CACHED_DRIFT_LOG_CONTENT    — wrapped drift log content
#   _CACHED_CLARIFICATIONS_CONTENT — clarifications file content
#   _CACHED_ARCHITECTURE_LOG_CONTENT — wrapped architecture log content
#   _CACHED_MILESTONE_BLOCK      — computed milestone window block
preload_context_cache() {
    _phase_start "context_cache_preload"

    # --- Architecture file ---
    export _CACHED_ARCHITECTURE_CONTENT=""
    export _CACHED_ARCHITECTURE_RAW=""
    if [[ -f "${ARCHITECTURE_FILE:-}" ]]; then
        local _raw
        _raw=$(_safe_read_file "${ARCHITECTURE_FILE}" "ARCHITECTURE_FILE")
        if [[ -n "$_raw" ]]; then
            _CACHED_ARCHITECTURE_RAW="$_raw"
            _CACHED_ARCHITECTURE_CONTENT=$(_wrap_file_content "ARCHITECTURE" "$_raw")
        fi
    fi

    # --- Drift log ---
    export _CACHED_DRIFT_LOG_CONTENT=""
    local _drift_file="${DRIFT_LOG_FILE:-}"
    if [[ -f "$_drift_file" ]]; then
        local _drift_raw
        _drift_raw=$(_safe_read_file "$_drift_file" "DRIFT_LOG")
        if [[ -n "$_drift_raw" ]]; then
            _CACHED_DRIFT_LOG_CONTENT=$(_wrap_file_content "DRIFT_LOG" "$_drift_raw")
        fi
    fi

    # --- Clarifications ---
    export _CACHED_CLARIFICATIONS_CONTENT=""
    local _clarify_file="${CLARIFICATIONS_FILE:-}"
    if [[ -f "$_clarify_file" ]] && [[ -s "$_clarify_file" ]]; then
        _CACHED_CLARIFICATIONS_CONTENT=$(_safe_read_file "$_clarify_file" "CLARIFICATIONS")
    fi

    # --- Architecture decision log ---
    export _CACHED_ARCHITECTURE_LOG_CONTENT=""
    local _adl_file="${ARCHITECTURE_LOG_FILE:-}"
    if [[ -f "$_adl_file" ]]; then
        local _adl_raw
        _adl_raw=$(_safe_read_file "$_adl_file" "ARCHITECTURE_LOG")
        if [[ -n "$_adl_raw" ]]; then
            _CACHED_ARCHITECTURE_LOG_CONTENT=$(_wrap_file_content "ARCHITECTURE_LOG" "$_adl_raw")
        fi
    fi

    # --- Milestone window (computed once, cleared on milestone advance) ---
    export _CACHED_MILESTONE_BLOCK=""
    if [[ "${MILESTONE_MODE:-false}" == true ]] \
       && [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f build_milestone_window &>/dev/null \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest 2>/dev/null; then
        # Use CLAUDE_CODER_MODEL as representative model for budget calc
        local _cache_model="${CLAUDE_CODER_MODEL:-${CLAUDE_STANDARD_MODEL:-sonnet}}"
        if build_milestone_window "$_cache_model" 2>/dev/null; then
            _CACHED_MILESTONE_BLOCK="${MILESTONE_BLOCK:-}"
        fi
    fi

    _CONTEXT_CACHE_LOADED="true"
    export _CONTEXT_CACHE_LOADED

    _phase_end "context_cache_preload"
    log_verbose "[context-cache] Preloaded context cache (arch=${#_CACHED_ARCHITECTURE_CONTENT}, drift=${#_CACHED_DRIFT_LOG_CONTENT}, clarify=${#_CACHED_CLARIFICATIONS_CONTENT}, adl=${#_CACHED_ARCHITECTURE_LOG_CONTENT}, milestone=${#_CACHED_MILESTONE_BLOCK})"
}

# invalidate_drift_cache — Clears cached drift log content.
# Call after the review stage appends new drift observations to ${DRIFT_LOG_FILE}.
invalidate_drift_cache() {
    _CACHED_DRIFT_LOG_CONTENT=""
    export _CACHED_DRIFT_LOG_CONTENT
    log_verbose "[context-cache] Drift log cache invalidated"
}

# invalidate_milestone_cache — Clears cached milestone window.
# Call after mark_milestone_done() to force recomputation for the next milestone.
invalidate_milestone_cache() {
    _CACHED_MILESTONE_BLOCK=""
    export _CACHED_MILESTONE_BLOCK
    log_verbose "[context-cache] Milestone window cache invalidated"
}

# _get_cached_architecture_content — Returns wrapped architecture content.
# Uses cache if available, otherwise reads from disk (fallback for planning mode).
_get_cached_architecture_content() {
    if [[ "${_CONTEXT_CACHE_LOADED:-false}" == "true" ]]; then
        echo "$_CACHED_ARCHITECTURE_CONTENT"
    elif [[ -f "${ARCHITECTURE_FILE:-}" ]]; then
        local _raw
        _raw=$(_safe_read_file "${ARCHITECTURE_FILE}" "ARCHITECTURE_FILE")
        if [[ -n "$_raw" ]]; then
            _wrap_file_content "ARCHITECTURE" "$_raw"
        fi
    fi
}

# _get_cached_architecture_raw — Returns raw (unwrapped) architecture content.
# Used by coder stage for ARCHITECTURE_BLOCK construction.
_get_cached_architecture_raw() {
    if [[ "${_CONTEXT_CACHE_LOADED:-false}" == "true" ]]; then
        echo "$_CACHED_ARCHITECTURE_RAW"
    elif [[ -f "${ARCHITECTURE_FILE:-}" ]]; then
        _safe_read_file "${ARCHITECTURE_FILE}" "ARCHITECTURE_FILE"
    fi
}

# _get_cached_drift_log_content — Returns wrapped drift log content.
# Note: Unlike other accessors, this checks -n (non-empty) in addition to
# _CONTEXT_CACHE_LOADED. This is because invalidate_drift_cache() clears the
# cached value mid-run (after review appends observations), so an empty string
# with cache loaded means "invalidated, re-read from disk" — not "file was empty".
_get_cached_drift_log_content() {
    if [[ "${_CONTEXT_CACHE_LOADED:-false}" == "true" ]] && [[ -n "$_CACHED_DRIFT_LOG_CONTENT" ]]; then
        echo "$_CACHED_DRIFT_LOG_CONTENT"
    elif [[ -f "${DRIFT_LOG_FILE:-}" ]]; then
        local _raw
        _raw=$(_safe_read_file "${DRIFT_LOG_FILE:-}" "DRIFT_LOG")
        if [[ -n "$_raw" ]]; then
            _wrap_file_content "DRIFT_LOG" "$_raw"
        fi
    fi
}

# _get_cached_clarifications_content — Returns clarifications content.
_get_cached_clarifications_content() {
    if [[ "${_CONTEXT_CACHE_LOADED:-false}" == "true" ]]; then
        echo "$_CACHED_CLARIFICATIONS_CONTENT"
    else
        local _file="${CLARIFICATIONS_FILE:-}"
        if [[ -f "$_file" ]] && [[ -s "$_file" ]]; then
            _safe_read_file "$_file" "CLARIFICATIONS"
        fi
    fi
}

# _get_cached_architecture_log_content — Returns wrapped architecture log content.
_get_cached_architecture_log_content() {
    if [[ "${_CONTEXT_CACHE_LOADED:-false}" == "true" ]]; then
        echo "$_CACHED_ARCHITECTURE_LOG_CONTENT"
    elif [[ -f "${ARCHITECTURE_LOG_FILE:-}" ]]; then
        local _raw
        _raw=$(_safe_read_file "${ARCHITECTURE_LOG_FILE:-}" "ARCHITECTURE_LOG")
        if [[ -n "$_raw" ]]; then
            _wrap_file_content "ARCHITECTURE_LOG" "$_raw"
        fi
    fi
}

# _get_cached_milestone_block — Returns milestone window block.
# Uses cache if available, otherwise computes fresh.
_get_cached_milestone_block() {
    local model="${1:-${CLAUDE_CODER_MODEL:-${CLAUDE_STANDARD_MODEL:-sonnet}}}"
    if [[ "${_CONTEXT_CACHE_LOADED:-false}" == "true" ]] && [[ -n "$_CACHED_MILESTONE_BLOCK" ]]; then
        MILESTONE_BLOCK="$_CACHED_MILESTONE_BLOCK"
        export MILESTONE_BLOCK
        return 0
    fi
    # Fallback: compute fresh
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f build_milestone_window &>/dev/null \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest 2>/dev/null; then
        build_milestone_window "$model" || return 1
        return 0
    fi
    return 1
}
