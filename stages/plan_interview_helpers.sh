#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# stages/plan_interview_helpers.sh — Helper functions for plan_interview.sh
#
# Extracted from plan_interview.sh to keep both files under the 300-line ceiling.
# Contains: _read_section_answer, _read_section_answer_editor,
#           _build_phase_context, _select_interview_mode, _run_file_mode,
#           _run_cli_interview.
#
# Sourced by plan_interview.sh — do not run directly.
# Expects: log(), success(), warn() from common.sh
# Expects: load_answer(), save_answer(), load_all_answers(),
#          export_question_template() from plan_answers.sh
# Expects: _extract_template_sections(), _slugify_section() from plan.sh
# Expects: PLAN_TEMPLATE_FILE, PLAN_ANSWER_FILE, PROJECT_DIR
# =============================================================================

# _read_section_answer — Read a multi-line answer from the user.
#
# If VISUAL or EDITOR is set, opens the editor with a temp file containing
# guidance as comments. The user writes their answer, saves, and exits.
# Otherwise, reads lines from the given fd until a blank line.
# Returns "skip" (with rc=0) if no content entered or EOF.
# When TEKHTON_TEST_MODE is set, uses the line-by-line fallback via stdin.
#
# Arguments:
#   $1  guidance     — Guidance text to display above the prompt
#   $2  is_required  — "true" or "false"
#   $3  input_fd     — Numeric file descriptor to read from (e.g., 3)
#
# Callers must open their input source on this fd before calling.
# Using fd numbers (read -u N) instead of path re-opening (< /dev/stdin)
# guarantees correct position sharing across subshell calls ($()),
# regardless of whether the input is a pipe or regular file.
#
# Prints the collected answer to stdout.
# All prompt/guidance display goes to stderr so it remains visible even when
# this function is called inside a command substitution: answer=$(...)
_read_section_answer() {
    local guidance="$1"
    local is_required="$2"
    local input_fd="$3"

    local editor="${VISUAL:-${EDITOR:-}}"

    # Use editor when available and on a real terminal (not test mode)
    if [[ -n "$editor" ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]] && [[ -e /dev/tty ]]; then
        _read_section_answer_editor "$guidance" "$is_required" "$editor"
        return $?
    fi

    # Fallback: line-by-line read from the given fd
    echo >&2
    if [[ -n "$guidance" ]]; then
        echo "  ${guidance}" >&2
    fi
    if [[ "$is_required" != "true" ]]; then
        echo "  (optional — type 'skip' to skip)" >&2
    fi
    echo >&2
    printf "  >>> " >&2

    local lines=() line=""
    while IFS= read -r -u "$input_fd" line; do
        line="${line//$'\r'/}"
        if [[ -z "$line" ]]; then
            [[ "${#lines[@]}" -gt 0 ]] && break
        else
            lines+=("$line")
            printf "  >>> " >&2
        fi
    done

    if [[ "${#lines[@]}" -eq 0 ]]; then
        echo "skip"
        return 0
    fi

    # Join lines with newlines to preserve multi-line structure for potential
    # YAML block scalar support in save_answer()
    local IFS=$'\n'
    echo "${lines[*]}"
}

# _read_section_answer_editor — Read answer via $EDITOR.
#
# Creates a temp file with guidance as comments, opens the editor, and reads
# the non-comment content when the user saves and exits.
#
# Arguments:
#   $1  guidance     — Guidance text
#   $2  is_required  — "true" or "false"
#   $3  editor       — Editor command to invoke
_read_section_answer_editor() {
    local guidance="$1"
    local is_required="$2"
    local editor="$3"

    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/tekhton_answer.XXXXXX.md")

    # Write guidance as comments the user can read while editing
    {
        echo "# Write your answer below. Lines starting with # are ignored."
        echo "# Save and exit the editor to submit. Empty file = skip."
        if [[ -n "$guidance" ]]; then
            echo "#"
            echo "# Guidance: ${guidance}"
        fi
        if [[ "$is_required" != "true" ]]; then
            echo "# (This section is optional)"
        fi
        echo ""
    } > "$tmpfile"

    echo "  Opening editor for your answer..." >&2

    # Open the editor on the terminal — /dev/tty handles the case where
    # stdout is captured by $()
    "$editor" "$tmpfile" < /dev/tty > /dev/tty 2>&1

    # Read back the answer, stripping comment lines
    local lines=()
    while IFS= read -r line; do
        [[ "$line" == "#"* ]] && continue
        [[ -n "$line" ]] && lines+=("$line")
    done < "$tmpfile"

    rm -f "$tmpfile"

    if [[ "${#lines[@]}" -eq 0 ]]; then
        echo "skip"
        return 0
    fi

    # Join lines with newlines to preserve multi-line structure for YAML
    # block scalar support in save_answer(). Matches CLI fallback behavior.
    local IFS=$'\n'
    echo "${lines[*]}"
}

