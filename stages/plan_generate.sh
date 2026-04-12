#!/usr/bin/env bash
# =============================================================================
# stages/plan_generate.sh — Planning phase: CLAUDE.md generation
#
# Reads the completed ${DESIGN_FILE} and generates a full CLAUDE.md with project
# rules, milestone plan, architecture guidelines, and testing strategy.
# Uses _call_planning_batch() to call Claude in batch mode.
# The shell writes CLAUDE.md to disk.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PLAN_GENERATION_MODEL, PLAN_GENERATION_MAX_TURNS, PROJECT_DIR,
#          TEKHTON_HOME
# Expects: log(), success(), warn(), error(), header() from common.sh
# Expects: render_prompt(), _call_planning_batch() from lib/plan.sh
# Expects: _insert_milestone_pointer() from lib/milestone_dag_migrate.sh
# =============================================================================
set -euo pipefail

# Minimum line count to consider on-disk content "substantive" (shared with
# plan_interview.sh — kept in sync as a named constant for easy tuning).
_MIN_SUBSTANTIVE_LINES=20

# run_plan_generate — Generate CLAUDE.md from ${DESIGN_FILE} using a batch call.
#
# Reads ${DESIGN_FILE}, renders the generation prompt, calls _call_planning_batch()
# to get the CLAUDE.md content as text output, and writes it to disk.
# The shell captures text output and writes the file.
#
# Returns 0 if CLAUDE.md was produced, 1 otherwise.
run_plan_generate() {
    # shellcheck disable=SC2153
    local design_file="${PROJECT_DIR}/${DESIGN_FILE}"

    if [[ ! -f "$design_file" ]]; then
        error "${DESIGN_FILE} not found at ${design_file} — cannot generate CLAUDE.md."
        return 1
    fi

    local log_dir="${PROJECT_DIR}/.claude/logs"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${log_dir}/${timestamp}_plan-generate.log"

    mkdir -p "$log_dir"

    # Set template variables for prompt rendering
    export DESIGN_CONTENT
    DESIGN_CONTENT=$(cat "$design_file")

    # Render the generation prompt
    local prompt
    prompt=$(render_prompt "plan_generate")

    header "CLAUDE.md Generation"
    log "Model: ${PLAN_GENERATION_MODEL}"
    log "Max turns: ${PLAN_GENERATION_MAX_TURNS}"
    log "Log: ${log_file}"
    echo
    log "Generating CLAUDE.md from ${DESIGN_FILE}..."

    # Write session metadata to log
    {
        echo "=== Tekhton Plan Generation ==="
        echo "Date: $(date)"
        echo "Model: ${PLAN_GENERATION_MODEL}"
        echo "Max Turns: ${PLAN_GENERATION_MAX_TURNS}"
        echo "Design file: ${design_file} ($(count_lines < "$design_file") lines)"
        echo "=== System Prompt ==="
        echo "$prompt"
        echo "=== Session Start ==="
    } > "$log_file"

    # Call claude in batch mode — shell captures output and writes CLAUDE.md.
    # Claude outputs text only via _call_planning_batch(); shell writes the file.
    local claude_md_content=""
    local batch_exit=0
    local claude_md="${PROJECT_DIR}/CLAUDE.md"

    claude_md_content=$(_call_planning_batch \
        "$PLAN_GENERATION_MODEL" \
        "$PLAN_GENERATION_MAX_TURNS" \
        "$prompt" \
        "$log_file") || batch_exit=$?

    # Guard against tool-write overwrite: if Claude used the Write tool to create
    # CLAUDE.md (substantive content on disk) and returned only a summary as text
    # output, the captured text won't start with a markdown heading. Detect this
    # and preserve the on-disk version.
    local _disk_rescued=false
    if [[ -n "$claude_md_content" ]] && [[ -f "$claude_md" ]]; then
        local _captured_first
        _captured_first=$(printf '%s\n' "$claude_md_content" | head -1)
        if [[ "$_captured_first" != "#"* ]]; then
            local _disk_lines _disk_first
            _disk_first=$(head -1 "$claude_md")
            _disk_lines=$(count_lines < "$claude_md")
            if [[ "$_disk_first" == "#"* ]] && [[ "$_disk_lines" -gt "$_MIN_SUBSTANTIVE_LINES" ]]; then
                log "Detected tool-written CLAUDE.md (${_disk_lines} lines on disk) — using on-disk version."
                claude_md_content=$(cat "$claude_md")
                _disk_rescued=true
            fi
        fi
    fi

    # Trim preamble lines (e.g. "I have enough context...") before the first
    # top-level heading, unless we already rescued the on-disk version.
    if [[ -n "$claude_md_content" ]] && [[ "$_disk_rescued" == "false" ]]; then
        claude_md_content=$(printf '%s' "$claude_md_content" | _trim_document_preamble)
    fi

    {
        echo "=== Session End ==="
        echo "Exit code: ${batch_exit}"
        echo "Turns used: 1"
        echo "Date: $(date)"
    } >> "$log_file"

    echo

    if [[ -n "$claude_md_content" ]]; then
        if [[ "$_disk_rescued" == "false" ]]; then
            printf '%s\n' "$claude_md_content" > "$claude_md"
        fi
        # Append tekhton-managed marker for artifact detection
        if ! grep -q '<!-- tekhton-managed -->' "$claude_md" 2>/dev/null; then
            echo "<!-- tekhton-managed -->" >> "$claude_md"
        fi
        local line_count
        line_count=$(count_lines < "$claude_md")
        if [[ "$_disk_rescued" == "true" ]]; then
            success "CLAUDE.md preserved from tool-written version (${line_count} lines)."
        else
            success "CLAUDE.md generated (${line_count} lines)."
        fi

        # Post-process: extract milestones into DAG files if enabled
        if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
           && declare -f migrate_inline_milestones &>/dev/null; then
            local milestone_dir="${PROJECT_DIR}/${MILESTONE_DIR:-.claude/milestones}"
            if parse_milestones "$claude_md" >/dev/null 2>&1; then
                log "Extracting milestones from CLAUDE.md into DAG files..."
                if migrate_inline_milestones "$claude_md" "$milestone_dir"; then
                    success "Milestones extracted to ${milestone_dir}/"
                    # Insert a pointer comment in CLAUDE.md
                    _insert_milestone_pointer "$claude_md" "$milestone_dir"
                else
                    warn "Milestone extraction failed — milestones remain inline in CLAUDE.md"
                fi
            fi
        fi

        log "Log saved: ${log_file}"
        return 0
    else
        warn "Generation produced no output — CLAUDE.md was not created."
        [[ "$batch_exit" -ne 0 ]] && warn "Claude exited with code ${batch_exit}."
        log "Log saved: ${log_file}"
        return 1
    fi
}

