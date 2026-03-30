#!/usr/bin/env bash
set -euo pipefail
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

    # Strip markdown formatting that breaks field matching:
    # - **bold** field names (e.g. "**Files to modify:** 5")
    # - Leading bullets ("- Files to modify: 5")
    # This ensures grep ^Field anchors work regardless of LLM formatting.
    section=$(echo "$section" | sed 's/^[[:space:]]*[-*]*[[:space:]]*//' | sed 's/\*\*//g')

    # Parse each field — extract the numeric value after the colon.
    # For range values like "25-30", take the first number only.
    SCOUT_FILES_TO_MODIFY=$(echo "$section" | grep -i "^Files to modify:" | sed 's/.*: *//' | grep -oE '[0-9]+' | head -1 || echo "0")
    SCOUT_LINES_OF_CHANGE=$(echo "$section" | grep -i "^Estimated lines" | sed 's/.*: *//' | grep -oE '[0-9]+' | head -1 || echo "0")
    SCOUT_INTERCONNECTED=$(echo "$section" | grep -i "^Interconnected" | sed 's/.*: *//' | tr -d '[:space:]' || echo "unknown")
    SCOUT_REC_CODER_TURNS=$(echo "$section" | grep -i "^Recommended coder" | sed 's/.*: *//' | grep -oE '[0-9]+' | head -1 || echo "0")
    SCOUT_REC_REVIEWER_TURNS=$(echo "$section" | grep -i "^Recommended reviewer" | sed 's/.*: *//' | grep -oE '[0-9]+' | head -1 || echo "0")
    SCOUT_REC_TESTER_TURNS=$(echo "$section" | grep -i "^Recommended tester" | sed 's/.*: *//' | grep -oE '[0-9]+' | head -1 || echo "0")

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

    # Apply scout recommendation, with adaptive calibration, clamped to bounds.
    # IMPORTANT: Scout can only RAISE the budget above the configured default, never lower it.
    # This prevents the negative feedback loop where low estimates → low limits → capped data
    # → even lower estimates.
    if [ "${SCOUT_REC_CODER_TURNS:-0}" -gt 0 ] 2>/dev/null; then
        local calibrated_coder
        calibrated_coder=$(calibrate_turn_estimate "$SCOUT_REC_CODER_TURNS" "coder" | tail -1)
        [[ "$calibrated_coder" =~ ^[0-9]+$ ]] || calibrated_coder="$SCOUT_REC_CODER_TURNS"
        local clamped_coder
        clamped_coder=$(clamp_turns "$calibrated_coder" "$CODER_MIN_TURNS" "$CODER_MAX_TURNS_CAP")
        # Floor: never go below configured default
        if [ "$clamped_coder" -gt "$CODER_MAX_TURNS" ] 2>/dev/null; then
            ADJUSTED_CODER_TURNS="$clamped_coder"
        else
            ADJUSTED_CODER_TURNS="$CODER_MAX_TURNS"
        fi
        if [ "$calibrated_coder" != "$SCOUT_REC_CODER_TURNS" ]; then
            log "[metrics] Adaptive calibration: coder ${SCOUT_REC_CODER_TURNS} → ${calibrated_coder} (adjusted), floor ${CODER_MAX_TURNS} → ${ADJUSTED_CODER_TURNS}"
        else
            log "Coder turns: ${CODER_MAX_TURNS} (configured) → ${ADJUSTED_CODER_TURNS} (scout-adjusted, floor=${CODER_MAX_TURNS})"
        fi
    fi

    if [ "${SCOUT_REC_REVIEWER_TURNS:-0}" -gt 0 ] 2>/dev/null; then
        local calibrated_reviewer
        calibrated_reviewer=$(calibrate_turn_estimate "$SCOUT_REC_REVIEWER_TURNS" "reviewer" | tail -1)
        [[ "$calibrated_reviewer" =~ ^[0-9]+$ ]] || calibrated_reviewer="$SCOUT_REC_REVIEWER_TURNS"
        local clamped_reviewer
        clamped_reviewer=$(clamp_turns "$calibrated_reviewer" "$REVIEWER_MIN_TURNS" "$REVIEWER_MAX_TURNS_CAP")
        # Floor: never go below configured default
        if [ "$clamped_reviewer" -gt "$REVIEWER_MAX_TURNS" ] 2>/dev/null; then
            ADJUSTED_REVIEWER_TURNS="$clamped_reviewer"
        else
            ADJUSTED_REVIEWER_TURNS="$REVIEWER_MAX_TURNS"
        fi
        if [ "$calibrated_reviewer" != "$SCOUT_REC_REVIEWER_TURNS" ]; then
            log "[metrics] Adaptive calibration: reviewer ${SCOUT_REC_REVIEWER_TURNS} → ${calibrated_reviewer} (adjusted), floor ${REVIEWER_MAX_TURNS} → ${ADJUSTED_REVIEWER_TURNS}"
        else
            log "Reviewer turns: ${REVIEWER_MAX_TURNS} (configured) → ${ADJUSTED_REVIEWER_TURNS} (scout-adjusted, floor=${REVIEWER_MAX_TURNS})"
        fi
    fi

    if [ "${SCOUT_REC_TESTER_TURNS:-0}" -gt 0 ] 2>/dev/null; then
        local calibrated_tester
        calibrated_tester=$(calibrate_turn_estimate "$SCOUT_REC_TESTER_TURNS" "tester" | tail -1)
        [[ "$calibrated_tester" =~ ^[0-9]+$ ]] || calibrated_tester="$SCOUT_REC_TESTER_TURNS"
        local clamped_tester
        clamped_tester=$(clamp_turns "$calibrated_tester" "$TESTER_MIN_TURNS" "$TESTER_MAX_TURNS_CAP")
        # Floor: never go below configured default
        if [ "$clamped_tester" -gt "$TESTER_MAX_TURNS" ] 2>/dev/null; then
            ADJUSTED_TESTER_TURNS="$clamped_tester"
        else
            ADJUSTED_TESTER_TURNS="$TESTER_MAX_TURNS"
        fi
        if [ "$calibrated_tester" != "$SCOUT_REC_TESTER_TURNS" ]; then
            log "[metrics] Adaptive calibration: tester ${SCOUT_REC_TESTER_TURNS} → ${calibrated_tester} (adjusted), floor ${TESTER_MAX_TURNS} → ${ADJUSTED_TESTER_TURNS}"
        else
            log "Tester turns: ${TESTER_MAX_TURNS} (configured) → ${ADJUSTED_TESTER_TURNS} (scout-adjusted, floor=${TESTER_MAX_TURNS})"
        fi
    fi

    # Final sanitization — ensure all ADJUSTED_*_TURNS are bare integers.
    # Defense against log() stdout leaking into $() captures.
    [[ "$ADJUSTED_CODER_TURNS" =~ ^[0-9]+$ ]]    || ADJUSTED_CODER_TURNS="$CODER_MAX_TURNS"
    [[ "$ADJUSTED_REVIEWER_TURNS" =~ ^[0-9]+$ ]]  || ADJUSTED_REVIEWER_TURNS="$REVIEWER_MAX_TURNS"
    [[ "$ADJUSTED_TESTER_TURNS" =~ ^[0-9]+$ ]]    || ADJUSTED_TESTER_TURNS="$TESTER_MAX_TURNS"
}

