#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# stages/intake.sh — Pre-stage 1: Task Intake / PM Agent (Pre-Stage Gate)
#
# Evaluates task and milestone clarity before committing pipeline resources.
# Silently passes well-scoped milestones; auto-tweaks or escalates as needed.
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TASK, LOG_FILE, MILESTONE_MODE, _CURRENT_MILESTONE,
#          INTAKE_AGENT_ENABLED, CLAUDE_INTAKE_MODEL, INTAKE_MAX_TURNS,
#          INTAKE_CLARITY_THRESHOLD, INTAKE_TWEAK_THRESHOLD,
#          INTAKE_CONFIRM_TWEAKS, INTAKE_AUTO_SPLIT,
#          INTAKE_ROLE_FILE, INTAKE_REPORT_FILE
# Expects: log(), warn(), success(), header(), error() from common.sh
# Expects: run_agent() from agent.sh
# Expects: render_prompt() from prompts.sh
# Expects: _intake_* helpers from lib/intake_helpers.sh
#
# Provides:
#   run_stage_intake      — pre-stage gate before Scout/Coder
#   run_intake_create     — --add-milestone create mode
# Delegates to lib/intake_helpers.sh:
#   _intake_get_milestone_content, _intake_handle_tweaked,
#   _intake_handle_split_recommended, _intake_handle_needs_clarity
# =============================================================================

# --- Main stage function ------------------------------------------------------

# run_stage_intake
# Pre-stage gate that evaluates task/milestone clarity.
# Produces INTAKE_REPORT.md with verdict and confidence score.
run_stage_intake() {
    # Skip if disabled
    if [[ "${INTAKE_AGENT_ENABLED:-true}" != "true" ]]; then
        log "Intake agent disabled (INTAKE_AGENT_ENABLED=false). Skipping."
        return 0
    fi

    # Use cached intake results from dry-run if available (Milestone 23)
    if [[ "${INTAKE_CACHED:-false}" == "true" ]] && [[ -f "${INTAKE_REPORT_FILE:-INTAKE_REPORT.md}" ]]; then
        header "Pre-stage 1 — Task Intake (cached)"
        log "Intake: using cached results from dry-run."
        local _cached_verdict
        _cached_verdict=$(_intake_parse_verdict "${INTAKE_REPORT_FILE}")
        local _cached_confidence
        _cached_confidence=$(_intake_parse_confidence "${INTAKE_REPORT_FILE}")
        export INTAKE_VERDICT="$_cached_verdict"
        export INTAKE_CONFIDENCE="$_cached_confidence"
        log "Intake verdict: ${_cached_verdict} (confidence: ${_cached_confidence})"
        # NEEDS_CLARITY still pauses even from cache — user may have answered since dry-run
        if [[ "$_cached_verdict" == "NEEDS_CLARITY" ]]; then
            _intake_handle_needs_clarity "${INTAKE_REPORT_FILE}"
        elif [[ "$_cached_verdict" == "TWEAKED" ]]; then
            _intake_handle_tweaked "${INTAKE_REPORT_FILE}"
        fi
        return 0
    fi

    # Get content to evaluate (before banner — skip silently if unchanged)
    local content
    content=$(_intake_get_milestone_content)

    if [[ -z "$content" ]]; then
        log "Intake: no content to evaluate. Passing."
        return 0
    fi

    # Check content hash — skip if already evaluated (no banner noise)
    local content_hash
    content_hash=$(_intake_content_hash "$content")
    if _intake_should_skip "$content_hash"; then
        log "Intake: content unchanged since last evaluation. Skipping."
        return 0
    fi

    header "Pre-stage 1 — Task Intake"

    # Prepare template variables
    export INTAKE_MILESTONE_CONTENT="$content"

    # Load PROJECT_INDEX.md summary if available (capped to 8KB — intake only needs
    # the overview, not full file listings). This prevents the intake agent from
    # processing 500KB+ of project index for a simple clarity evaluation.
    export INTAKE_PROJECT_INDEX=""
    if [[ -f "${PROJECT_DIR}/PROJECT_INDEX.md" ]]; then
        INTAKE_PROJECT_INDEX=$(_safe_read_file "${PROJECT_DIR}/PROJECT_INDEX.md" "PROJECT_INDEX" 8192)
    fi

    # Load intake history from causal log (when available)
    export INTAKE_HISTORY_BLOCK=""
    if [[ "${CAUSAL_LOG_ENABLED:-true}" == "true" ]] && type verdict_history &>/dev/null; then
        INTAKE_HISTORY_BLOCK=$(verdict_history "intake" 10 2>/dev/null || true)
        local rework_data
        rework_data=$(events_by_type "rework_cycle" 10 2>/dev/null || true)
        if [[ -n "$rework_data" ]]; then
            INTAKE_HISTORY_BLOCK="${INTAKE_HISTORY_BLOCK:+${INTAKE_HISTORY_BLOCK}
}Rework patterns: ${rework_data}"
        fi
    fi

    # Load health score summary (Milestone 15)
    export HEALTH_SCORE_SUMMARY=""
    if [[ "${HEALTH_ENABLED:-true}" == "true" ]] && command -v format_health_summary &>/dev/null; then
        HEALTH_SCORE_SUMMARY=$(format_health_summary "${PROJECT_DIR}" 2>/dev/null || true)
    fi

    # Load role file content
    local role_file="${PROJECT_DIR}/${INTAKE_ROLE_FILE}"
    export INTAKE_ROLE_CONTENT=""
    if [[ -f "$role_file" ]]; then
        INTAKE_ROLE_CONTENT=$(_safe_read_file "$role_file" "INTAKE_ROLE")
    fi

    # Inject related human notes context (M25)
    export NOTES_CONTEXT_BLOCK=""
    if [[ -f "HUMAN_NOTES.md" ]] && command -v extract_human_notes &>/dev/null; then
        local all_notes
        all_notes=$(NOTES_FILTER="" extract_human_notes 2>/dev/null || true)
        if [[ -n "$all_notes" ]]; then
            # Simple keyword overlap: include notes if any word from the task
            # appears in the notes (case-insensitive, 4+ char words only)
            local task_words
            task_words=$(echo "${TASK:-}" | tr '[:upper:]' '[:lower:]' | grep -oE '[a-z]{4,}' | sort -u || true)
            local matching_notes=""
            while IFS= read -r note_line; do
                [[ -z "$note_line" ]] && continue
                local note_lower
                note_lower=$(echo "$note_line" | tr '[:upper:]' '[:lower:]')
                while IFS= read -r word; do
                    [[ -z "$word" ]] && continue
                    if [[ "$note_lower" == *"$word"* ]]; then
                        matching_notes="${matching_notes}${note_line}
