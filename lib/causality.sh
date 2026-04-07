#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# causality.sh — Causal event log infrastructure
#
# Sourced by tekhton.sh — do not run directly.
# Expects: PROJECT_DIR, LOG_DIR (set by caller/config)
#
# Provides:
#   init_causal_log        — initialize event log for a new run
#   emit_event             — append a JSON event, return its ID
#   _next_event_id         — monotonic per-stage counter
#   _last_event_id         — most recently emitted event ID
#   _evict_oldest_events   — enforce the per-run event cap
#   archive_causal_log     — copy log to runs/ and prune old archives
#   _prune_causal_archives — remove archived logs beyond retention limit
#
# Query functions live in causality_query.sh (sourced independently).
# =============================================================================

# --- Module-level state -------------------------------------------------------

_LAST_EVENT_ID=""              # Most recently emitted event ID
_CURRENT_RUN_ID=""             # Set at init_causal_log()
_CAUSAL_EVENT_COUNT=0          # Events emitted this run
_CAUSAL_SEQ_DIR=""             # Directory for file-based per-stage counters

# --- JSON escape helper (shared with dashboard_parsers.sh) -------------------

# _json_escape STRING
# Escapes backslash, double-quote, newline, tab, and carriage return for JSON.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# --- Initialization -----------------------------------------------------------

# init_causal_log
# Sets _CURRENT_RUN_ID and ensures the log directory exists.
# If resuming (CAUSAL_LOG.jsonl already has events for this run), appends.
# Otherwise creates a fresh log.
init_causal_log() {
    : "${CAUSAL_LOG_ENABLED:=true}"
    : "${CAUSAL_LOG_FILE:=${PROJECT_DIR:-.}/.claude/logs/CAUSAL_LOG.jsonl}"
    : "${CAUSAL_LOG_MAX_EVENTS:=2000}"

    _CURRENT_RUN_ID="run_${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
    _CAUSAL_EVENT_COUNT=0
    _LAST_EVENT_ID=""

    # File-based per-stage counters survive subshell boundaries ($() capture)
    _CAUSAL_SEQ_DIR="${TEKHTON_SESSION_DIR:-/tmp}/causal_seq_$$"
    rm -rf "$_CAUSAL_SEQ_DIR" 2>/dev/null || true
    mkdir -p "$_CAUSAL_SEQ_DIR"

    if [[ "${CAUSAL_LOG_ENABLED}" != "true" ]]; then
        return 0
    fi

    local log_dir
    log_dir="$(dirname "$CAUSAL_LOG_FILE")"
    mkdir -p "$log_dir" 2>/dev/null || true

    # Create runs archive directory
    mkdir -p "${log_dir}/runs" 2>/dev/null || true
}

# --- Event emission -----------------------------------------------------------

# emit_event TYPE STAGE DETAIL CAUSED_BY VERDICT CONTEXT
# Appends a JSON line to the causal log. Returns the assigned event ID on stdout.
# CAUSED_BY: comma-separated list of event IDs (or empty string).
# VERDICT: JSON string or empty.
# CONTEXT: JSON string or empty.
emit_event() {
    local type="${1:-unknown}"
    local stage="${2:-pipeline}"
    local detail="${3:-}"
    local caused_by="${4:-}"
    local verdict="${5:-}"
    local context="${6:-}"

    # When disabled, return synthetic IDs so callers can thread causality
    if [[ "${CAUSAL_LOG_ENABLED:-true}" != "true" ]]; then
        local synth_id
        synth_id="$(_next_event_id "$stage")"
        _LAST_EVENT_ID="$synth_id"
        echo "$synth_id" > "${_CAUSAL_SEQ_DIR}/last_id" 2>/dev/null || true
        printf '%s' "$synth_id"
        return 0
    fi

    local event_id
    event_id="$(_next_event_id "$stage")"
    _LAST_EVENT_ID="$event_id"
    echo "$event_id" > "${_CAUSAL_SEQ_DIR}/last_id" 2>/dev/null || true

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

    local milestone="${_CURRENT_MILESTONE:-}"

    # Build caused_by JSON array
    local cb_json="[]"
    if [[ -n "$caused_by" ]]; then
        cb_json="["
        local first=true
        local IFS=','
        for cid in $caused_by; do
            cid="${cid## }"  # trim leading space
            cid="${cid%% }"  # trim trailing space
            if [[ -n "$cid" ]]; then
                if [[ "$first" = true ]]; then
                    first=false
                else
                    cb_json="${cb_json},"
                fi
                cb_json="${cb_json}\"$(_json_escape "$cid")\""
            fi
        done
        cb_json="${cb_json}]"
    fi

    # Build verdict field
    local v_json="null"
    if [[ -n "$verdict" ]]; then
        v_json="$verdict"
    fi

    # Build context field
    local ctx_json="null"
    if [[ -n "$context" ]]; then
        ctx_json="$context"
    fi

    # Escape string fields
    local esc_detail
    esc_detail="$(_json_escape "$detail")"
    local esc_stage
    esc_stage="$(_json_escape "$stage")"
    local esc_type
    esc_type="$(_json_escape "$type")"

    # Compose JSON line
    local json_line
    json_line=$(printf '{"id":"%s","ts":"%s","run_id":"%s","milestone":"%s","type":"%s","stage":"%s","detail":"%s","caused_by":%s,"verdict":%s,"context":%s}' \
        "$(_json_escape "$event_id")" \
        "$ts" \
        "$(_json_escape "$_CURRENT_RUN_ID")" \
        "$(_json_escape "$milestone")" \
        "$esc_type" \
        "$esc_stage" \
        "$esc_detail" \
        "$cb_json" \
        "$v_json" \
        "$ctx_json")

    # Append to log (atomic for single-process bash)
    echo "$json_line" >> "$CAUSAL_LOG_FILE"

    # Track event count via file (survives subshell) and enforce cap
    local _ec=0
    if [[ -f "${_CAUSAL_SEQ_DIR}/event_count" ]]; then
        _ec=$(cat "${_CAUSAL_SEQ_DIR}/event_count" 2>/dev/null || echo "0")
    fi
    _ec=$(( _ec + 1 ))
    echo "$_ec" > "${_CAUSAL_SEQ_DIR}/event_count"
    _CAUSAL_EVENT_COUNT="$_ec"
    if [[ "$_ec" -gt "$CAUSAL_LOG_MAX_EVENTS" ]]; then
        _evict_oldest_events
    fi

    printf '%s' "$event_id"
}

