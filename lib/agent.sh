#!/usr/bin/env bash
# =============================================================================
# agent.sh — Agent invocation wrapper with metrics tracking
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TOTAL_TURNS, TOTAL_TIME, STAGE_SUMMARY (set by caller)
# Expects: log(), success(), warn(), error() from common.sh
# =============================================================================

# --- Metrics accumulators (initialize if not already set) --------------------

: "${TOTAL_TURNS:=0}"
: "${TOTAL_TIME:=0}"
: "${STAGE_SUMMARY:=}"

# --- Run summary -------------------------------------------------------------

print_run_summary() {
    local total_mins=$(( TOTAL_TIME / 60 ))
    local total_secs=$(( TOTAL_TIME % 60 ))
    echo
    echo "══════════════════════════════════════"
    echo "  Run Summary"
    echo "══════════════════════════════════════"
    echo -e "$STAGE_SUMMARY"
    echo "  ──────────────────────────────────"
    echo "  Total turns: ${TOTAL_TURNS}"
    echo "  Total time:  ${total_mins}m${total_secs}s"
    echo "══════════════════════════════════════"
    echo
}

# =============================================================================
# AGENT INVOCATION WRAPPER
# Tracks turns used and wall-clock time for each stage
# =============================================================================

run_agent() {
    local label="$1"        # e.g. "Coder", "Reviewer", "Tester"
    local model="$2"
    local max_turns="$3"
    local prompt="$4"
    local log_file="$5"

    local start_time
    start_time=$(date +%s)

    claude \
        --model "$model" \
        --dangerously-skip-permissions \
        --max-turns "$max_turns" \
        --output-format json \
        -p "$prompt" \
        2>&1 | tee -a "$log_file" | (
            # Stream JSON lines — print text content live, capture final stats
            local turns=0
            local last_line=""
            while IFS= read -r line; do
                # Print assistant text content live
                if echo "$line" | grep -q '"type":"text"'; then
                    echo "$line" | python3 -c \
                        "import sys,json; d=json.load(sys.stdin); print(d.get('text',''))" \
                        2>/dev/null || true
                fi
                last_line="$line"
            done
            # Extract turn count from final result object
            turns=$(echo "$last_line" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns', 0))" \
                2>/dev/null || echo "0")
            echo "$turns" > "/tmp/tekhton_${PROJECT_NAME// /_}_last_turns"
        )

    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    local turns_used
    turns_used=$(cat "/tmp/tekhton_${PROJECT_NAME// /_}_last_turns" 2>/dev/null || echo "?")

    # Detect overshoot — Claude CLI's --max-turns is a soft cap
    local turns_display="${turns_used}/${max_turns}"
    if [ "$turns_used" != "?" ] && [ "$turns_used" -gt "$max_turns" ] 2>/dev/null; then
        turns_display="${turns_used}/${max_turns} (overshot by $(( turns_used - max_turns )))"
    fi

    log "[$label] Turns: ${turns_display} | Time: ${mins}m${secs}s"

    # Accumulate run totals
    TOTAL_TURNS=$(( TOTAL_TURNS + ${turns_used:-0} ))
    TOTAL_TIME=$(( TOTAL_TIME + elapsed ))

    # Store per-stage for summary
    STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label}: ${turns_display} turns, ${mins}m${secs}s"

}
