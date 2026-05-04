#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# causality.sh — Causal event log (m02 Go-wedge shim)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: PROJECT_DIR (set by caller/config), CAUSAL_LOG_FILE (or default).
# Depends on: lib/common.sh::_json_escape  (loaded for the bash fallback only).
#
# Pre-m02 this file owned the writer in bash (~270 lines). The writer moved
# to Go in m02; this file is the wedge shim that exec's `tekhton causal …`.
# The on-disk JSONL format is unchanged — query callers (causality_query.sh,
# external tooling) continue to read the same file.
#
# Transitional bash fallback. When the `tekhton` binary is not on $PATH
# (test sandboxes, fresh clones before `make build`), the shim falls back to
# an inline bash writer that produces the same `causal.event.v1` lines. Once
# the binary is universally installed (m04 Phase-1 hardening), the fallback
# can be deleted.
#
# Provides:
#   init_causal_log     — set _CURRENT_RUN_ID, ensure dirs (no fork)
#   emit_event          — Go writer or bash fallback, returns event ID
#   _last_event_id      — read most-recent ID from log file
#   archive_causal_log  — Go writer or bash fallback
# =============================================================================

# --- Module-level state -------------------------------------------------------

_CURRENT_RUN_ID=""             # Set at init_causal_log(), read by query layer.
_CAUSAL_SEQ_DIR=""    # Bash-fallback per-stage counter directory.

# --- Initialization -----------------------------------------------------------

# init_causal_log
# Sets _CURRENT_RUN_ID and ensures the log + archive directories exist.
# Does NOT truncate the log — resumed runs append.
init_causal_log() {
    : "${CAUSAL_LOG_ENABLED:=true}"
    : "${CAUSAL_LOG_FILE:=${PROJECT_DIR:-.}/.claude/logs/CAUSAL_LOG.jsonl}"
    : "${CAUSAL_LOG_MAX_EVENTS:=2000}"

    _CURRENT_RUN_ID="run_${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"

    _CAUSAL_SEQ_DIR="${TEKHTON_SESSION_DIR:-/tmp}/causal_seq_$$"
    rm -rf "$_CAUSAL_SEQ_DIR" 2>/dev/null || true
    mkdir -p "$_CAUSAL_SEQ_DIR" 2>/dev/null || true

    [[ "${CAUSAL_LOG_ENABLED}" != "true" ]] && return 0

    local log_dir
    log_dir="$(dirname "$CAUSAL_LOG_FILE")"
    mkdir -p "$log_dir" "${log_dir}/runs" 2>/dev/null || true
}

# --- Event emission -----------------------------------------------------------

# emit_event TYPE STAGE DETAIL CAUSED_BY VERDICT CONTEXT
# Args mirror the pre-m02 bash function exactly so callers don't change.
# CAUSED_BY is a comma-separated list of upstream IDs (or empty).
# VERDICT / CONTEXT are pre-formatted JSON literals or empty (→ null).
# Prints the assigned event ID on stdout.
emit_event() {
    local type="${1:-unknown}" stage="${2:-pipeline}" detail="${3:-}"
    local caused_by="${4:-}" verdict="${5:-}" context="${6:-}"

    if [[ "${CAUSAL_LOG_ENABLED:-true}" != "true" ]]; then
        # Disabled mode: fallback to per-stage seq using the same bash counter
        # so multiple emits within a single test still get monotonic IDs.
        _causal_fallback_next_id "$stage"
        return 0
    fi

    : "${CAUSAL_LOG_FILE:=${PROJECT_DIR:-.}/.claude/logs/CAUSAL_LOG.jsonl}"
    : "${CAUSAL_LOG_MAX_EVENTS:=2000}"

    if command -v tekhton >/dev/null 2>&1; then
        local -a args=(
            causal emit
            --path "$CAUSAL_LOG_FILE"
            --cap "$CAUSAL_LOG_MAX_EVENTS"
            --run-id "${_CURRENT_RUN_ID:-}"
            --stage "$stage"
            --type "$type"
        )
        [[ -n "$detail" ]] && args+=(--detail "$detail")
        [[ -n "${_CURRENT_MILESTONE:-}" ]] && args+=(--milestone "$_CURRENT_MILESTONE")
        [[ -n "$verdict" ]] && args+=(--verdict "$verdict")
        [[ -n "$context" ]] && args+=(--context "$context")
        if [[ -n "$caused_by" ]]; then
            local cid IFS=','
            for cid in $caused_by; do
                cid="${cid## }"; cid="${cid%% }"
                [[ -n "$cid" ]] && args+=(--caused-by "$cid")
            done
        fi
        tekhton "${args[@]}"
        return 0
    fi

    _causal_bash_fallback_emit "$type" "$stage" "$detail" "$caused_by" "$verdict" "$context"
}

# --- ID readback --------------------------------------------------------------

