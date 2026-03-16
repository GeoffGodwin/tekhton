#!/usr/bin/env bash
# =============================================================================
# clarify.sh — Mid-run clarification protocol
#
# Sourced by tekhton.sh — do not run directly.
# Expects: log(), warn(), error(), header() from common.sh
# Expects: render_prompt() from prompts.sh
# =============================================================================

# --- Clarification file path ------------------------------------------------
CLARIFICATIONS_FILE="${PROJECT_DIR}/CLARIFICATIONS.md"

# detect_clarifications — Parse a report file for clarification items.
#
# Looks for a "## Clarification Required" section and extracts items tagged
# with [BLOCKING] or [NON_BLOCKING]. Results are written to two temp files
# in TEKHTON_SESSION_DIR:
#   clarify_blocking.txt   — one item per line
#   clarify_nonblocking.txt — one item per line
#
# Returns 0 if any clarifications found, 1 if none.
#
# Usage: detect_clarifications "CODER_SUMMARY.md"
detect_clarifications() {
    local report_file="$1"

    if [[ ! -f "$report_file" ]]; then
        return 1
    fi

    if [[ "${CLARIFICATION_ENABLED:-true}" != "true" ]]; then
        return 1
    fi

    local blocking_file="${TEKHTON_SESSION_DIR}/clarify_blocking.txt"
    local nonblocking_file="${TEKHTON_SESSION_DIR}/clarify_nonblocking.txt"

    # Extract the "## Clarification Required" section
    local section_content
    section_content=$(awk '/^## Clarification Required/{found=1; next} found && /^## /{exit} found{print}' \
        "$report_file" 2>/dev/null || true)

    if [[ -z "$section_content" ]]; then
        return 1
    fi

    # Extract blocking items (lines containing [BLOCKING])
    echo "$section_content" | grep -i '\[BLOCKING\]' | sed 's/^- //' > "$blocking_file" 2>/dev/null || true

    # Extract non-blocking items (lines containing [NON_BLOCKING])
    echo "$section_content" | grep -i '\[NON_BLOCKING\]' | sed 's/^- //' > "$nonblocking_file" 2>/dev/null || true

    local blocking_count=0
    local nonblocking_count=0
    if [[ -s "$blocking_file" ]]; then
        blocking_count=$(wc -l < "$blocking_file" | tr -d '[:space:]')
    fi
    if [[ -s "$nonblocking_file" ]]; then
        nonblocking_count=$(wc -l < "$nonblocking_file" | tr -d '[:space:]')
    fi

    if [[ "$blocking_count" -eq 0 ]] && [[ "$nonblocking_count" -eq 0 ]]; then
        return 1
    fi

    log "Clarifications detected: ${blocking_count} blocking, ${nonblocking_count} non-blocking"
    return 0
}

# handle_clarifications — Pause for human input on blocking questions.
#
# Reads blocking items from the session temp file, presents each to the user,
# collects answers via /dev/tty, and writes them to CLARIFICATIONS.md.
# Non-blocking items are logged but do not pause the pipeline.
#
# Returns 0 on success, 1 if user aborts.
#
# Usage: handle_clarifications
handle_clarifications() {
    local blocking_file="${TEKHTON_SESSION_DIR}/clarify_blocking.txt"
    local nonblocking_file="${TEKHTON_SESSION_DIR}/clarify_nonblocking.txt"

    # Handle non-blocking items first (log only, no pause)
    if [[ -s "$nonblocking_file" ]]; then
        log "Non-blocking clarifications (agent will proceed with assumptions):"
        while IFS= read -r item; do
            log "  - ${item}"
        done < "$nonblocking_file"
        echo
    fi

    # Handle blocking items (require human input)
    if [[ ! -s "$blocking_file" ]]; then
        return 0
    fi

    local blocking_count
    blocking_count=$(wc -l < "$blocking_file" | tr -d '[:space:]')

    echo
    header "Clarification Required — ${blocking_count} Blocking Question(s)"
    echo "  The coder agent has questions that must be answered before continuing."
    echo "  Type your answer and press Enter. Type 'skip' to skip a question."
    echo "  Type 'abort' to save state and exit."
    echo

    # Determine input source
    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    # Initialize or append to CLARIFICATIONS.md
    local clarify_header
    clarify_header="# Clarifications — $(date '+%Y-%m-%d %H:%M:%S')"
    if [[ ! -f "$CLARIFICATIONS_FILE" ]]; then
        {
            echo "$clarify_header"
            echo ""
        } > "$CLARIFICATIONS_FILE"
    else
        {
            echo ""
            echo "$clarify_header"
            echo ""
        } >> "$CLARIFICATIONS_FILE"
    fi

    local question_num=0
    while IFS= read -r question; do
        question_num=$((question_num + 1))

        echo -e "${BOLD}Question ${question_num}/${blocking_count}:${NC}"
        echo "  ${question}"
        echo
        printf "  Answer: "

        local answer
        read -r answer < "$input_fd" || { warn "End of input"; answer="skip"; }
        answer="${answer//$'\r'/}"

        if [[ "$answer" == "abort" ]]; then
            warn "Clarification aborted by user."
            # Write partial answers collected so far
            return 1
        fi

        if [[ "$answer" == "skip" ]]; then
            log "  (skipped)"
            {
                echo "## Q: ${question}"
                echo "**A:** (skipped by user)"
                echo ""
            } >> "$CLARIFICATIONS_FILE"
        else
            {
                echo "## Q: ${question}"
                echo "**A:** ${answer}"
                echo ""
            } >> "$CLARIFICATIONS_FILE"
            success "  Answer recorded."
        fi
        echo
    done < "$blocking_file"

    success "All clarifications recorded in CLARIFICATIONS.md"
    return 0
}

# load_clarifications_content — Load CLARIFICATIONS.md into the export variable
# CLARIFICATIONS_CONTENT for template injection.
#
# Usage: load_clarifications_content
load_clarifications_content() {
    export CLARIFICATIONS_CONTENT=""
    if [[ -f "$CLARIFICATIONS_FILE" ]] && [[ -s "$CLARIFICATIONS_FILE" ]]; then
        CLARIFICATIONS_CONTENT=$(_safe_read_file "$CLARIFICATIONS_FILE" "CLARIFICATIONS")
    fi
}