# _build_phase_context — Build a summary of prior phase answers from YAML.
#
# Arguments:
#   $1  max_phase — include answers from phases < this value
#
# Prints a formatted summary to stdout.
_build_phase_context() {
    local max_phase="$1"

    local context=""
    while IFS='|' read -r _id title phase _req answer; do
        if [[ "$phase" -lt "$max_phase" ]] && [[ -n "$answer" ]] && \
           [[ "$answer" != "SKIP" ]] && [[ "$answer" != "TBD" ]]; then
            # Decode %%NL%% for display, but truncate for context
            local decoded="${answer//%%NL%%/ }"
            # Limit context display per section
            if [[ "${#decoded}" -gt 200 ]]; then
                decoded="${decoded:0:200}..."
            fi
            context+="- **${title}**: ${decoded}"$'\n'
        fi
    done < <(load_all_answers)
    echo "$context"
}

# _select_interview_mode — Present mode selection menu.
# Returns the chosen mode: "cli", "file", or "browser".
_select_interview_mode() {
    local input_fd="$1"

    echo >&2
    echo "  How would you like to answer the planning questions?" >&2
    echo "    1) CLI Mode     — answer questions one by one in the terminal" >&2
    echo "    2) File Mode    — export questions to YAML, fill out in your editor" >&2
    echo "    3) Browser Mode — fill out a form in your browser" >&2
    echo >&2

    local choice
    while true; do
        printf "  Select [1-3]: " >&2
        read -r -u "$input_fd" choice || { echo "cli"; return 0; }
        choice="${choice//$'\r'/}"
        case "$choice" in
            1) echo "cli"; return 0 ;;
            2) echo "file"; return 0 ;;
            3) echo "browser"; return 0 ;;
            *) warn "Invalid choice. Enter 1, 2, or 3." ;;
        esac
    done
}

# _run_file_mode — Handle file-mode interview flow.
# Exports template, waits for user to fill it, then imports.
_run_file_mode() {
    local export_path="${PROJECT_DIR}/.claude/plan_questions.yaml"

    export_question_template "$PLAN_TEMPLATE_FILE" "$export_path"
    success "Question template exported to: ${export_path}"
    echo
    log "Fill in the 'answer' field for each section in your editor."
    log "When done, re-run: tekhton --plan --answers ${export_path}"
    echo
    return 1
}

# _run_cli_interview — Interactive CLI interview loop.
# Collects answers section by section, saving each to the YAML file.
# Args: input_fd
_run_cli_interview() {
    local input_fd="$1"

    # Parse template sections into parallel arrays (4-field format)
    local -a section_names=() section_required=() section_guidance=() section_phases=()
    local -a section_ids=()
    while IFS='|' read -r s_name s_req s_guide s_phase; do
        section_names+=("$s_name")
        section_required+=("$s_req")
        section_guidance+=("$s_guide")
        section_phases+=("${s_phase:-1}")
        section_ids+=("$(_slugify_section "$s_name")")
    done < <(_extract_template_sections "$PLAN_TEMPLATE_FILE")

    local total="${#section_names[@]}"
    if [[ "$total" -eq 0 ]]; then
        warn "No sections found in template: ${PLAN_TEMPLATE_FILE}"
        return 1
    fi

    local current_phase=0
    local section_num=0
    local i
    for i in "${!section_names[@]}"; do
        local name="${section_names[$i]}"
        local req="${section_required[$i]}"
        local guide="${section_guidance[$i]:-}"
        local phase="${section_phases[$i]}"
        local sid="${section_ids[$i]}"

        # Check if already answered (resume support)
        local existing_answer
        existing_answer=$(load_answer "$sid")
        if [[ -n "$existing_answer" ]] && [[ "$existing_answer" != "SKIP" ]] && \
           [[ "$existing_answer" != "TBD" ]]; then
            section_num=$((section_num + 1))
            log "  [${section_num}/${total}] ${name} — already answered (${#existing_answer} chars)"
            continue
        fi

        # Display phase header on phase transition
        if [[ "$phase" -ne "$current_phase" ]]; then
            current_phase="$phase"
            echo
            echo "╔══════════════════════════════════════════════════╗"
            echo "║  ${_PHASE_LABELS[$phase]}"
            echo "╚══════════════════════════════════════════════════╝"
            echo

            # Show Phase 1 context at the start of Phase 2+
            if [[ "$phase" -ge 2 ]]; then
                local context
                context=$(_build_phase_context "$phase")
                if [[ -n "$context" ]]; then
                    log "Your answers so far:"
                    echo "$context" | while IFS= read -r ctx_line; do
                        [[ -n "$ctx_line" ]] && echo "  ${ctx_line}"
                    done
                    echo
                fi
            fi
        fi

        section_num=$((section_num + 1))
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [[ "$req" == "true" ]]; then
            echo "  [${section_num}/${total}] ${name}  *required"
        else
            echo "  [${section_num}/${total}] ${name}  (optional)"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        local answer
        answer=$(_read_section_answer "$guide" "$req" "$input_fd")

        if [[ "$answer" == "skip" || "$answer" == "s" ]]; then
            if [[ "$req" == "true" ]]; then
                warn "  Required section skipped — will be marked TBD in DESIGN.md."
                save_answer "$sid" "TBD"
            else
                log "  Skipped."
                save_answer "$sid" "SKIP"
            fi
        else
            save_answer "$sid" "$answer"
        fi
        echo
    done
}