# _last_event_id
# Returns the most-recent event ID seen in the on-disk log.
_last_event_id() {
    : "${CAUSAL_LOG_FILE:=${PROJECT_DIR:-.}/.claude/logs/CAUSAL_LOG.jsonl}"
    [[ ! -f "$CAUSAL_LOG_FILE" ]] && return 0
    if command -v tekhton >/dev/null 2>&1; then
        tekhton causal status --path "$CAUSAL_LOG_FILE" 2>/dev/null || true
        return 0
    fi
    # Fallback: parse the last id field directly.
    tail -n 1 "$CAUSAL_LOG_FILE" 2>/dev/null | grep -oE '"id":"[^"]+"' | head -1 | sed 's/"id":"//; s/"$//'
}

# --- Log lifecycle ------------------------------------------------------------

# archive_causal_log
# Copy current log to runs/ archive and prune old archives.
archive_causal_log() {
    [[ "${CAUSAL_LOG_ENABLED:-true}" != "true" ]] && return 0
    : "${CAUSAL_LOG_FILE:=${PROJECT_DIR:-.}/.claude/logs/CAUSAL_LOG.jsonl}"
    [[ ! -f "$CAUSAL_LOG_FILE" ]] && return 0
    : "${CAUSAL_LOG_RETENTION_RUNS:=50}"

    if command -v tekhton >/dev/null 2>&1; then
        tekhton causal archive \
            --path "$CAUSAL_LOG_FILE" \
            --run-id "${_CURRENT_RUN_ID:-}" \
            --retention "$CAUSAL_LOG_RETENTION_RUNS" \
            2>/dev/null || true
        return 0
    fi

    local runs_dir
    runs_dir="$(dirname "$CAUSAL_LOG_FILE")/runs"
    mkdir -p "$runs_dir" 2>/dev/null || true
    cp "$CAUSAL_LOG_FILE" "${runs_dir}/CAUSAL_LOG_${_CURRENT_RUN_ID}.jsonl"
    _causal_fallback_prune_archives "$runs_dir" "$CAUSAL_LOG_RETENTION_RUNS"
}

# =============================================================================
# Bash fallback — used only when `tekhton` binary is not on PATH.
# Format matches the Go writer's `causal.event.v1` line byte-for-byte.
# =============================================================================

_causal_fallback_next_id() {
    local stage="$1"
    local seq_file="${_CAUSAL_SEQ_DIR:-/tmp}/${stage}"
    local seq=0
    [[ -f "$seq_file" ]] && seq=$(cat "$seq_file" 2>/dev/null || echo 0)
    seq=$(( seq + 1 ))
    echo "$seq" > "$seq_file" 2>/dev/null || true
    printf '%s.%03d' "$stage" "$seq"
}

_causal_bash_fallback_emit() {
    local type="$1" stage="$2" detail="$3" caused_by="$4" verdict="$5" context="$6"
    local event_id ts cb_json="[]" v_json="null" ctx_json="null"
    event_id="$(_causal_fallback_next_id "$stage")"
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

    if [[ -n "$caused_by" ]]; then
        cb_json="["
        local first=true cid IFS=','
        for cid in $caused_by; do
            cid="${cid## }"; cid="${cid%% }"
            [[ -z "$cid" ]] && continue
            if $first; then first=false; else cb_json="${cb_json},"; fi
            cb_json="${cb_json}\"$(_json_escape "$cid")\""
        done
        cb_json="${cb_json}]"
    fi
    [[ -n "$verdict" ]] && v_json="$verdict"
    [[ -n "$context" ]] && ctx_json="$context"

    printf '{"proto":"tekhton.causal.v1","id":"%s","ts":"%s","run_id":"%s","milestone":"%s","type":"%s","stage":"%s","detail":"%s","caused_by":%s,"verdict":%s,"context":%s}\n' \
        "$(_json_escape "$event_id")" "$ts" \
        "$(_json_escape "${_CURRENT_RUN_ID:-}")" \
        "$(_json_escape "${_CURRENT_MILESTONE:-}")" \
        "$(_json_escape "$type")" "$(_json_escape "$stage")" \
        "$(_json_escape "$detail")" "$cb_json" "$v_json" "$ctx_json" \
        >> "$CAUSAL_LOG_FILE"

    _causal_fallback_evict
    printf '%s' "$event_id"
}

_causal_fallback_evict() {
    [[ ! -f "$CAUSAL_LOG_FILE" ]] && return 0
    local total
    total=$(wc -l < "$CAUSAL_LOG_FILE" 2>/dev/null || echo 0)
    total="${total##* }"
    [[ "$total" -le "$CAUSAL_LOG_MAX_EVENTS" ]] && return 0
    local to_remove=$(( total - CAUSAL_LOG_MAX_EVENTS ))
    local tmp="${CAUSAL_LOG_FILE}.tmp.$$"
    tail -n +"$(( to_remove + 1 ))" "$CAUSAL_LOG_FILE" > "$tmp"
    mv "$tmp" "$CAUSAL_LOG_FILE"
}

_causal_fallback_prune_archives() {
    local runs_dir="$1" retention="$2"
    [[ "$retention" -le 0 ]] && return 0
    local count=0 archive
    while IFS= read -r archive; do
        count=$(( count + 1 ))
        if [[ "$count" -gt "$retention" ]]; then
            rm -f "$archive" 2>/dev/null || true
        fi
    done < <(ls -t "$runs_dir"/CAUSAL_LOG_*.jsonl 2>/dev/null || true)
}
