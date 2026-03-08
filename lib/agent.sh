#!/usr/bin/env bash
# =============================================================================
# agent.sh — Agent invocation wrapper with metrics tracking + exit detection
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TOTAL_TURNS, TOTAL_TIME, STAGE_SUMMARY (set by caller)
# Expects: log(), success(), warn(), error() from common.sh
# =============================================================================

# --- Metrics accumulators (initialize if not already set) --------------------

: "${TOTAL_TURNS:=0}"
: "${TOTAL_TIME:=0}"
: "${STAGE_SUMMARY:=}"

# --- Agent exit detection globals --------------------------------------------
# Set after every run_agent() call. Callers inspect these to decide next steps.

LAST_AGENT_TURNS=0         # Turns the agent actually used
LAST_AGENT_EXIT_CODE=0     # claude CLI exit code
LAST_AGENT_ELAPSED=0       # Wall-clock seconds
LAST_AGENT_NULL_RUN=false  # true if agent likely died without doing work

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

    # Temporarily disable pipefail — claude can exit non-zero on turn limits
    # and we don't want that to kill the entire tekhton pipeline
    set +o pipefail
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
    local agent_exit=${PIPESTATUS[0]}
    set -o pipefail

    if [ "$agent_exit" -ne 0 ]; then
        warn "[$label] claude exited with code ${agent_exit} (may indicate turn limit or error)"
    fi

    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    local turns_used
    turns_used=$(cat "/tmp/tekhton_${PROJECT_NAME// /_}_last_turns" 2>/dev/null || echo "0")
    [[ "$turns_used" =~ ^[0-9]+$ ]] || turns_used=0

    # Detect overshoot — Claude CLI's --max-turns is a soft cap
    local turns_display="${turns_used}/${max_turns}"
    if [ "$turns_used" -gt "$max_turns" ] 2>/dev/null; then
        turns_display="${turns_used}/${max_turns} (overshot by $(( turns_used - max_turns )))"
    fi

    log "[$label] Turns: ${turns_display} | Time: ${mins}m${secs}s"

    # Accumulate run totals
    TOTAL_TURNS=$(( TOTAL_TURNS + turns_used ))
    TOTAL_TIME=$(( TOTAL_TIME + elapsed ))

    # Store per-stage for summary
    STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label}: ${turns_display} turns, ${mins}m${secs}s"

    # --- Agent exit detection ------------------------------------------------
    # Populate LAST_AGENT_* globals so callers can check for null runs.

    LAST_AGENT_TURNS="$turns_used"
    LAST_AGENT_EXIT_CODE="$agent_exit"
    LAST_AGENT_ELAPSED="$elapsed"
    LAST_AGENT_NULL_RUN=false

    # Null run heuristic: agent used very few turns (≤2) OR exited non-zero
    # with zero turns. This typically means it died during discovery/search.
    local null_threshold="${AGENT_NULL_RUN_THRESHOLD:-2}"
    if [ "$turns_used" -le "$null_threshold" ] && [ "$agent_exit" -ne 0 ]; then
        LAST_AGENT_NULL_RUN=true
        warn "[$label] NULL RUN DETECTED — agent used ${turns_used} turn(s) and exited ${agent_exit}."
        warn "[$label] The agent likely died during initial discovery/file search."
    elif [ "$turns_used" -eq 0 ]; then
        LAST_AGENT_NULL_RUN=true
        warn "[$label] NULL RUN DETECTED — agent used 0 turns."
    fi
}

# =============================================================================
# NULL RUN DETECTION HELPERS
# Call these after run_agent() to check if the agent accomplished anything.
# =============================================================================

# was_null_run — returns 0 (true) if the last agent invocation was a null run.
# A null run is one where the agent died before accomplishing meaningful work.
was_null_run() {
    [ "$LAST_AGENT_NULL_RUN" = true ]
}

# check_agent_output — verifies an agent produced its expected output file and
# made git changes. Returns 0 if the agent produced meaningful work.
#
# Usage:  check_agent_output "CODER_SUMMARY.md" "Coder"
# Returns: 0 if output file exists AND (git has changes OR output file has content)
#          1 if null run or no meaningful output
check_agent_output() {
    local expected_file="$1"
    local label="$2"

    # If the agent was already flagged as a null run, fail immediately
    if was_null_run; then
        warn "[$label] Agent was a null run — no output expected."
        return 1
    fi

    # Check for expected output file
    if [ ! -f "$expected_file" ]; then
        warn "[$label] Expected output file '${expected_file}' not found."
        return 1
    fi

    # Check if the file has meaningful content (more than just a header)
    local line_count
    line_count=$(wc -l < "$expected_file" | tr -d '[:space:]')
    if [ "$line_count" -lt 3 ]; then
        warn "[$label] Output file '${expected_file}' has only ${line_count} line(s) — likely a stub."
        return 1
    fi

    # Check for git changes (the agent might have produced a report but changed no code)
    local has_changes=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        has_changes=true
    fi

    if [ "$has_changes" = false ] && [ "$line_count" -lt 5 ]; then
        warn "[$label] No git changes and minimal output — agent may not have accomplished anything."
        return 1
    fi

    return 0
}
