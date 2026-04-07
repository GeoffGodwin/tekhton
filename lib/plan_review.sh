#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# plan_review.sh — Draft review UI before synthesis
#
# Displays all collected answers in a structured summary with completeness
# status and char counts. Allows editing individual sections before synthesis.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PLAN_ANSWER_FILE from plan_answers.sh
# Expects: load_all_answers(), save_answer(), answer_file_complete() from plan_answers.sh
# Expects: log(), warn(), success(), header() from common.sh
# =============================================================================

# show_draft_review — Display all answers and allow editing before synthesis.
#
# Returns 0 when user is ready to proceed to synthesis.
# Returns 1 if user quits (answers are saved).
show_draft_review() {
    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    while true; do
        _display_draft_summary

        local choice
        printf "  Select [e/s/q]: "
        read -r choice < "$input_fd" || { warn "End of input — proceeding to synthesis."; return 0; }
        choice="${choice//$'\r'/}"

        case "$choice" in
            e|E)
                _edit_section "$input_fd"
                ;;
            s|S)
                if ! answer_file_complete; then
                    warn "Some required sections still need answers."
                    printf "  Proceed anyway? [y/n]: "
                    local confirm
                    read -r confirm < "$input_fd" || confirm="n"
                    confirm="${confirm//$'\r'/}"
                    if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
                        continue
                    fi
                fi
                return 0
                ;;
            q|Q)
                log "Answers saved to ${PLAN_ANSWER_FILE}"
                log "Resume with: tekhton --plan"
                return 1
                ;;
            *)
                warn "Invalid choice '${choice}'. Enter e, s, or q."
                ;;
        esac
    done
}

# _display_draft_summary — Render the answer overview table.
_display_draft_summary() {
    echo
    echo "══════════════════════════════════════"
    echo "  Planning Draft Review"
    echo "══════════════════════════════════════"
    echo

    local current_phase=0
    local total_sections=0
    local complete_sections=0
    local required_incomplete=0

    # First pass: collect data into arrays for display
    local -a ids=() titles=() phases=() requireds=() answers=()
    while IFS='|' read -r s_id s_title s_phase s_req s_answer; do
        ids+=("$s_id")
        titles+=("$s_title")
        phases+=("$s_phase")
        requireds+=("$s_req")
        answers+=("$s_answer")
    done < <(load_all_answers)

    local i
    for i in "${!ids[@]}"; do
        local phase="${phases[$i]}"
        local title="${titles[$i]}"
        local required="${requireds[$i]}"
        local answer="${answers[$i]}"

        # Phase header on transition
        if [[ "$phase" -ne "$current_phase" ]]; then
            current_phase="$phase"
            local phase_label=""
            case "$phase" in
                1) phase_label="Phase 1: Concept Capture" ;;
                2) phase_label="Phase 2: System Deep-Dive" ;;
                3) phase_label="Phase 3: Architecture & Constraints" ;;
                *) phase_label="Phase ${phase}" ;;
            esac
            echo "  ${phase_label}"
            echo "  ────────────────────────────────────"
        fi

        total_sections=$((total_sections + 1))
        local num=$((i + 1))

        # Decode %%NL%% for char counting
        local decoded_answer="${answer//%%NL%%/$'\n'}"
        local char_count=${#decoded_answer}

        if [[ -z "$answer" ]] || [[ "$answer" == "SKIP" ]] || [[ "$answer" == "TBD" ]]; then
            if [[ "$required" == "true" ]]; then
                printf "  %s %2d. %s (TBD)  *required\n" "✗" "$num" "$title"
                required_incomplete=$((required_incomplete + 1))
            else
                printf "  %s %2d. %s (skipped)\n" "~" "$num" "$title"
                complete_sections=$((complete_sections + 1))
            fi
        else
            printf "  %s %2d. %s (%d chars)\n" "✓" "$num" "$title" "$char_count"
            complete_sections=$((complete_sections + 1))
        fi
    done

    echo
    echo "  ${complete_sections} of ${total_sections} sections complete."
    if [[ "$required_incomplete" -gt 0 ]]; then
        warn "  ${required_incomplete} required section(s) need answers."
    fi
    echo
    echo "  Actions:"
    echo "    [e] Edit a section    [s] Start synthesis    [q] Quit (answers saved)"
    echo
}

