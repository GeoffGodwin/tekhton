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

# consolidate_legacy_human_action — fold a stale root-level
# HUMAN_ACTION_REQUIRED.md into the canonical .tekhton/ location.
# Pre-m25 this was a multi-step awk/sed routine in lib/drift_artifacts.sh;
# post-m25 the same logic lives in internal/drift/artifacts.go::
# (*HumanAction).ConsolidateLegacy and is exposed as
# `tekhton drift human-action consolidate-legacy`.
#
# Called by tekhton-legacy.sh:2271 during startup cleanup BEFORE any
# agent runs. The legacy file may not exist (most projects), in which
# case the Go side returns 0 with no error — we just swallow stdout
# and continue. Defensive on missing binary so a `--fix nb` invocation
# on a brownfield project without the binary on PATH still proceeds
# (the legacy file merge is best-effort, not load-bearing).
consolidate_legacy_human_action() {
    local _bin="${TEKHTON_BIN:-}"
    if [[ -z "$_bin" ]]; then
        if command -v tekhton >/dev/null 2>&1; then
            _bin=$(command -v tekhton)
        else
            return 0
        fi
    fi
    local _proj="${PROJECT_DIR:-$PWD}"
    "$_bin" drift human-action consolidate-legacy \
        --project-dir "$_proj" >/dev/null 2>&1 || true
}

# _drift_compat_resolve_bin — common binary lookup for the cleanup shims.
# Echoes the resolved path or empty on failure; callers should `return 0`
# silently when empty (the cleanup ops are best-effort startup tidying).
_drift_compat_resolve_bin() {
    local b="${TEKHTON_BIN:-}"
    if [[ -z "$b" ]] && command -v tekhton >/dev/null 2>&1; then
        b=$(command -v tekhton)
    fi
    [[ -x "$b" ]] && echo "$b"
}

# clear_completed_nonblocking_notes — move `- [x]` items from the Open
# section into the Resolved section of NON_BLOCKING_LOG.md. Pre-m25 lived
# in lib/drift_cleanup.sh; post-m25 the logic is in
# internal/drift/nonblocking.go::(*NonBlocking).ClearCompleted.
# Called by tekhton-legacy.sh:2272 during startup cleanup. Best-effort
# (silently no-ops if the binary is unavailable).
clear_completed_nonblocking_notes() {
    local _bin
    _bin=$(_drift_compat_resolve_bin) || true
    [[ -z "$_bin" ]] && return 0
    "$_bin" drift nonblocking clear-completed \
        --project-dir "${PROJECT_DIR:-$PWD}" >/dev/null 2>&1 || true
}

# clear_resolved_nonblocking_notes — empty the ## Resolved section of
# NON_BLOCKING_LOG.md. Post-m25 logic lives in
# internal/drift/nonblocking.go::(*NonBlocking).ClearResolved.
# Called by tekhton-legacy.sh:2284. Best-effort.
clear_resolved_nonblocking_notes() {
    local _bin
    _bin=$(_drift_compat_resolve_bin) || true
    [[ -z "$_bin" ]] && return 0
    "$_bin" drift nonblocking clear-resolved \
        --project-dir "${PROJECT_DIR:-$PWD}" >/dev/null 2>&1 || true
}

# clear_resolved_drift_observations — empty the ## Resolved section of
# DRIFT_LOG.md. Post-m25 logic lives in
# internal/drift/observe.go::(*Log).ClearResolved.
# Called by tekhton-legacy.sh:2273. Best-effort.
clear_resolved_drift_observations() {
    local _bin
    _bin=$(_drift_compat_resolve_bin) || true
    [[ -z "$_bin" ]] && return 0
    "$_bin" drift clear-resolved-observations \
        --project-dir "${PROJECT_DIR:-$PWD}" >/dev/null 2>&1 || true
}

# count_drift_observations — count unresolved entries in DRIFT_LOG.md's
# ## Observations section. Post-m25 the logic is in
# internal/drift/observe.go::(*Log).CountUnresolved and is exposed as
# `tekhton drift count` (which already existed; only the bash shim is new).
# Called by tekhton-legacy.sh:1721, :2101, :2934 and lib/finalize_display.sh:96.
# Echoes a numeric count; defensive fallback to 0 when the binary is missing
# or returns garbage, matching the pre-m25 behavior on an empty/absent file.
# get_open_nonblocking_notes — echo the full body of every unchecked
# (- [ ]) item under the ## Open section of NON_BLOCKING_LOG.md, one
# entry per line. Pre-m25 this was a bash awk pipeline in
# lib/drift_cleanup.sh; post-m25 the logic lives in
# internal/drift/nonblocking.go::(*NonBlocking).GetOpen and is exposed
# as `tekhton drift nonblocking list`. Called by stages/coder.sh:572
# during --fix-nonblockers runs to build the agent's note-context block.
# Defensive: missing binary or unparseable output → empty (the caller
# treats empty as "no notes" which is the safe fallback).
get_open_nonblocking_notes() {
    local _bin
    _bin=$(_drift_compat_resolve_bin) || true
    [[ -z "$_bin" ]] && return 0
    "$_bin" drift nonblocking list \
        --project-dir "${PROJECT_DIR:-$PWD}" 2>/dev/null || true
}