# --- ID management ------------------------------------------------------------

# _next_event_id STAGE
# Returns stage.NNN using file-based per-stage monotonic counter.
# File-based counters survive $() subshell boundaries (critical because
# emit_event is typically called as: eid=$(emit_event ...)).
_next_event_id() {
    local stage="${1:-pipeline}"
    local seq_file="${_CAUSAL_SEQ_DIR}/${stage}"
    local seq=0
    if [[ -f "$seq_file" ]]; then
        seq=$(cat "$seq_file" 2>/dev/null || echo "0")
    fi
    seq=$(( seq + 1 ))
    echo "$seq" > "$seq_file"
    printf '%s.%03d' "$stage" "$seq"
}

# _last_event_id
# Returns the most recently emitted event ID.
# Reads from file to survive subshell boundaries.
_last_event_id() {
    if [[ -f "${_CAUSAL_SEQ_DIR}/last_id" ]]; then
        cat "${_CAUSAL_SEQ_DIR}/last_id" 2>/dev/null || printf '%s' "$_LAST_EVENT_ID"
    else
        printf '%s' "$_LAST_EVENT_ID"
    fi
}

# --- Event cap enforcement ----------------------------------------------------

# _evict_oldest_events
# Removes oldest events from the current run's log to stay under the cap.
# Keeps the most recent events (most diagnostically useful).
_evict_oldest_events() {
    [[ ! -f "$CAUSAL_LOG_FILE" ]] && return 0

    local total
    total=$(wc -l < "$CAUSAL_LOG_FILE" 2>/dev/null || echo "0")
    total="${total##* }"  # strip whitespace

    if [[ "$total" -le "$CAUSAL_LOG_MAX_EVENTS" ]]; then
        return 0
    fi

    local to_remove=$(( total - CAUSAL_LOG_MAX_EVENTS ))
    local tmpfile="${CAUSAL_LOG_FILE}.tmp.$$"
    tail -n +"$(( to_remove + 1 ))" "$CAUSAL_LOG_FILE" > "$tmpfile"
    mv "$tmpfile" "$CAUSAL_LOG_FILE"
}

# --- Log lifecycle ------------------------------------------------------------

# archive_causal_log
# Copy current log to runs/ archive and prune old archives.
archive_causal_log() {
    [[ "${CAUSAL_LOG_ENABLED:-true}" != "true" ]] && return 0
    [[ ! -f "$CAUSAL_LOG_FILE" ]] && return 0

    local runs_dir
    runs_dir="$(dirname "$CAUSAL_LOG_FILE")/runs"
    mkdir -p "$runs_dir" 2>/dev/null || true

    local archive_file="${runs_dir}/CAUSAL_LOG_${_CURRENT_RUN_ID}.jsonl"
    cp "$CAUSAL_LOG_FILE" "$archive_file"

    # Prune old archives beyond retention limit
    _prune_causal_archives
}

# _prune_causal_archives
# Remove archived logs beyond CAUSAL_LOG_RETENTION_RUNS.
_prune_causal_archives() {
    : "${CAUSAL_LOG_RETENTION_RUNS:=50}"
    local runs_dir
    runs_dir="$(dirname "$CAUSAL_LOG_FILE")/runs"
    [[ ! -d "$runs_dir" ]] && return 0

    local count=0
    while IFS= read -r archive; do
        count=$(( count + 1 ))
        if [[ "$count" -gt "$CAUSAL_LOG_RETENTION_RUNS" ]]; then
            rm -f "$archive" 2>/dev/null || true
        fi
    done < <(ls -t "$runs_dir"/CAUSAL_LOG_*.jsonl 2>/dev/null || true)
}
