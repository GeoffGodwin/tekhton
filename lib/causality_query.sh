#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# causality_query.sh — Causal event log query layer
#
# Sourced by tekhton.sh — do not run directly.
# Expects: CAUSAL_LOG_FILE, _CURRENT_RUN_ID (set by causality.sh / caller)
#
# Provides:
#   trace_cause_chain    — walk caused_by edges backward from an event
#   trace_effect_chain   — walk forward to find descendant events
#   events_for_milestone — filter events by milestone ID
#   events_by_type       — return events of a type across runs
#   recurring_pattern    — count event type across archived logs
#   verdict_history      — extract verdict events for a stage
#   cause_chain_summary  — human-readable one-line causal chain
# =============================================================================

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
# Note: Uses grep -F broad string match on the event ID. This may produce
# false positives if an event's detail field contains the ID string (e.g.,
# "error near coder.001" would match as an effect of coder.001). Acceptable
# for the primary use case (diagnostic exploration) but not for precise queries.
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