count_drift_observations() {
    local _bin
    _bin=$(_drift_compat_resolve_bin) || true
    if [[ -z "$_bin" ]]; then
        echo "0"
        return 0
    fi
    local _count
    if ! _count=$("$_bin" drift count --project-dir "${PROJECT_DIR:-$PWD}" 2>/dev/null); then
        echo "0"
        return 0
    fi
    _count="${_count//[[:space:]]/}"
    if [[ -z "$_count" ]] || ! [[ "$_count" =~ ^[0-9]+$ ]]; then
        echo "0"
        return 0
    fi
    echo "$_count"
}

# _drift_compat_audit_status_field FIELD
# Internal helper: runs `tekhton drift audit-status` with the current
# DRIFT_OBSERVATION_THRESHOLD / DRIFT_RUNS_SINCE_AUDIT_THRESHOLD, then
# extracts the requested JSON field by line-matching (no jq dependency).
# The Go encoder emits one indented key:value per line, so a simple
# grep + sed is sufficient. Echoes the field value verbatim; empty on
# any failure path.
_drift_compat_audit_status_field() {
    local field="$1"
    local _bin
    _bin=$(_drift_compat_resolve_bin) || true
    [[ -z "$_bin" ]] && return 0
    local _obs_thr="${DRIFT_OBSERVATION_THRESHOLD:-8}"
    local _runs_thr="${DRIFT_RUNS_SINCE_AUDIT_THRESHOLD:-5}"
    local _out
    _out=$("$_bin" drift audit-status \
        --project-dir "${PROJECT_DIR:-$PWD}" \
        --obs-threshold "$_obs_thr" \
        --runs-threshold "$_runs_thr" 2>/dev/null) || return 0
    # Lines look like:    "should_trigger_audit": true,
    # or                  "runs_since_audit": 3,
    printf '%s\n' "$_out" \
        | grep -F "\"${field}\":" \
        | head -1 \
        | sed -E 's/.*:\s*//;s/,\s*$//;s/^"//;s/"$//' \
        | tr -d '[:space:]'
}

# should_trigger_audit — Returns 0 (true) when either the unresolved
# observation count or the runs-since-audit counter is at/above its
# configured threshold. Pre-m25 this was a bash function in
# lib/drift_artifacts.sh; post-m25 the logic lives in
# internal/drift/observe.go::(*Log).ShouldTriggerAudit and is exposed
# as the boolean field on `tekhton drift audit-status`.
#
# Called by tekhton-legacy.sh:2446 in the pre-coder architect-trigger
# block: `if [ "$FORCE_AUDIT" = true ] || should_trigger_audit; then`.
# Without this shim the architect never auto-triggers from drift
# thresholds in normal runs — only forced runs (--force-audit, --fix
# drift) reach the architect, so observations accumulate untouched.
should_trigger_audit() {
    local _v
    _v=$(_drift_compat_audit_status_field should_trigger_audit)
    [[ "$_v" == "true" ]]
}

# get_runs_since_audit — Echoes the integer runs-since-audit counter
# stored in DRIFT_LOG.md's HTML metadata comment. Pre-m25 lived in
# lib/drift_artifacts.sh; post-m25 the logic is in
# internal/drift/observe.go::(*Log).GetRunsSinceAudit. Defensive
# fallback to 0 when the binary or counter is unavailable.
get_runs_since_audit() {
    local _v
    _v=$(_drift_compat_audit_status_field runs_since_audit)
    [[ "$_v" =~ ^[0-9]+$ ]] || _v=0
    echo "$_v"
}

# get_resolved_drift_observations — Prints every entry under DRIFT_LOG.md's
# ## Resolved section, one entry per line. Pre-m25 was an awk pipeline
# in lib/drift_artifacts.sh; post-m25 ports to
# internal/drift/observe.go::(*Log).GetResolved and is exposed as
# `tekhton drift resolved-entries`. Used by lib/hooks.sh:248 when
# building the finalize commit-message banner. Best-effort: missing
# binary → empty output, the caller treats empty as "no resolved
# items to mention."
get_resolved_drift_observations() {
    local _bin
    _bin=$(_drift_compat_resolve_bin) || true
    [[ -z "$_bin" ]] && return 0
    "$_bin" drift resolved-entries \
        --project-dir "${PROJECT_DIR:-$PWD}" 2>/dev/null || true
}