"
                        break
                    fi
                done <<< "$task_words"
            done <<< "$all_notes"
            if [[ -n "$matching_notes" ]]; then
                NOTES_CONTEXT_BLOCK="$matching_notes"
            fi
        fi
    fi

    # Render and run the intake scan agent
    local intake_prompt
    intake_prompt=$(render_prompt "intake_scan")

    log "Running intake evaluation (model: ${CLAUDE_INTAKE_MODEL}, turns: ${INTAKE_MAX_TURNS})..."

    run_agent \
        "Intake" \
        "$CLAUDE_INTAKE_MODEL" \
        "$INTAKE_MAX_TURNS" \
        "$intake_prompt" \
        "$LOG_FILE"

    # Parse the report
    local report_file="${INTAKE_REPORT_FILE}"
    local verdict
    verdict=$(_intake_parse_verdict "$report_file")
    local confidence
    confidence=$(_intake_parse_confidence "$report_file")

    log "Intake verdict: ${verdict} (confidence: ${confidence})"

    # Export for metrics and downstream use
    export INTAKE_VERDICT="$verdict"
    export INTAKE_CONFIDENCE="$confidence"

    # Save content hash — evaluation complete
    _intake_save_hash "$content_hash"

    # Handle verdict
    case "$verdict" in
        PASS)
            success "Intake: task is clear. Proceeding."
            ;;

        TWEAKED)
            _intake_handle_tweaked "$report_file"
            ;;

        SPLIT_RECOMMENDED)
            _intake_handle_split_recommended "$report_file"
            ;;

        NEEDS_CLARITY)
            _intake_handle_needs_clarity "$report_file"
            ;;
    esac

    return 0
}

# --- Create mode (--add-milestone) -------------------------------------------

