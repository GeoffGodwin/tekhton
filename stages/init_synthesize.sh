#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# stages/init_synthesize.sh — Agent-assisted project synthesis (Milestone 21)
#
# Uses PROJECT_INDEX.md + tech stack detection as input to an agent-assisted
# synthesis pipeline that generates DESIGN.md and CLAUDE.md for brownfield
# projects. The brownfield equivalent of --plan — reads existing code instead
# of interviewing the user.
#
# Sourced by tekhton.sh when --plan-from-index is passed. Do not run directly.
# Expects: log(), success(), warn(), error(), header() from common.sh
# Expects: render_prompt(), _call_planning_batch() from lib/plan.sh
# Expects: check_context_budget(), measure_context_size() from lib/context.sh
# Expects: compress_context() from lib/context_compiler.sh
# Expects: format_detection_report() from lib/detect_report.sh
# Expects: check_design_completeness() from lib/plan_completeness.sh
# =============================================================================

# --- Config defaults for synthesis -------------------------------------------

export SYNTHESIS_MODEL="${SYNTHESIS_MODEL:-${PLAN_GENERATION_MODEL:-opus}}"
export SYNTHESIS_MAX_TURNS="${SYNTHESIS_MAX_TURNS:-${PLAN_GENERATION_MAX_TURNS:-50}}"

# --- Context assembly --------------------------------------------------------

# _assemble_synthesis_context — Builds agent prompt context from project artifacts.
#
# Loads PROJECT_INDEX.md, detection report, README, existing ARCHITECTURE.md,
# and git log summary. Applies context budget — compresses if over budget.
#
# Sets exported variables: PROJECT_INDEX_CONTENT, DETECTION_REPORT_CONTENT,
#   README_CONTENT, EXISTING_ARCHITECTURE_CONTENT, GIT_LOG_SUMMARY
#
# Args: $1 = project directory
# Returns: 0 on success, 1 if PROJECT_INDEX.md is missing
_assemble_synthesis_context() {
    local project_dir="$1"
    local index_file="${project_dir}/PROJECT_INDEX.md"

    if [[ ! -f "$index_file" ]]; then
        error "PROJECT_INDEX.md not found at ${index_file}"
        error "Run 'tekhton --init' first to generate the project index."
        return 1
    fi

    # Load project index
    export PROJECT_INDEX_CONTENT
    PROJECT_INDEX_CONTENT=$(cat "$index_file")
    log "Loaded PROJECT_INDEX.md ($(echo "$PROJECT_INDEX_CONTENT" | wc -c | tr -d '[:space:]') chars)"

    # Generate detection report
    export DETECTION_REPORT_CONTENT
    DETECTION_REPORT_CONTENT=$(format_detection_report "$project_dir")
    log "Generated detection report ($(echo "$DETECTION_REPORT_CONTENT" | wc -c | tr -d '[:space:]') chars)"

    # Load README if present
    export README_CONTENT=""
    local readme_file=""
    for candidate in README.md README.rst README.txt README; do
        if [[ -f "${project_dir}/${candidate}" ]]; then
            readme_file="${project_dir}/${candidate}"
            break
        fi
    done
    if [[ -n "$readme_file" ]]; then
        README_CONTENT=$(cat "$readme_file")
        log "Loaded ${readme_file##*/} ($(echo "$README_CONTENT" | wc -c | tr -d '[:space:]') chars)"
    fi

    # Load existing architecture doc if present
    export EXISTING_ARCHITECTURE_CONTENT=""
    if [[ -f "${project_dir}/ARCHITECTURE.md" ]]; then
        EXISTING_ARCHITECTURE_CONTENT=$(cat "${project_dir}/ARCHITECTURE.md")
        log "Loaded ARCHITECTURE.md ($(echo "$EXISTING_ARCHITECTURE_CONTENT" | wc -c | tr -d '[:space:]') chars)"
    fi

    # Git log summary (last 30 commits)
    export GIT_LOG_SUMMARY=""
    if git -C "$project_dir" rev-parse --git-dir &>/dev/null; then
        GIT_LOG_SUMMARY=$(git -C "$project_dir" log --oneline -30 2>/dev/null || true)
        if [[ -n "$GIT_LOG_SUMMARY" ]]; then
            log "Loaded git log ($(echo "$GIT_LOG_SUMMARY" | wc -l | tr -d '[:space:]') commits)"
        fi
    fi

    # --- Context budget check and compression ---
    _compress_synthesis_context

    return 0
}