# --- Post-coder turn recalibration -------------------------------------------

# Recalibrate reviewer/tester turn limits using actual coder data.
# Formula-based: uses actual_coder_turns + files_modified + diff_lines to compute
# reviewer and tester limits deterministically. Always overrides scout pre-coder
# guesses when actual_coder_turns is available.
#
# Arguments:
#   $1 — actual coder turns used (optional; falls back to heuristic if empty/0)
#
# Falls back to file-count/diff-line heuristic when actual turns unavailable
# (e.g., --start-at review).
estimate_post_coder_turns() {
    local actual_coder_turns="${1:-0}"

    if [ "${DYNAMIC_TURNS_ENABLED}" != "true" ]; then
        ADJUSTED_REVIEWER_TURNS="${ADJUSTED_REVIEWER_TURNS:-$REVIEWER_MAX_TURNS}"
        ADJUSTED_TESTER_TURNS="${ADJUSTED_TESTER_TURNS:-$TESTER_MAX_TURNS}"
        return
    fi

    local files_modified=0
    local diff_lines=0

    # Count files modified from CODER_SUMMARY.md
    # Note: ERE alternation (|) in awk /pattern/ is gawk/mawk-compatible but not
    # strictly POSIX. Acceptable for this project's Linux/WSL target environment.
    if [ -f "CODER_SUMMARY.md" ]; then
        files_modified=$(awk '/^## Files (Modified|created or modified)/{found=1; next} found && /^##/{exit} found && /^[-*]/{count++} END{print count+0}' \
            CODER_SUMMARY.md 2>/dev/null || echo "0")
    fi

    # Count git diff stat lines (insertions + deletions)
    # Note: when grep finds no match (no insertions/deletions), the pipeline fails
    # and the || echo "0" fallback fires correctly. When grep matches, tr strips
    # non-digits to extract the number. The ${var:-0} in arithmetic handles empty strings.
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        diff_lines=$(git diff --stat HEAD 2>/dev/null | tail -1 | grep -o '[0-9]* insertion' | tr -dc '0-9' || echo "0")
        local del_lines
        del_lines=$(git diff --stat HEAD 2>/dev/null | tail -1 | grep -o '[0-9]* deletion' | tr -dc '0-9' || echo "0")
        diff_lines=$(( ${diff_lines:-0} + ${del_lines:-0} ))
    fi

    local prior_reviewer="${ADJUSTED_REVIEWER_TURNS:-$REVIEWER_MAX_TURNS}"
    local prior_tester="${ADJUSTED_TESTER_TURNS:-$TESTER_MAX_TURNS}"
    local estimated_reviewer estimated_tester

    # Use formula when actual coder turns are available
    if [ "${actual_coder_turns:-0}" -gt 0 ] 2>/dev/null; then
        # Formula: reviewer = coder_actual * 0.35 + files * 1.5
        #          tester   = coder_actual * 0.5  + files * 2.0
        # Shell integer arithmetic: multiply first, divide to simulate decimals
        local coder_reviewer_part=$(( actual_coder_turns * 35 / 100 ))
        local files_reviewer_part=$(( files_modified * 15 / 10 ))
        estimated_reviewer=$(( coder_reviewer_part + files_reviewer_part ))

        local coder_tester_part=$(( actual_coder_turns * 50 / 100 ))
        local files_tester_part=$(( files_modified * 20 / 10 ))
        estimated_tester=$(( coder_tester_part + files_tester_part ))

        local clamped_reviewer clamped_tester
        clamped_reviewer=$(clamp_turns "$estimated_reviewer" "$REVIEWER_MIN_TURNS" "$REVIEWER_MAX_TURNS_CAP")
        clamped_tester=$(clamp_turns "$estimated_tester" "$TESTER_MIN_TURNS" "$TESTER_MAX_TURNS_CAP")

        # Floor: never go below configured defaults
        if [ "$clamped_reviewer" -gt "$REVIEWER_MAX_TURNS" ] 2>/dev/null; then
            ADJUSTED_REVIEWER_TURNS="$clamped_reviewer"
        else
            ADJUSTED_REVIEWER_TURNS="$REVIEWER_MAX_TURNS"
        fi
        if [ "$clamped_tester" -gt "$TESTER_MAX_TURNS" ] 2>/dev/null; then
            ADJUSTED_TESTER_TURNS="$clamped_tester"
        else
            ADJUSTED_TESTER_TURNS="$TESTER_MAX_TURNS"
        fi

        log "Post-coder recalibration: reviewer ${prior_reviewer}→${ADJUSTED_REVIEWER_TURNS}, tester ${prior_tester}→${ADJUSTED_TESTER_TURNS}"
        log "  (coder used ${actual_coder_turns} turns, ${files_modified} files, ~${diff_lines} diff lines)"
    else
        # Fallback heuristic when actual turns unavailable (e.g., --start-at review)
        if [ "$files_modified" -le 3 ] && [ "$diff_lines" -le 100 ]; then
            estimated_reviewer=15
            estimated_tester=30
        elif [ "$files_modified" -le 8 ] && [ "$diff_lines" -le 500 ]; then
            estimated_reviewer=20
            estimated_tester=40
        else
            estimated_reviewer=25
            estimated_tester=50
        fi

        local clamped_reviewer_fb clamped_tester_fb
        clamped_reviewer_fb=$(clamp_turns "$estimated_reviewer" "$REVIEWER_MIN_TURNS" "$REVIEWER_MAX_TURNS_CAP")
        clamped_tester_fb=$(clamp_turns "$estimated_tester" "$TESTER_MIN_TURNS" "$TESTER_MAX_TURNS_CAP")

        # Floor: never go below configured defaults
        if [ "$clamped_reviewer_fb" -gt "$REVIEWER_MAX_TURNS" ] 2>/dev/null; then
            ADJUSTED_REVIEWER_TURNS="$clamped_reviewer_fb"
        else
            ADJUSTED_REVIEWER_TURNS="$REVIEWER_MAX_TURNS"
        fi
        if [ "$clamped_tester_fb" -gt "$TESTER_MAX_TURNS" ] 2>/dev/null; then
            ADJUSTED_TESTER_TURNS="$clamped_tester_fb"
        else
            ADJUSTED_TESTER_TURNS="$TESTER_MAX_TURNS"
        fi

        log "Post-coder turn estimate — fallback heuristic (${files_modified} files, ~${diff_lines} diff lines):"
        log "  Reviewer: ${ADJUSTED_REVIEWER_TURNS}, Tester: ${ADJUSTED_TESTER_TURNS}"
    fi
}
