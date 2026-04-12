#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2153
# =============================================================================
# plan_completeness.sh — Design document completeness checking
#
# Provides structural validation of ${DESIGN_FILE} against required template
# sections, and a follow-up interview loop for incomplete sections.
# Extracted from lib/plan.sh to keep files under 300 lines.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PLAN_TEMPLATE_FILE, PROJECT_DIR from plan.sh
# Expects: log(), success(), warn(), error(), header() from common.sh
# Expects: run_plan_followup_interview() from stages/plan_interview.sh
# =============================================================================

# --- Completeness Check ------------------------------------------------------

# _extract_required_sections — Parse template for sections marked <!-- REQUIRED -->.
_extract_required_sections() {
    local template_file="$1"
    local prev_line=""
    while IFS= read -r line; do
        if [[ "$line" == "<!-- REQUIRED -->" ]] && [[ "$prev_line" =~ ^##\  ]]; then
            # Strip the "## " prefix to get the section name
            echo "${prev_line#\#\# }"
        fi
        prev_line="$line"
    done < "$template_file"
}

# _get_section_content — Extract content between ## heading and next ## or EOF.
_get_section_content() {
    local design_file="$1"
    local section_name="$2"
    local in_section=0
    local content=""
    while IFS= read -r line; do
        if [[ "$in_section" -eq 1 ]]; then
            # Stop at next ## heading or end
            if [[ "$line" =~ ^##\  ]]; then
                break
            fi
            content="${content}${line}"$'\n'
        fi
        if [[ "$line" == "## ${section_name}" ]]; then
            in_section=1
        fi
    done < "$design_file"
    echo "$content"
}

# _is_section_incomplete — Check if content is empty, placeholder, or has comments.
_is_section_incomplete() {
    local content="$1"

    # Strip HTML comments (sed handles multiline safely)
    local stripped
    # shellcheck disable=SC2001
    stripped=$(echo "$content" | sed 's/<!--.*-->//g')
    # Strip whitespace
    stripped=$(echo "$stripped" | tr -d '[:space:]')

    # Empty after stripping comments and whitespace
    if [[ -z "$stripped" ]]; then
        return 0
    fi

    # Check for placeholder-only content (case-insensitive)
    local lower
    lower=$(echo "$stripped" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" == "tbd" ]] || [[ "$lower" == "tk" ]] || \
       [[ "$lower" == "todo" ]] || [[ "$lower" == "n/a" ]] || \
       [[ "$lower" == "tba" ]]; then
        return 0
    fi

    # Check for remaining guidance comments (multi-line comments)
    if echo "$content" | grep -q '<!--'; then
        return 0
    fi

    # Content looks adequate
    return 1
}

# --- Depth Scoring ----------------------------------------------------------

# Minimum non-blank line count for a required section to be considered deep.
# Overridable via environment variable.
PLAN_SECTION_MIN_LINES="${PLAN_SECTION_MIN_LINES:-5}"

# _score_section_depth — Score section content for structural depth.
#
# Returns a score from 0–6 based on:
#   +1  if content has >= PLAN_SECTION_MIN_LINES non-blank lines
#   +1  if content has >= 3 * PLAN_SECTION_MIN_LINES non-blank lines (prose depth)
#   +2  if content contains ### sub-headings
#   +1  if content contains markdown table rows (|...|)
#   +1  if content contains fenced code blocks (```)
#
# Arguments:
#   $1  content  — the raw section content (between ## headings)
#
# Prints the integer score to stdout.
_score_section_depth() {
    local content="$1"
    local score=0

    # Count non-blank lines
    local line_count
    line_count=$(echo "$content" | grep -c '[^[:space:]]' || true)
    if [[ "$line_count" -ge "$PLAN_SECTION_MIN_LINES" ]]; then
        score=$((score + 1))
    fi

    # Substantial prose depth — long-form content without sub-headings is still deep
    local prose_threshold=$(( PLAN_SECTION_MIN_LINES * 3 ))
    if [[ "$line_count" -ge "$prose_threshold" ]]; then
        score=$((score + 1))
    fi

    # Sub-headings (### or deeper)
    if echo "$content" | grep -q '^###'; then
        score=$((score + 2))
    fi

    # Markdown tables (lines containing |...|)
    if echo "$content" | grep -qE '^\|.*\|'; then
        score=$((score + 1))
    fi

    # Fenced code blocks
    if echo "$content" | grep -q '^```'; then
        score=$((score + 1))
    fi

    echo "$score"
}

# _is_section_shallow — Check if a non-empty section lacks structural depth.
#
# A section is shallow if its depth score is less than 2. This means it has
# content but lacks sub-sections AND (is short OR lacks tables/code examples).
#
# Arguments:
#   $1  content  — the raw section content
#
# Returns 0 (true) if shallow, 1 (false) if deep enough.
_is_section_shallow() {
    local content="$1"
    local score
    score=$(_score_section_depth "$content")
    [[ "$score" -lt 2 ]]
}

# check_design_completeness — Validate ${DESIGN_FILE} against required sections.
# Sets PLAN_INCOMPLETE_SECTIONS and returns 0 if all complete, 1 otherwise.
check_design_completeness() {
    local design_file="${PROJECT_DIR}/${DESIGN_FILE:-}"
    local template_file="$PLAN_TEMPLATE_FILE"

    PLAN_INCOMPLETE_SECTIONS=""

    if [[ ! -f "$design_file" ]]; then
        error "${DESIGN_FILE} not found at ${design_file}"
        return 1
    fi

    local required_sections
    required_sections=$(_extract_required_sections "$template_file")

    if [[ -z "$required_sections" ]]; then
        log "No required sections found in template — completeness check passed."
        return 0
    fi

    local section_name content incomplete_count=0
    while IFS= read -r section_name; do
        [[ -z "$section_name" ]] && continue

        # Check if section heading exists in ${DESIGN_FILE}
        if ! grep -q "^## ${section_name}$" "$design_file"; then
            warn "Missing section: ${section_name}"
            PLAN_INCOMPLETE_SECTIONS="${PLAN_INCOMPLETE_SECTIONS}${section_name}"$'\n'
            incomplete_count=$((incomplete_count + 1))
            continue
        fi

        content=$(_get_section_content "$design_file" "$section_name")

        if _is_section_incomplete "$content"; then
            warn "Incomplete section: ${section_name}"
            PLAN_INCOMPLETE_SECTIONS="${PLAN_INCOMPLETE_SECTIONS}[MISSING] ${section_name}"$'\n'
            incomplete_count=$((incomplete_count + 1))
        elif _is_section_shallow "$content"; then
            warn "Shallow section: ${section_name}"
            PLAN_INCOMPLETE_SECTIONS="${PLAN_INCOMPLETE_SECTIONS}[SHALLOW] ${section_name}"$'\n'
            incomplete_count=$((incomplete_count + 1))
        else
            log "Complete: ${section_name}"
        fi
    done <<< "$required_sections"

    # Trim trailing newline
    PLAN_INCOMPLETE_SECTIONS="${PLAN_INCOMPLETE_SECTIONS%$'\n'}"

    if [[ "$incomplete_count" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# run_plan_completeness_loop — Check completeness and run follow-up interviews.
run_plan_completeness_loop() {
    local design_file="${PROJECT_DIR}/${DESIGN_FILE}"

    if [[ ! -f "$design_file" ]]; then
        warn "No ${DESIGN_FILE} found — skipping completeness check."
        return 1
    fi

    local pass_num=0
    local max_followups=3

    while true; do
        pass_num=$((pass_num + 1))
        header "Completeness Check — Pass ${pass_num}"

        if check_design_completeness; then
            success "All required sections are complete and have sufficient depth."
            return 0
        fi

        echo
        local section_count
        section_count=$(echo "$PLAN_INCOMPLETE_SECTIONS" | grep -c '.' || true)
        warn "${section_count} required section(s) need more detail:"
        echo "$PLAN_INCOMPLETE_SECTIONS" | while IFS= read -r s; do
            [[ -n "$s" ]] && echo "  - ${s}"
        done
        echo

        if [[ "$pass_num" -ge "$max_followups" ]]; then
            warn "Maximum follow-up passes (${max_followups}) reached."
            warn "Continuing with incomplete sections. You can edit ${DESIGN_FILE} manually."
            return 0
        fi

        # Use /dev/tty when stdin is not a terminal (e.g., piped input from scripts).
        # TEKHTON_TEST_MODE disables this so tests can pipe input via stdin.
        local input_fd="/dev/stdin"
        if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
            input_fd="/dev/tty"
        fi

        local choice
        while true; do
            printf "  [f] Follow-up interview on incomplete sections\n"
            printf "  [s] Skip — continue with current %s\n" "${DESIGN_FILE}"
            printf "  Select [f/s]: "
            read -r choice < "$input_fd" || { log "End of input — skipping follow-up."; return 0; }
            choice="${choice//$'\r'/}"

            case "$choice" in
                f|F)
                    echo
                    run_plan_followup_interview || true
                    break
                    ;;
                s|S)
                    log "Skipping follow-up. Continuing with current ${DESIGN_FILE}."
                    return 0
                    ;;
                *)
                    warn "Invalid choice. Please enter 'f' or 's'."
                    ;;
            esac
        done
    done
}
