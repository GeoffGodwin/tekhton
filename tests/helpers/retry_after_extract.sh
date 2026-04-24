#!/usr/bin/env bash
# =============================================================================
# tests/helpers/retry_after_extract.sh — Shared _extract_retry_after_seconds
#
# Canonical source: lib/agent_retry.sh. Duplicated here so tests don't need to
# pull in the full agent monitoring stack to exercise Retry-After parsing.
# If the canonical definition changes, update this copy in lockstep.
#
# Sourced by test files — do not run directly.
# Provides: _extract_retry_after_seconds
# =============================================================================

_extract_retry_after_seconds() {
    local session_dir="${1:-}"
    [[ -n "$session_dir" ]] || return 1
    local f secs=""
    for f in "${session_dir}/agent_last_output.txt" "${session_dir}/agent_stderr.txt"; do
        [[ -f "$f" ]] || continue
        secs=$(grep -oiE '"?retry[._-]?after"?[[:space:]]*:[[:space:]]*"?[0-9]+' "$f" 2>/dev/null \
               | grep -oE '[0-9]+' | head -1 || true)
        if [[ -z "$secs" ]]; then
            secs=$(grep -oiE 'retry[-[:space:]]+after[[:space:]]+[0-9]+' "$f" 2>/dev/null \
                   | grep -oE '[0-9]+' | head -1 || true)
        fi
        [[ -n "$secs" ]] && break
    done
    if [[ -n "$secs" ]] && [[ "$secs" =~ ^[0-9]+$ ]]; then
        echo "$secs"
        return 0
    fi
    return 1
}
