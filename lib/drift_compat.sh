#!/usr/bin/env bash
# =============================================================================
# drift_compat.sh — Backwards-compatibility shims for bash functions that
# m25 (drift/clarify port) deleted but left in-tree bash callers depending
# on.
#
# Why this file exists. m25 ported lib/drift*.sh + lib/clarify*.sh to
# internal/drift and internal/clarify and deleted the bash files. The
# port surfaced the operations via `tekhton drift <subcommand>` Cobra
# subcommands. Most callers were updated. But six callers of
# `count_open_nonblocking_notes` (formerly in lib/drift_cleanup.sh) were
# left unrewritten — stages/coder.sh:569, tekhton-legacy.sh:1668 and
# :2805, and three guarded sites in lib/finalize_display.sh +
# lib/dashboard_emitters.sh. The unguarded calls crashed every pipeline
# run with "count_open_nonblocking_notes: command not found".
#
# Rather than touch six call sites we restore the function as a thin
# shim that delegates to the Go binary. This keeps the m25 port's
# "bash files deleted" outcome intact (the original drift bash is still
# gone) while papering over the API gap until each caller migrates to
# the explicit `tekhton drift nonblocking count` form.
#
# Sourced by tekhton.sh / DefaultLibHelpers — do not run directly.
# Expects: log() warn() from common.sh (only used on failure paths).
# Provides: count_open_nonblocking_notes — drop-in for the m25-deleted
#           function. Stdout: integer count. Exit: 0 on success, 0 with
#           stdout "0" on degraded paths (binary missing, log absent).
# =============================================================================
set -euo pipefail

# count_open_nonblocking_notes — count `- [ ]` items under the `## Open`
# section of NON_BLOCKING_LOG.md. Pre-m25 this was a 12-line awk pipeline
# in lib/drift_cleanup.sh; post-m25 the same logic lives in
# internal/drift/nonblocking.go::CountOpen and is exposed as
# `tekhton drift nonblocking count`.
#
# Defensive: when the tekhton binary is unavailable (pre-build / first
# clone), echo 0 instead of failing so the caller's `nb_count=$(...)`
# stays valid. The pre-m25 bash function exhibited the same behavior
# (empty file → 0).
count_open_nonblocking_notes() {
    local _bin="${TEKHTON_BIN:-}"
    if [[ -z "$_bin" ]]; then
        if command -v tekhton >/dev/null 2>&1; then
            _bin=$(command -v tekhton)
        else
            echo "0"
            return 0
        fi
    fi
    local _proj="${PROJECT_DIR:-$PWD}"
    local _count
    if ! _count=$("$_bin" drift nonblocking count --project-dir "$_proj" 2>/dev/null); then
        echo "0"
        return 0
    fi
    # Trim whitespace defensively; Cobra adds a trailing newline that the
    # `$(...)` capture already strips, but a botched binary could emit
    # extra characters and we don't want them propagating into integer
    # comparisons.
    _count="${_count//[[:space:]]/}"
    if [[ -z "$_count" ]] || ! [[ "$_count" =~ ^[0-9]+$ ]]; then
        echo "0"
        return 0
    fi
    echo "$_count"
}
