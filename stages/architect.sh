#!/usr/bin/env bash
# =============================================================================
# stages/architect.sh — Stage 0: Architect audit (conditional)
#
# Sourced by tekhton.sh — do not run directly.
# Expects all pipeline globals to be set.
# Runs BEFORE the main task's coder stage when drift thresholds are exceeded.
# =============================================================================

# run_stage_architect — Runs the architect audit:
#   1. Guard: verify drift threshold is actually exceeded (or --force-audit)
#   2. Load drift log and architecture log content for prompt
#   3. Invoke architect agent
#   4. Parse ARCHITECT_PLAN.md sections
#   5. Route sr coder items (Simplification)
#   6. Route jr coder items (Staleness, Dead Code, Naming)
#   7. Run build gate after coders
#   8. Run expedited reviewer (single cycle, no rework loop)
#   9. Mark addressed observations as RESOLVED in DRIFT_LOG.md
#  10. Append Design Doc Observations to HUMAN_ACTION_REQUIRED.md
#  11. Reset runs-since-audit counter
run_stage_architect() {
    header "Stage 0 — Architect Audit"

    # --- Load context for prompt ---------------------------------------------

    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    local adl_file="${PROJECT_DIR}/${ARCHITECTURE_LOG_FILE}"

    export DRIFT_LOG_CONTENT="(No drift log found)"
    if [ -f "$drift_file" ]; then
        DRIFT_LOG_CONTENT=$(cat "$drift_file")
    fi

    export ARCHITECTURE_LOG_CONTENT="(No architecture decision log found)"
    if [ -f "$adl_file" ]; then
        ARCHITECTURE_LOG_CONTENT=$(cat "$adl_file")
    fi

    export ARCHITECTURE_CONTENT="(No architecture file found)"
    if [ -f "${ARCHITECTURE_FILE}" ]; then
        ARCHITECTURE_CONTENT=$(cat "${ARCHITECTURE_FILE}")
    fi

    DRIFT_OBSERVATION_COUNT=$(count_drift_observations)

    # Dependency constraints (P5 — optional, may not exist yet)
    export DEPENDENCY_CONSTRAINTS_CONTENT=""
    if [ -n "${DEPENDENCY_CONSTRAINTS_FILE:-}" ] && [ -f "${DEPENDENCY_CONSTRAINTS_FILE}" ]; then
        DEPENDENCY_CONSTRAINTS_CONTENT=$(cat "${DEPENDENCY_CONSTRAINTS_FILE}")
    fi

    # --- Invoke architect agent ----------------------------------------------

    local architect_model="${CLAUDE_ARCHITECT_MODEL:-${CLAUDE_STANDARD_MODEL}}"
    local architect_turns="${ARCHITECT_MAX_TURNS}"
    if [ "$MILESTONE_MODE" = true ]; then
        architect_turns="${MILESTONE_ARCHITECT_MAX_TURNS}"
    fi

    ARCHITECT_PROMPT=$(render_prompt "architect")

    log "Invoking architect agent (${DRIFT_OBSERVATION_COUNT} observations, max ${architect_turns} turns)..."
    run_agent \
        "Architect" \
        "$architect_model" \
        "$architect_turns" \
        "$ARCHITECT_PROMPT" \
        "$LOG_FILE" \
        "$AGENT_TOOLS_ARCHITECT"
    print_run_summary
    success "Architect agent finished."

    # --- Validate output -----------------------------------------------------

    if [ ! -f "ARCHITECT_PLAN.md" ]; then
        warn "Architect did not produce ARCHITECT_PLAN.md. Skipping remediation."
        warn "Drift observations remain unresolved — will retry next audit cycle."
        return 0
    fi

    log "ARCHITECT_PLAN.md produced. Parsing sections..."

    # --- Parse plan sections -------------------------------------------------

    local has_simplification=0
    local has_jr_work=0

    # Check for non-empty Simplification section
    local simplification_content
    simplification_content=$(awk '/^## Simplification/{found=1; next} found && /^##/{exit} found{print}' \
        ARCHITECT_PLAN.md 2>/dev/null || true)
    if [ -n "$simplification_content" ] && ! echo "$simplification_content" | grep -qiE '^\s*-?\s*None\s*$'; then
        has_simplification=1
    fi

    # Check for non-empty jr coder sections (Staleness, Dead Code, Naming)
    for section in "Staleness Fixes" "Dead Code Removal" "Naming Normalization"; do
        local section_content
        section_content=$(awk -v sect="$section" '/^## /{if($0 ~ sect){found=1; next}else if(found){exit}} found{print}' \
            ARCHITECT_PLAN.md 2>/dev/null || true)
        if [ -n "$section_content" ] && ! echo "$section_content" | grep -qiE '^\s*-?\s*None\s*$'; then
            has_jr_work=1
            break
        fi
    done

    # --- Route to coders -----------------------------------------------------

    if [ "$has_simplification" -eq 1 ]; then
        log "Simplification items found — routing to senior coder..."

        ARCHITECT_SR_PROMPT=$(render_prompt "architect_sr_rework")

        run_agent \
            "Coder (architect remediation)" \
            "$CLAUDE_CODER_MODEL" \
            "$CODER_MAX_TURNS" \
            "$ARCHITECT_SR_PROMPT" \
            "$LOG_FILE" \
            "$AGENT_TOOLS_CODER"
        print_run_summary
        success "Senior coder remediation finished."
    else
        log "No Simplification items — skipping senior coder."
    fi

    if [ "$has_jr_work" -eq 1 ]; then
        log "Staleness/Dead Code/Naming items found — routing to jr coder..."

        ARCHITECT_JR_PROMPT=$(render_prompt "architect_jr_rework")

        run_agent \
            "Jr Coder (architect remediation)" \
            "$CLAUDE_JR_CODER_MODEL" \
            "$JR_CODER_MAX_TURNS" \
            "$ARCHITECT_JR_PROMPT" \
            "$LOG_FILE" \
            "$AGENT_TOOLS_JR_CODER"
        print_run_summary
        success "Jr coder remediation finished."
    else
        log "No Staleness/Dead Code/Naming items — skipping jr coder."
    fi

    # --- Build gate after remediation ----------------------------------------

    if [ "$has_simplification" -eq 1 ] || [ "$has_jr_work" -eq 1 ]; then
        if ! run_build_gate "post-architect-remediation"; then
            warn "Build gate failed after architect remediation."
            warn "Attempting build fix..."

            BUILD_FIX_PROMPT=$(render_prompt "build_fix_minimal")
            run_agent \
                "Coder (architect build fix)" \
                "$CLAUDE_CODER_MODEL" \
                "$((CODER_MAX_TURNS / 3))" \
                "$BUILD_FIX_PROMPT" \
                "$LOG_FILE" \
                "$AGENT_TOOLS_BUILD_FIX"

            if ! run_build_gate "post-architect-remediation-retry"; then
                warn "Build still broken after architect remediation. Skipping review."
                warn "Drift observations NOT resolved — will retry next audit cycle."
                reset_runs_since_audit
                return 0
            fi
        fi

        # --- Expedited review ------------------------------------------------

        log "Running expedited review of architect remediation..."

        export ARCHITECTURE_CONTENT
        ARCHITECTURE_CONTENT=$([ -f "${ARCHITECTURE_FILE}" ] && cat "${ARCHITECTURE_FILE}" || echo "(not found)")
        export PRIOR_BLOCKERS_BLOCK=""
        ARCHITECT_REVIEW_PROMPT=$(render_prompt "architect_review")

        run_agent \
            "Reviewer (architect expedited)" \
            "$CLAUDE_STANDARD_MODEL" \
            "$REVIEWER_MAX_TURNS" \
            "$ARCHITECT_REVIEW_PROMPT" \
            "$LOG_FILE" \
            "$AGENT_TOOLS_REVIEWER"
        print_run_summary
        success "Expedited review finished."
    fi

    # --- Resolve drift observations ------------------------------------------

    # Extract the "Drift Observations to Resolve" section from the plan
    local resolve_section
    resolve_section=$(awk '/^## Drift Observations to Resolve/{found=1; next} found && /^##/{exit} found{print}' \
        ARCHITECT_PLAN.md 2>/dev/null || true)

    if [ -n "$resolve_section" ]; then
        log "Marking addressed drift observations as resolved..."
        # Build pattern list from resolve section lines
        local resolve_patterns=()
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/^[[:space:]]*//')
            [ -z "$line" ] && continue
            # Skip placeholder / boilerplate lines
            echo "$line" | grep -qiE '^\s*None\b' && continue
            echo "$line" | grep -qE '^\s*-+\s*$' && continue
            # Escape regex special characters for safe grep matching
            local escaped
            # shellcheck disable=SC2016
            escaped=$(printf '%s' "$line" | sed 's/[.[\*^$()+?{|]/\\&/g')
            resolve_patterns+=("$escaped")
        done <<< "$resolve_section"

        if [ ${#resolve_patterns[@]} -gt 0 ]; then
            resolve_drift_observations "${resolve_patterns[@]}"
            log "Resolved ${#resolve_patterns[@]} observation(s) in drift log."
        fi
    fi

    # --- Surface design doc observations to human ----------------------------

    local design_section
    design_section=$(awk '/^## Design Doc Observations/{found=1; next} found && /^##/{exit} found{print}' \
        ARCHITECT_PLAN.md 2>/dev/null || true)

    if [ -n "$design_section" ]; then
        # Filter out non-actionable lines: section subtitles, separators, "None"
        local filtered_lines=""
        while IFS= read -r line; do
            local cleaned
            cleaned=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/^[[:space:]]*//')
            [ -z "$cleaned" ] && continue
            # Skip placeholder / boilerplate lines
            echo "$cleaned" | grep -qiE '^\s*-?\s*None\.?\s*$' && continue
            echo "$cleaned" | grep -qE '^\s*-+\s*$' && continue
            echo "$cleaned" | grep -qiE '^\*?\(route to human' && continue
            filtered_lines+="${cleaned}"$'\n'
        done <<< "$design_section"

        # Only append if there are real actionable lines
        filtered_lines=$(echo "$filtered_lines" | sed '/^$/d')
        if [ -n "$filtered_lines" ]; then
            log "Adding design doc observations to human action file..."
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                append_human_action "architect" "$line"
            done <<< "$filtered_lines"
        fi
    fi

    # --- Reset audit counter -------------------------------------------------

    reset_runs_since_audit
    log "Runs-since-audit counter reset."

    # --- Archive and clean up plan -------------------------------------------

    if [ -f "ARCHITECT_PLAN.md" ]; then
        mv "ARCHITECT_PLAN.md" "${LOG_DIR}/${TIMESTAMP}_ARCHITECT_PLAN.md"
        log "ARCHITECT_PLAN.md archived and removed from working directory."
    fi

    success "Architect audit complete."
}
