#!/usr/bin/env bash
# =============================================================================
# turns.sh — Dynamic turn limit estimation
#
# Sourced by tekhton.sh — do not run directly.
# Expects: DYNAMIC_TURNS_ENABLED, *_MIN_TURNS, *_MAX_TURNS_CAP (from config.sh)
# Expects: CODER_MAX_TURNS, REVIEWER_MAX_TURNS, TESTER_MAX_TURNS (from config.sh)
# Expects: log(), warn() from common.sh
#
# Provides:
#   parse_scout_complexity  — read SCOUT_REPORT.md complexity section
#   apply_scout_turn_limits — set ADJUSTED_*_TURNS from scout recommendation
#   estimate_review_turns   — estimate reviewer turns from coder output
#   estimate_tester_turns   — estimate tester turns from coder output
#   clamp_turns             — clamp a value to [min, max]
# =============================================================================

# --- Clamp helper ------------------------------------------------------------

# clamp_turns VALUE MIN MAX — returns VALUE clamped to [MIN, MAX]
clamp_turns() {
    local value="$1" min="$2" max="$3"
    if [ "$value" -lt "$min" ] 2>/dev/null; then
        echo "$min"
    elif [ "$value" -gt "$max" ] 2>/dev/null; then
        echo "$max"
    else
        echo "$value"
    fi
}

# --- Parse scout complexity estimate -----------------------------------------

# Reads SCOUT_REPORT.md and extracts complexity fields into global variables.
# Sets: SCOUT_FILES_TO_MODIFY, SCOUT_LINES_OF_CHANGE, SCOUT_INTERCONNECTED,
#       SCOUT_REC_CODER_TURNS, SCOUT_REC_REVIEWER_TURNS, SCOUT_REC_TESTER_TURNS
# Returns 0 if complexity section was found and parsed, 1 otherwise.
parse_scout_complexity() {
    local report="${1:-SCOUT_REPORT.md}"

    SCOUT_FILES_TO_MODIFY=0
    SCOUT_LINES_OF_CHANGE=0
    SCOUT_INTERCONNECTED="unknown"
    SCOUT_REC_CODER_TURNS=0
    SCOUT_REC_REVIEWER_TURNS=0
    SCOUT_REC_TESTER_TURNS=0

    if [ ! -f "$report" ]; then
        return 1
    fi

    # Extract the Complexity Estimate section
    local section
    section=$(awk '/^## Complexity Estimate/{found=1; next} found && /^##/{exit} found{print}' \
        "$report" 2>/dev/null || true)

    if [ -z "$section" ]; then
        return 1
    fi

    # Parse each field — extract the numeric value after the colon
    SCOUT_FILES_TO_MODIFY=$(echo "$section" | grep -i "^Files to modify:" | sed 's/.*: *//' | tr -dc '0-9' || echo "0")
    SCOUT_LINES_OF_CHANGE=$(echo "$section" | grep -i "^Estimated lines" | sed 's/.*: *//' | tr -dc '0-9' || echo "0")
    SCOUT_INTERCONNECTED=$(echo "$section" | grep -i "^Interconnected" | sed 's/.*: *//' | tr -d '[:space:]' || echo "unknown")
    SCOUT_REC_CODER_TURNS=$(echo "$section" | grep -i "^Recommended coder" | sed 's/.*: *//' | tr -dc '0-9' || echo "0")
    SCOUT_REC_REVIEWER_TURNS=$(echo "$section" | grep -i "^Recommended reviewer" | sed 's/.*: *//' | tr -dc '0-9' || echo "0")
    SCOUT_REC_TESTER_TURNS=$(echo "$section" | grep -i "^Recommended tester" | sed 's/.*: *//' | tr -dc '0-9' || echo "0")

    # Validate — at least coder turns must be non-zero
    [ "${SCOUT_REC_CODER_TURNS:-0}" -gt 0 ] 2>/dev/null
}

# --- Apply scout recommendations to turn limits -----------------------------