# _compress_synthesis_context — Applies compression if total context exceeds budget.
#
# Compression priority (compress first → last):
#   1. Sampled file content in PROJECT_INDEX (truncate to headings only)
#   2. README (truncate to 50 lines)
#   3. Existing ARCHITECTURE.md (truncate to 50 lines)
#   4. Git log (truncate to 10 entries)
_compress_synthesis_context() {
    local cpt="${CHARS_PER_TOKEN:-4}"
    local total_chars=0
    total_chars=$(( ${#PROJECT_INDEX_CONTENT} + ${#DETECTION_REPORT_CONTENT} \
        + ${#README_CONTENT} + ${#EXISTING_ARCHITECTURE_CONTENT} \
        + ${#GIT_LOG_SUMMARY} ))
    local total_tokens=$(( (total_chars + cpt - 1) / cpt ))

    if check_context_budget "$total_tokens" "$SYNTHESIS_MODEL"; then
        log "[synthesis] Context within budget (${total_tokens} est. tokens)"
        return
    fi

    log "[synthesis] Over budget (${total_tokens} est. tokens) — applying compression"

    # Compress sampled file content in index to headings only
    local compressed_index
    compressed_index=$(compress_context "$PROJECT_INDEX_CONTENT" "summarize_headings")
    if [[ -n "$compressed_index" ]] && [[ ${#compressed_index} -lt ${#PROJECT_INDEX_CONTENT} ]]; then
        local saved=$(( (${#PROJECT_INDEX_CONTENT} - ${#compressed_index}) / cpt ))
        log "[synthesis] Compressed PROJECT_INDEX: saved ~${saved} tokens"
        PROJECT_INDEX_CONTENT="[Context compressed: PROJECT_INDEX.md reduced to headings only]
${compressed_index}"
    fi

    # Re-check
    total_chars=$(( ${#PROJECT_INDEX_CONTENT} + ${#DETECTION_REPORT_CONTENT} \
        + ${#README_CONTENT} + ${#EXISTING_ARCHITECTURE_CONTENT} \
        + ${#GIT_LOG_SUMMARY} ))
    total_tokens=$(( (total_chars + cpt - 1) / cpt ))
    if check_context_budget "$total_tokens" "$SYNTHESIS_MODEL"; then
        log "[synthesis] Under budget after index compression"
        return
    fi

    # Truncate README
    if [[ -n "$README_CONTENT" ]]; then
        README_CONTENT=$(compress_context "$README_CONTENT" "truncate" 50)
        log "[synthesis] Truncated README to 50 lines"
    fi

    # Truncate architecture doc
    if [[ -n "$EXISTING_ARCHITECTURE_CONTENT" ]]; then
        EXISTING_ARCHITECTURE_CONTENT=$(compress_context "$EXISTING_ARCHITECTURE_CONTENT" "truncate" 50)
        log "[synthesis] Truncated ARCHITECTURE.md to 50 lines"
    fi

    # Truncate git log
    if [[ -n "$GIT_LOG_SUMMARY" ]]; then
        GIT_LOG_SUMMARY=$(echo "$GIT_LOG_SUMMARY" | head -10)
        log "[synthesis] Truncated git log to 10 entries"
    fi

    total_chars=$(( ${#PROJECT_INDEX_CONTENT} + ${#DETECTION_REPORT_CONTENT} \
        + ${#README_CONTENT} + ${#EXISTING_ARCHITECTURE_CONTENT} \
        + ${#GIT_LOG_SUMMARY} ))
    total_tokens=$(( (total_chars + cpt - 1) / cpt ))
    if ! check_context_budget "$total_tokens" "$SYNTHESIS_MODEL"; then
        warn "[synthesis] Still over budget after compression (${total_tokens} est. tokens)"
        warn "[synthesis] Proceeding anyway — model may truncate internally"
    fi
}

# --- DESIGN.md generation ----------------------------------------------------

# _synthesize_design — Generates DESIGN.md from project index and detection.
#
# Args: $1 = project directory
# Returns: 0 if DESIGN.md was produced, 1 otherwise
_synthesize_design() {
    local project_dir="$1"
    local log_dir="${project_dir}/.claude/logs"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${log_dir}/${timestamp}_synthesize-design.log"

    mkdir -p "$log_dir"

    # Render the synthesis prompt
    local prompt
    prompt=$(render_prompt "init_synthesize_design")

    header "DESIGN.md Synthesis"
    log "Model: ${SYNTHESIS_MODEL}"
    log "Max turns: ${SYNTHESIS_MAX_TURNS}"
    log "Log: ${log_file}"
    echo
    log "Synthesizing DESIGN.md from project index..."

    # Write session metadata to log
    {
        echo "=== Tekhton Project Synthesis (DESIGN.md) ==="
        echo "Date: $(date)"
        echo "Model: ${SYNTHESIS_MODEL}"
        echo "Max Turns: ${SYNTHESIS_MAX_TURNS}"
        echo "=== Session Start ==="
    } > "$log_file"

    local design_content=""
    local batch_exit=0
    design_content=$(_call_planning_batch \
        "$SYNTHESIS_MODEL" \
        "$SYNTHESIS_MAX_TURNS" \
        "$prompt" \
        "$log_file") || batch_exit=$?

    {
        echo "=== Session End ==="
        echo "Exit code: ${batch_exit}"
        echo "Date: $(date)"
    } >> "$log_file"

    echo

    if [[ -n "$design_content" ]]; then
        local design_file="${project_dir}/DESIGN.md"
        printf '%s\n' "$design_content" > "$design_file"
        local line_count
        line_count=$(wc -l < "$design_file" | tr -d '[:space:]')
        success "DESIGN.md synthesized (${line_count} lines)."
        return 0
    else
        warn "Synthesis produced no output — DESIGN.md was not created."
        [[ "$batch_exit" -ne 0 ]] && warn "Claude exited with code ${batch_exit}."
        return 1
    fi
}

# --- Completeness check for synthesized DESIGN.md ----------------------------

# _check_synthesis_completeness — Validates synthesized DESIGN.md and re-synthesizes
# thin sections if needed.
#
# Args: $1 = project directory
# Returns: 0 always (best-effort — does not block on incomplete sections)
_check_synthesis_completeness() {
    local project_dir="$1"
    local design_file="${project_dir}/DESIGN.md"

    if [[ ! -f "$design_file" ]]; then
        return 0
    fi

    # Use a lightweight check: count sections with headers and minimal content
    local section_count
    section_count=$(grep -c '^## ' "$design_file" || true)

    if [[ "$section_count" -lt 5 ]]; then
        warn "DESIGN.md has only ${section_count} sections — running re-synthesis pass"
    fi

    # Check individual section depth regardless of total section count
    local thin_sections=""
    local section_name section_content line_count
    while IFS= read -r section_name; do
        [[ -z "$section_name" ]] && continue
        section_content=$(_get_section_content_simple "$design_file" "$section_name")
        line_count=$(echo "$section_content" | grep -c '[^[:space:]]' || true)
        if [[ "$line_count" -lt 3 ]]; then
            thin_sections="${thin_sections}${section_name}"$'\n'
        fi
    done < <(grep '^## ' "$design_file" | sed 's/^## //')

    if [[ -n "$thin_sections" ]]; then
        warn "Thin sections found:"
        echo "$thin_sections" | while IFS= read -r s; do
            [[ -n "$s" ]] && warn "  - ${s}"
        done

        # Set PLAN_INCOMPLETE_SECTIONS so the prompt can target these sections
        export PLAN_INCOMPLETE_SECTIONS
        PLAN_INCOMPLETE_SECTIONS=$(echo "$thin_sections" | sed '/^$/d' | sed 's/^/- /')

        # Re-synthesize with thin sections flagged
        log "Running second synthesis pass for thin sections..."
        _synthesize_design "$project_dir" || true

        # Clear after use
        unset PLAN_INCOMPLETE_SECTIONS
    else
        success "DESIGN.md has ${section_count} sections — completeness OK."
    fi

    return 0
}

# _get_section_content_simple — Extract content between ## heading and next ## or EOF.
# Simpler version of _get_section_content from plan_completeness.sh.
_get_section_content_simple() {
    local file="$1"
    local section_name="$2"
    local in_section=0
    local content=""
    while IFS= read -r line; do
        if [[ "$in_section" -eq 1 ]]; then
            if [[ "$line" =~ ^##\  ]]; then
                break
            fi
            content="${content}${line}"$'\n'
        fi
        if [[ "$line" == "## ${section_name}" ]]; then
            in_section=1
        fi
    done < "$file"
    echo "$content"
}

# --- CLAUDE.md generation ----------------------------------------------------

# _synthesize_claude — Generates CLAUDE.md from DESIGN.md and project index.
#
# Args: $1 = project directory
# Returns: 0 if CLAUDE.md was produced, 1 otherwise
_synthesize_claude() {
    local project_dir="$1"
    local design_file="${project_dir}/DESIGN.md"

    if [[ ! -f "$design_file" ]]; then
        error "DESIGN.md not found at ${design_file} — cannot generate CLAUDE.md."
        return 1
    fi

    local log_dir="${project_dir}/.claude/logs"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${log_dir}/${timestamp}_synthesize-claude.log"

    mkdir -p "$log_dir"

    # Set DESIGN_CONTENT for the prompt
    export DESIGN_CONTENT
    DESIGN_CONTENT=$(cat "$design_file")

    # Render the CLAUDE.md synthesis prompt
    local prompt
    prompt=$(render_prompt "init_synthesize_claude")

    header "CLAUDE.md Synthesis"
    log "Model: ${SYNTHESIS_MODEL}"
    log "Max turns: ${SYNTHESIS_MAX_TURNS}"
    log "Log: ${log_file}"
    echo
    log "Generating CLAUDE.md from DESIGN.md + project index..."

    {
        echo "=== Tekhton Project Synthesis (CLAUDE.md) ==="
        echo "Date: $(date)"
        echo "Model: ${SYNTHESIS_MODEL}"
        echo "Max Turns: ${SYNTHESIS_MAX_TURNS}"
        echo "=== Session Start ==="
    } > "$log_file"

    local claude_content=""
    local batch_exit=0
    claude_content=$(_call_planning_batch \
        "$SYNTHESIS_MODEL" \
        "$SYNTHESIS_MAX_TURNS" \
        "$prompt" \
        "$log_file") || batch_exit=$?

    {
        echo "=== Session End ==="
        echo "Exit code: ${batch_exit}"
        echo "Date: $(date)"
    } >> "$log_file"

    echo

    if [[ -n "$claude_content" ]]; then
        local claude_file="${project_dir}/CLAUDE.md"
        printf '%s\n' "$claude_content" > "$claude_file"
        local line_count
        line_count=$(wc -l < "$claude_file" | tr -d '[:space:]')
        success "CLAUDE.md synthesized (${line_count} lines)."
        return 0
    else
        warn "Generation produced no output — CLAUDE.md was not created."
        [[ "$batch_exit" -ne 0 ]] && warn "Claude exited with code ${batch_exit}."
        return 1
    fi
}

# --- Human review menu -------------------------------------------------------

# _synthesis_review_menu — Displays [a]ccept / [e]dit / [r]egenerate menu.
#
# Args: $1 = project directory
# Returns: 0 on accept, 1 on abort
_synthesis_review_menu() {
    local project_dir="$1"
    local design_file="${project_dir}/DESIGN.md"
    local claude_file="${project_dir}/CLAUDE.md"

    # Use /dev/tty for interactive input when stdin is not a terminal
    local input_fd="/dev/stdin"
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]] && [[ -z "${TEKHTON_TEST_MODE:-}" ]]; then
        input_fd="/dev/tty"
    fi

    local choice
    while true; do
        echo
        header "Project Synthesis — Review"

        if [[ -f "$design_file" ]]; then
            local design_lines
            design_lines=$(wc -l < "$design_file" | tr -d '[:space:]')
            log "DESIGN.md: ${design_lines} lines"
        fi

        if [[ -f "$claude_file" ]]; then
            local claude_lines milestones
            claude_lines=$(wc -l < "$claude_file" | tr -d '[:space:]')
            milestones=$(grep -c -E '^#{2,3} Milestone [0-9]+' "$claude_file" || true)
            log "CLAUDE.md: ${claude_lines} lines, ${milestones} milestones"
        fi

        echo
        echo "  [a] Accept — keep generated files"
        echo "  [e] Edit — open CLAUDE.md in \${EDITOR:-nano}"
        echo "  [d] Edit DESIGN.md — open DESIGN.md in \${EDITOR:-nano}"
        echo "  [r] Regenerate — re-run CLAUDE.md synthesis from DESIGN.md"
        echo "  [n] Abort — discard generated files"
        echo
        printf "  Select [a/e/d/r/n]: "
        read -r choice < "$input_fd" || { warn "End of input — accepting files."; choice="a"; }
        choice="${choice//$'\r'/}"

        case "$choice" in
            a|A)
                success "Files accepted at ${project_dir}:"
                log "  DESIGN.md"
                log "  CLAUDE.md"
                _print_synthesis_next_steps
                return 0
                ;;
            e|E)
                if [[ -f "$claude_file" ]]; then
                    log "Opening CLAUDE.md in editor..."
                    "${EDITOR:-nano}" "$claude_file" || warn "Editor exited with non-zero status"
                else
                    warn "CLAUDE.md not found."
                fi
                ;;
            d|D)
                if [[ -f "$design_file" ]]; then
                    log "Opening DESIGN.md in editor..."
                    "${EDITOR:-nano}" "$design_file" || warn "Editor exited with non-zero status"
                else
                    warn "DESIGN.md not found."
                fi
                ;;
            r|R)
                log "Re-generating CLAUDE.md from DESIGN.md..."
                _synthesize_claude "$project_dir" || warn "Re-generation failed."
                ;;
            n|N)
                warn "Aborted."
                if [[ -f "$design_file" ]]; then
                    warn "DESIGN.md preserved at: ${design_file}"
                fi
                if [[ -f "$claude_file" ]]; then
                    warn "CLAUDE.md preserved at: ${claude_file}"
                fi
                return 1
                ;;
            *)
                warn "Invalid choice '${choice}'. Please enter a, e, d, r, or n."
                ;;
        esac
    done
}

# _print_synthesis_next_steps — Instructions after successful synthesis.
_print_synthesis_next_steps() {
    echo
    success "Project synthesis complete!"
    echo
    log "Your files:"
    log "  DESIGN.md  — project design document (synthesized from codebase)"
    log "  CLAUDE.md  — project rules and improvement plan"
    echo
    log "Next steps:"
    log "  1. Review the generated files and make any manual edits"
    log "  2. Add feature milestones to CLAUDE.md as needed"
    log "  3. Run: tekhton \"Implement Milestone 1: <title>\""
    echo
}

# --- Main entry point --------------------------------------------------------

# run_project_synthesis — Main entry point for --plan-from-index.
#
# Phases:
#   1. Context assembly (load index, detection, README, etc.)
#   2. DESIGN.md generation
#   3. Completeness check + optional re-synthesis
#   4. CLAUDE.md generation
#   5. Human review menu
#
# Args: $1 = project directory
# Returns: 0 on success, 1 on failure or abort
run_project_synthesis() {
    local project_dir="${1:-${PROJECT_DIR:-.}}"

    header "Tekhton — Project Synthesis"
    log "Synthesizing DESIGN.md and CLAUDE.md from project index."
    log "Model: ${SYNTHESIS_MODEL} | Max turns: ${SYNTHESIS_MAX_TURNS}"
    echo

    # Phase 1: Context assembly
    log "Phase 1: Assembling context..."
    _assemble_synthesis_context "$project_dir" || return 1

    # Phase 2: DESIGN.md generation
    echo
    log "Phase 2: Generating DESIGN.md..."
    _synthesize_design "$project_dir" || return 1

    # Phase 3: Completeness check
    echo
    log "Phase 3: Checking DESIGN.md completeness..."
    _check_synthesis_completeness "$project_dir"

    # Phase 4: CLAUDE.md generation
    echo
    log "Phase 4: Generating CLAUDE.md..."
    _synthesize_claude "$project_dir" || return 1

    # Phase 5: Human review
    echo
    _synthesis_review_menu "$project_dir"
}
