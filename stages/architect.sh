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
        DRIFT_LOG_CONTENT=$(_wrap_file_content "DRIFT_LOG" "$(_safe_read_file "$drift_file" "DRIFT_LOG")")
    fi

    export ARCHITECTURE_LOG_CONTENT="(No architecture decision log found)"
    if [ -f "$adl_file" ]; then
        ARCHITECTURE_LOG_CONTENT=$(_wrap_file_content "ARCHITECTURE_LOG" "$(_safe_read_file "$adl_file" "ARCHITECTURE_LOG")")
    fi

    export ARCHITECTURE_CONTENT="(No architecture file found)"
    if [ -f "${ARCHITECTURE_FILE}" ]; then
        ARCHITECTURE_CONTENT=$(_wrap_file_content "ARCHITECTURE" "$(_safe_read_file "${ARCHITECTURE_FILE}" "ARCHITECTURE_FILE")")
    fi

    DRIFT_OBSERVATION_COUNT=$(count_drift_observations)

    # Dependency constraints (P5 — optional, may not exist yet)
    export DEPENDENCY_CONSTRAINTS_CONTENT=""
    if [ -n "${DEPENDENCY_CONSTRAINTS_FILE:-}" ] && [ -f "${DEPENDENCY_CONSTRAINTS_FILE}" ]; then
        DEPENDENCY_CONSTRAINTS_CONTENT=$(_wrap_file_content "DEPENDENCY_CONSTRAINTS" "$(_safe_read_file "${DEPENDENCY_CONSTRAINTS_FILE}" "DEPENDENCY_CONSTRAINTS")")
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

    # --- UPSTREAM error detection (12.2) ----------------------------------------

    if [[ "${AGENT_ERROR_CATEGORY:-}" = "UPSTREAM" ]]; then
        warn "Architect hit an API error (${AGENT_ERROR_SUBCATEGORY}): ${AGENT_ERROR_MESSAGE}"
        warn "Drift observations remain unresolved — will retry next audit cycle."
        return 0
    fi

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
        if [ -f "${ARCHITECTURE_FILE}" ]; then
            ARCHITECTURE_CONTENT=$(_wrap_file_content "ARCHITECTURE" "$(_safe_read_file "${ARCHITECTURE_FILE}" "ARCHITECTURE_FILE")")
        else
            ARCHITECTURE_CONTENT="(not found)"
        fi
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

    local pre_resolve_count
    pre_resolve_count=$(count_drift_observations)

    if [ "$pre_resolve_count" -gt 0 ]; then
        # Extract Out of Scope items — these stay unresolved for next audit cycle
        local oos_section
        oos_section=$(awk '/^## Out of Scope/{found=1; next} found && /^##/{exit} found{print}' \
            ARCHITECT_PLAN.md 2>/dev/null || true)

        local oos_items=()
        if [ -n "$oos_section" ]; then
            # Join multi-line bullets: accumulate continuation lines (lines
            # that don't start with a bullet marker) into the previous bullet.
            local _oos_current=""
            local cleaned
            while IFS= read -r line; do
                cleaned="${line#"${line%%[![:space:]]*}"}"
                [ -z "$cleaned" ] && continue
                if [[ "$cleaned" =~ ^[-*][[:space:]]+(.*) ]]; then
                    # New bullet — flush previous
                    if [ -n "$_oos_current" ]; then
                        oos_items+=("$_oos_current")
                    fi
                    _oos_current="${BASH_REMATCH[1]}"
                else
                    # Continuation line — append to current bullet
                    if [ -n "$_oos_current" ]; then
                        _oos_current="${_oos_current} ${cleaned}"
                    else
                        _oos_current="$cleaned"
                    fi
                fi
            done <<< "$oos_section"
            # Flush last bullet
            if [ -n "$_oos_current" ]; then
                oos_items+=("$_oos_current")
            fi

            # Filter out placeholder entries
            local _filtered_oos=()
            for entry in "${oos_items[@]}"; do
                echo "$entry" | grep -qiE '^\s*None\b' && continue
                echo "$entry" | grep -qiE '^\s*N/?A\b' && continue
                echo "$entry" | grep -qiE '^No (items?|observations?)\b' && continue
                echo "$entry" | grep -qE '^\s*-+\s*$' && continue
                _filtered_oos+=("$entry")
            done
            oos_items=("${_filtered_oos[@]+"${_filtered_oos[@]}"}")
        fi

        # Resolve ALL unresolved observations — the architect reviewed them all.
        # This replaces fragile pattern-matching that silently failed when the
        # architect paraphrased observations instead of copying them verbatim.
        log "Resolving all ${pre_resolve_count} drift observations..."
        resolve_all_drift_observations

        # Re-add Out of Scope items as new unresolved entries
        if [ ${#oos_items[@]} -gt 0 ]; then
            log "Re-adding ${#oos_items[@]} out-of-scope item(s) to drift log..."
            append_drift_entries "${oos_items[@]}"
        fi

        local post_resolve_count
        post_resolve_count=$(count_drift_observations)
        log "Drift resolution: ${pre_resolve_count} → ${post_resolve_count} unresolved."
    fi

    # --- Surface design doc observations to human ----------------------------

    local design_section
    design_section=$(awk '/^## Design Doc Observations/{found=1; next} found && /^##/{exit} found{print}' \
        ARCHITECT_PLAN.md 2>/dev/null || true)

    if [ -n "$design_section" ]; then
        # Join multi-line bullets, then filter out non-actionable entries.
        local _design_items=()
        local _ds_current=""
        local cleaned
        while IFS= read -r line; do
            cleaned="${line#"${line%%[![:space:]]*}"}"
            [ -z "$cleaned" ] && continue
            if [[ "$cleaned" =~ ^[-*][[:space:]]+(.*) ]]; then
                # New bullet — flush previous
                if [ -n "$_ds_current" ]; then
                    _design_items+=("$_ds_current")
                fi
                _ds_current="${BASH_REMATCH[1]}"
            else
                # Continuation line
                if [ -n "$_ds_current" ]; then
                    _ds_current="${_ds_current} ${cleaned}"
                else
                    _ds_current="$cleaned"
                fi
            fi
        done <<< "$design_section"
        if [ -n "$_ds_current" ]; then
            _design_items+=("$_ds_current")
        fi

        # Filter out placeholder / boilerplate entries
        local _filtered_design=()
        for entry in "${_design_items[@]+"${_design_items[@]}"}"; do
            echo "$entry" | grep -qiE '^\s*None\b' && continue
            echo "$entry" | grep -qiE '^\s*N/?A\b' && continue
            echo "$entry" | grep -qiE '^No (design|doc|observations?|issues?|action|items?)\b' && continue
            echo "$entry" | grep -qiE '^(All|No) (drift |design )?(observations?|items?) (are|have been|were)\b' && continue
            echo "$entry" | grep -qiE '^Nothing (to|requiring|needs)\b' && continue
            echo "$entry" | grep -qE '^\s*-+\s*$' && continue
            echo "$entry" | grep -qiE '^\*?\(route to human' && continue
            _filtered_design+=("$entry")
        done

        if [ ${#_filtered_design[@]} -gt 0 ]; then
            log "Adding design doc observations to human action file..."
            for entry in "${_filtered_design[@]}"; do
                append_human_action "architect" "$entry"
            done
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