# Reads scout complexity and sets ADJUSTED_*_TURNS variables.
# Falls back to configured defaults if scout data is missing or dynamic turns disabled.
apply_scout_turn_limits() {
    # Initialize adjusted values to defaults
    ADJUSTED_CODER_TURNS="$CODER_MAX_TURNS"
    ADJUSTED_REVIEWER_TURNS="$REVIEWER_MAX_TURNS"
    ADJUSTED_TESTER_TURNS="$TESTER_MAX_TURNS"

    if [ "${DYNAMIC_TURNS_ENABLED}" != "true" ]; then
        log "Dynamic turn limits disabled — using configured defaults."
        return
    fi

    local report="${1:-SCOUT_REPORT.md}"
    if ! parse_scout_complexity "$report"; then
        log "No scout complexity estimate found — using configured defaults."
        return
    fi

    log "Scout complexity estimate:"
    log "  Files to modify: ${SCOUT_FILES_TO_MODIFY}"
    log "  Estimated lines: ${SCOUT_LINES_OF_CHANGE}"
    log "  Interconnected:  ${SCOUT_INTERCONNECTED}"
    log "  Recommended:     coder=${SCOUT_REC_CODER_TURNS}, reviewer=${SCOUT_REC_REVIEWER_TURNS}, tester=${SCOUT_REC_TESTER_TURNS}"

    # Apply scout recommendation, clamped to configured bounds
    if [ "${SCOUT_REC_CODER_TURNS:-0}" -gt 0 ] 2>/dev/null; then
        ADJUSTED_CODER_TURNS=$(clamp_turns "$SCOUT_REC_CODER_TURNS" "$CODER_MIN_TURNS" "$CODER_MAX_TURNS_CAP")
        log "Coder turns: ${CODER_MAX_TURNS} (configured) → ${ADJUSTED_CODER_TURNS} (scout-adjusted)"
    fi

    if [ "${SCOUT_REC_REVIEWER_TURNS:-0}" -gt 0 ] 2>/dev/null; then
        ADJUSTED_REVIEWER_TURNS=$(clamp_turns "$SCOUT_REC_REVIEWER_TURNS" "$REVIEWER_MIN_TURNS" "$REVIEWER_MAX_TURNS_CAP")
        log "Reviewer turns: ${REVIEWER_MAX_TURNS} (configured) → ${ADJUSTED_REVIEWER_TURNS} (scout-adjusted)"
    fi

    if [ "${SCOUT_REC_TESTER_TURNS:-0}" -gt 0 ] 2>/dev/null; then
        ADJUSTED_TESTER_TURNS=$(clamp_turns "$SCOUT_REC_TESTER_TURNS" "$TESTER_MIN_TURNS" "$TESTER_MAX_TURNS_CAP")
        log "Tester turns: ${TESTER_MAX_TURNS} (configured) → ${ADJUSTED_TESTER_TURNS} (scout-adjusted)"
    fi
}

# --- Estimate turns from coder output ----------------------------------------

# When no scout ran (e.g., --start-at review), estimate reviewer/tester turns
# based on the size of coder output. This is a rough heuristic.
estimate_post_coder_turns() {
    if [ "${DYNAMIC_TURNS_ENABLED}" != "true" ]; then
        ADJUSTED_REVIEWER_TURNS="${ADJUSTED_REVIEWER_TURNS:-$REVIEWER_MAX_TURNS}"
        ADJUSTED_TESTER_TURNS="${ADJUSTED_TESTER_TURNS:-$TESTER_MAX_TURNS}"
        return
    fi

    # If scout already set these, don't override
    if [ "${SCOUT_REC_REVIEWER_TURNS:-0}" -gt 0 ] 2>/dev/null; then
        return
    fi

    local files_modified=0
    local diff_lines=0

    # Count files modified from CODER_SUMMARY.md
    if [ -f "CODER_SUMMARY.md" ]; then
        files_modified=$(awk '/^## Files (Modified|created or modified)/{found=1; next} found && /^##/{exit} found && /^[-*]/{count++} END{print count+0}' \
            CODER_SUMMARY.md 2>/dev/null || echo "0")
    fi

    # Count git diff stat lines
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        diff_lines=$(git diff --stat HEAD 2>/dev/null | tail -1 | grep -o '[0-9]* insertion' | tr -dc '0-9' || echo "0")
        local del_lines
        del_lines=$(git diff --stat HEAD 2>/dev/null | tail -1 | grep -o '[0-9]* deletion' | tr -dc '0-9' || echo "0")
        diff_lines=$(( ${diff_lines:-0} + ${del_lines:-0} ))
    fi

    # Heuristic: more files/lines → more review/test turns needed
    local estimated_reviewer estimated_tester
    if [ "$files_modified" -le 3 ] && [ "$diff_lines" -le 100 ]; then
        estimated_reviewer=8
        estimated_tester=20
    elif [ "$files_modified" -le 8 ] && [ "$diff_lines" -le 500 ]; then
        estimated_reviewer=12
        estimated_tester=35
    else
        estimated_reviewer=18
        estimated_tester=50
    fi

    ADJUSTED_REVIEWER_TURNS=$(clamp_turns "$estimated_reviewer" "$REVIEWER_MIN_TURNS" "$REVIEWER_MAX_TURNS_CAP")
    ADJUSTED_TESTER_TURNS=$(clamp_turns "$estimated_tester" "$TESTER_MIN_TURNS" "$TESTER_MAX_TURNS_CAP")

    log "Post-coder turn estimate (${files_modified} files, ~${diff_lines} diff lines):"
    log "  Reviewer: ${ADJUSTED_REVIEWER_TURNS}, Tester: ${ADJUSTED_TESTER_TURNS}"
}