# _edit_section — Prompt for section number and open for editing.
# Args: input_fd
_edit_section() {
    local input_fd="$1"

    # Collect section IDs for lookup
    local -a ids=() titles=()
    while IFS='|' read -r s_id s_title _phase _req _answer; do
        ids+=("$s_id")
        titles+=("$s_title")
    done < <(load_all_answers)

    local total="${#ids[@]}"
    printf "  Section number to edit [1-%d]: " "$total"
    local num_choice
    read -r num_choice < "$input_fd" || return 0
    num_choice="${num_choice//$'\r'/}"

    if ! [[ "$num_choice" =~ ^[0-9]+$ ]] || [[ "$num_choice" -lt 1 ]] || [[ "$num_choice" -gt "$total" ]]; then
        warn "Invalid section number."
        return 0
    fi

    local idx=$((num_choice - 1))
    local section_id="${ids[$idx]}"
    local section_title="${titles[$idx]}"

    # Load current answer
    local current_answer
    current_answer=$(load_answer "$section_id")

    echo
    echo "  Editing: ${section_title}"
    if [[ -n "$current_answer" ]] && [[ "$current_answer" != "SKIP" ]] && [[ "$current_answer" != "TBD" ]]; then
        echo "  Current answer:"
        echo "$current_answer" | head -10 | while IFS= read -r line; do
            echo "    ${line}"
        done
        local total_lines
        total_lines=$(echo "$current_answer" | count_lines)
        if [[ "$total_lines" -gt 10 ]]; then
            echo "    ... (${total_lines} lines total)"
        fi
    fi

    local editor="${VISUAL:-${EDITOR:-}}"

    if [[ -n "$editor" ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]] && [[ -e /dev/tty ]]; then
        _edit_section_in_editor "$section_id" "$section_title" "$current_answer" "$editor"
    else
        _edit_section_inline "$section_id" "$input_fd"
    fi
}

# _edit_section_in_editor — Open answer in $EDITOR for editing.
_edit_section_in_editor() {
    local section_id="$1"
    local section_title="$2"
    local current_answer="$3"
    local editor="$4"

    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/tekhton_edit.XXXXXX.md")

    {
        echo "# Editing: ${section_title}"
        echo "# Lines starting with # are ignored."
        echo "# Save and exit to update. Empty file = keep current answer."
        echo ""
        if [[ -n "$current_answer" ]] && [[ "$current_answer" != "SKIP" ]] && [[ "$current_answer" != "TBD" ]]; then
            echo "$current_answer"
        fi
    } > "$tmpfile"

    "$editor" "$tmpfile" < /dev/tty > /dev/tty 2>&1

    local new_answer=""
    while IFS= read -r line; do
        [[ "$line" == "#"* ]] && continue
        if [[ -z "$new_answer" ]]; then
            new_answer="$line"
        else
            new_answer="${new_answer}"$'\n'"${line}"
        fi
    done < "$tmpfile"

    rm -f "$tmpfile"

    # Trim
    new_answer="${new_answer#"${new_answer%%[![:space:]]*}"}"
    new_answer="${new_answer%"${new_answer##*[![:space:]]}"}"

    if [[ -n "$new_answer" ]]; then
        save_answer "$section_id" "$new_answer"
        success "  Updated: ${section_title}"
    else
        log "  No changes — keeping current answer."
    fi
}

# _edit_section_inline — Read new answer from terminal.
_edit_section_inline() {
    local section_id="$1"
    local input_fd="$2"

    echo "  Enter new answer (blank line to finish):"
    printf "  >>> "

    local lines=() line=""
    while IFS= read -r -u "$input_fd" line; do
        line="${line//$'\r'/}"
        if [[ -z "$line" ]]; then
            [[ "${#lines[@]}" -gt 0 ]] && break
        else
            lines+=("$line")
            printf "  >>> "
        fi
    done

    if [[ "${#lines[@]}" -gt 0 ]]; then
        local new_answer
        new_answer=$(printf '%s\n' "${lines[@]}")
        new_answer="${new_answer%$'\n'}"
        save_answer "$section_id" "$new_answer"
        success "  Answer updated."
    else
        log "  No input — keeping current answer."
    fi
}
