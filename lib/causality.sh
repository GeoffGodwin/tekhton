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
#   trace_cause_chain      — walk caused_by edges backward
#   trace_effect_chain     — walk forward to find descendants
#   events_for_milestone   — filter events by milestone ID
#   events_by_type         — return events of a type across runs
#   recurring_pattern      — count event type across archived logs
#   verdict_history        — extract verdict events for a stage
#   cause_chain_summary    — human-readable one-line causal chain
#   archive_causal_log     — copy log to runs/ and prune old archives
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

# --- Query functions ----------------------------------------------------------

# trace_cause_chain EVENT_ID
# Walk caused_by edges backward, printing ancestor events as JSON lines.
trace_cause_chain() {
    local target_id="$1"
    [[ ! -f "$CAUSAL_LOG_FILE" ]] && return 0

    # Build an associative array of id → line for fast lookup
    local -A id_map=()
    local -A caused_by_map=()
    while IFS= read -r line; do
        local eid
        eid=$(printf '%s' "$line" | grep -oP '"id"\s*:\s*"\K[^"]+' 2>/dev/null || true)
        [[ -z "$eid" ]] && continue
        id_map[$eid]="$line"
        local cbs
        cbs=$(printf '%s' "$line" | grep -oP '"caused_by"\s*:\s*\[\K[^\]]*' 2>/dev/null || true)
        caused_by_map[$eid]="$cbs"
    done < "$CAUSAL_LOG_FILE"

    # Walk backward from target
    local -A visited=()
    local queue="$target_id"
    while [[ -n "$queue" ]]; do
        local current="${queue%%$'\n'*}"
        queue="${queue#"$current"}"
        queue="${queue#$'\n'}"

        [[ -n "${visited[$current]:-}" ]] && continue
        visited[$current]=1

        if [[ -n "${id_map[$current]:-}" ]] && [[ "$current" != "$target_id" ]]; then
            echo "${id_map[$current]}"
        fi

        # Parse caused_by for this event
        local cbs="${caused_by_map[$current]:-}"
        if [[ -n "$cbs" ]]; then
            # Extract quoted IDs
            local IFS=','
            for cb_entry in $cbs; do
                local cb_id
                cb_id=$(printf '%s' "$cb_entry" | tr -d ' "')
                if [[ -n "$cb_id" ]] && [[ -z "${visited[$cb_id]:-}" ]]; then
                    queue="${queue:+${queue}$'\n'}${cb_id}"
                fi
            done
        fi
    done
}

# trace_effect_chain EVENT_ID
# Walk forward: find all events whose caused_by contains this ID.
trace_effect_chain() {
    local target_id="$1"
    [[ ! -f "$CAUSAL_LOG_FILE" ]] && return 0

    local -A visited=()
    local queue="$target_id"
    while [[ -n "$queue" ]]; do
        local current="${queue%%$'\n'*}"
        queue="${queue#"$current"}"
        queue="${queue#$'\n'}"

        [[ -n "${visited[$current]:-}" ]] && continue
        visited[$current]=1

        # Find all events that have current in their caused_by
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local eid
            eid=$(printf '%s' "$line" | grep -oP '"id"\s*:\s*"\K[^"]+' 2>/dev/null || true)
            [[ -z "$eid" ]] && continue
            [[ -n "${visited[$eid]:-}" ]] && continue
            if [[ "$current" != "$target_id" ]] || [[ "$eid" != "$target_id" ]]; then
                echo "$line"
            fi
            queue="${queue:+${queue}$'\n'}${eid}"
        done < <(grep -F "\"$current\"" "$CAUSAL_LOG_FILE" 2>/dev/null || true)
    done
}

# events_for_milestone MILESTONE_ID [RUN_ID]
# Filter events by milestone field.
events_for_milestone() {
    local milestone_id="$1"
    local run_id="${2:-$_CURRENT_RUN_ID}"

    [[ ! -f "$CAUSAL_LOG_FILE" ]] && return 0
    grep "\"milestone\":\"${milestone_id}\"" "$CAUSAL_LOG_FILE" 2>/dev/null \
        | grep "\"run_id\":\"${run_id}\"" 2>/dev/null || true
}