# run_intake_create DESCRIPTION
# Evaluates and creates a new milestone using the intake agent.
# Writes milestone file to MILESTONE_DIR and appends to MANIFEST.cfg.
run_intake_create() {
    local description="$1"

    if [[ -z "$description" ]]; then
        error "--add-milestone requires a description."
        exit 1
    fi

    header "Intake: Create Milestone"

    # Set up minimal pipeline globals for agent invocation
    export INTAKE_MILESTONE_CONTENT="$description"
    export INTAKE_PROJECT_INDEX=""
    export INTAKE_HISTORY_BLOCK=""
    export INTAKE_ROLE_CONTENT=""
    export INTAKE_CREATE_MODE="true"

    if [[ -f "${PROJECT_DIR}/PROJECT_INDEX.md" ]]; then
        INTAKE_PROJECT_INDEX=$(_safe_read_file "${PROJECT_DIR}/PROJECT_INDEX.md" "PROJECT_INDEX" 8192)
    fi

    local role_file="${PROJECT_DIR}/${INTAKE_ROLE_FILE}"
    if [[ -f "$role_file" ]]; then
        INTAKE_ROLE_CONTENT=$(_safe_read_file "$role_file" "INTAKE_ROLE")
    fi

    # Render and run the intake agent in create mode
    # Create mode uses Opus (needs to generate quality milestone content)
    local intake_prompt
    intake_prompt=$(render_prompt "intake_scan")

    log "Evaluating milestone description (model: ${CLAUDE_INTAKE_MODEL})..."

    run_agent \
        "Intake Create" \
        "$CLAUDE_INTAKE_MODEL" \
        "$INTAKE_MAX_TURNS" \
        "$intake_prompt" \
        "${LOG_DIR:-/tmp}/intake_create.log"

    local report_file="${INTAKE_REPORT_FILE}"
    if [[ ! -f "$report_file" ]]; then
        error "Intake agent did not produce ${report_file}."
        exit 1
    fi

    local verdict
    verdict=$(_intake_parse_verdict "$report_file")

    if [[ "$verdict" == "NEEDS_CLARITY" ]]; then
        warn "Description is too ambiguous. Questions:"
        _intake_parse_questions "$report_file"
        warn "Refine your description and try again."
        exit 1
    fi

    # Extract milestone content (tweaked version if available, otherwise original)
    local ms_content
    if [[ "$verdict" == "TWEAKED" ]]; then
        ms_content=$(_intake_parse_tweaks "$report_file")
    fi
    if [[ -z "${ms_content:-}" ]]; then
        ms_content=$(awk '/^## Milestone Content/{found=1; next} found && /^## /{exit} found{print}' "$report_file" 2>/dev/null || true)
    fi
    if [[ -z "$ms_content" ]]; then
        # Fallback: use description directly
        ms_content="#### Milestone: ${description}

Acceptance criteria:
- (generated by intake agent — review and refine)
"
    fi

    # Determine next milestone ID
    local manifest_file="${MILESTONE_DIR}/${MILESTONE_MANIFEST:-MANIFEST.cfg}"
    local next_id="m01"
    if [[ -f "$manifest_file" ]]; then
        local max_num=0
        while IFS='|' read -r mid _ _ _ _ _; do
            [[ "$mid" =~ ^# ]] && continue
            [[ -z "$mid" ]] && continue
            local num_part="${mid#m}"
            num_part="${num_part#0}"
            if [[ "$num_part" =~ ^[0-9]+$ ]] && [[ "$num_part" -gt "$max_num" ]]; then
                max_num="$num_part"
            fi
        done < "$manifest_file"
        local next_num=$((max_num + 1))
        next_id=$(printf "m%02d" "$next_num")
    fi

    # Create milestone file
    mkdir -p "$MILESTONE_DIR"
    local ms_file="${MILESTONE_DIR}/${next_id}.md"
    # Extract a short title from the first line of content or description
    local short_title
    short_title=$(echo "$description" | head -1 | cut -c1-60)

    local tmpfile
    tmpfile=$(mktemp "${MILESTONE_DIR}/create.XXXXXX")
    cat > "$tmpfile" << MSEOF
#### Milestone ${next_id#m0}: ${short_title}
<!-- milestone-meta
id: "${next_id#m0}"
status: "pending"
-->
<!-- PM-tweaked: $(date '+%Y-%m-%d') -->

${ms_content}
MSEOF
    mv -f "$tmpfile" "$ms_file"

    # Append to manifest
    local manifest_entry="${next_id}|${short_title}|pending||${next_id}.md|"
    if [[ -f "$manifest_file" ]]; then
        echo "$manifest_entry" >> "$manifest_file"
    else
        cat > "$manifest_file" << MFEOF
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
${manifest_entry}
MFEOF
    fi

    success "Created milestone ${next_id}: ${short_title}"
    log "  File: ${ms_file}"
    log "  Manifest: ${manifest_file}"
    echo
    log "Review the milestone file and run: tekhton --milestone \"Implement Milestone ${next_id#m0}: ${short_title}\""
}