# events_by_type EVENT_TYPE [LOOKBACK_RUNS]
# Return events of a given type across the last N archived runs.
events_by_type() {
    local event_type="$1"
    local lookback="${2:-10}"

    local runs_dir
    runs_dir="$(dirname "$CAUSAL_LOG_FILE")/runs"

    # Current run first
    if [[ -f "$CAUSAL_LOG_FILE" ]]; then
        grep "\"type\":\"${event_type}\"" "$CAUSAL_LOG_FILE" 2>/dev/null || true
    fi

    # Archived runs (most recent first)
    if [[ -d "$runs_dir" ]]; then
        local count=0
        while IFS= read -r archive; do
            [[ "$count" -ge "$lookback" ]] && break
            grep "\"type\":\"${event_type}\"" "$archive" 2>/dev/null || true
            count=$(( count + 1 ))
        done < <(ls -t "$runs_dir"/CAUSAL_LOG_*.jsonl 2>/dev/null || true)
    fi
}

# recurring_pattern EVENT_TYPE LOOKBACK_RUNS
# Count occurrences of an event type across runs.
# Outputs: COUNT RUN_ID1 RUN_ID2 ...
recurring_pattern() {
    local event_type="$1"
    local lookback="${2:-10}"

    local total=0
    local run_ids=""
    local runs_dir
    runs_dir="$(dirname "$CAUSAL_LOG_FILE")/runs"

    if [[ -d "$runs_dir" ]]; then
        local count=0
        while IFS= read -r archive; do
            [[ "$count" -ge "$lookback" ]] && break
            local hits
            hits=$(grep -c "\"type\":\"${event_type}\"" "$archive" 2>/dev/null || echo "0")
            hits="${hits//[!0-9]/}"
            : "${hits:=0}"
            if [[ "$hits" -gt 0 ]]; then
                total=$(( total + hits ))
                local rid
                rid=$(grep -m1 -oP '"run_id"\s*:\s*"\K[^"]+' "$archive" 2>/dev/null || true)
                run_ids="${run_ids:+${run_ids} }${rid}"
            fi
            count=$(( count + 1 ))
        done < <(ls -t "$runs_dir"/CAUSAL_LOG_*.jsonl 2>/dev/null || true)
    fi

    echo "${total} ${run_ids}"
}

# verdict_history STAGE LOOKBACK_RUNS
# Extract verdict events for a stage across recent runs.
verdict_history() {
    local stage="$1"
    local lookback="${2:-10}"

    events_by_type "verdict" "$lookback" \
        | grep "\"stage\":\"${stage}\"" 2>/dev/null || true
}

# cause_chain_summary EVENT_ID
# Produce a human-readable one-line causal chain.
# Example: "build_gate.FAIL ← coder.stage_end ← scout.stage_end"
cause_chain_summary() {
    local event_id="$1"
    [[ ! -f "$CAUSAL_LOG_FILE" ]] && { echo "$event_id"; return 0; }

    local chain="$event_id"
    local current="$event_id"
    local depth=0
    local max_depth=20

    while [[ "$depth" -lt "$max_depth" ]]; do
        local line
        line=$(grep "\"id\":\"${current}\"" "$CAUSAL_LOG_FILE" 2>/dev/null | head -1 || true)
        [[ -z "$line" ]] && break

        local cbs
        cbs=$(printf '%s' "$line" | grep -oP '"caused_by"\s*:\s*\[\K[^\]]*' 2>/dev/null || true)
        [[ -z "$cbs" ]] && break

        # Take first cause
        local first_cause
        first_cause=$(printf '%s' "$cbs" | tr ',' '\n' | head -1 | tr -d ' "')
        [[ -z "$first_cause" ]] && break

        # Get type of the cause event for readable summary
        local cause_line
        cause_line=$(grep "\"id\":\"${first_cause}\"" "$CAUSAL_LOG_FILE" 2>/dev/null | head -1 || true)
        local cause_type=""
        if [[ -n "$cause_line" ]]; then
            cause_type=$(printf '%s' "$cause_line" | grep -oP '"type"\s*:\s*"\K[^"]+' 2>/dev/null || true)
        fi

        chain="${chain} <- ${first_cause}${cause_type:+.${cause_type}}"
        current="$first_cause"
        depth=$(( depth + 1 ))
    done

    echo "$chain"
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
