#!/usr/bin/env bash
# =============================================================================
# stages/coder.sh — Stage 1: Coder (scout + implement + gates)
#
# Sourced by tekhton.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, TIMESTAMP, etc.)
# =============================================================================

# run_stage_coder — Runs the full coder stage including:
#   1. Optional scout sub-agent (for BUG/FEAT notes)
#   2. Context block construction (architecture, glossary, milestone, prior reports)
#   3. Coder agent invocation
#   4. IN PROGRESS / turn-limit handling with state save
#   5. Completion gate
#   6. Build gate with one retry
#
# Exits the pipeline (exit 1) on unrecoverable failure, saving state for resume.
# On success, CODER_SUMMARY.md exists and the build passes.
run_stage_coder() {
    header "Stage 1 / 3 — Coder"

    # --- Scout sub-agent (optional) ------------------------------------------
    BUG_SCOUT_CONTEXT=""
    SHOULD_SCOUT=false

    if [ "$NOTES_FILTER" = "BUG" ] && [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
        SHOULD_SCOUT=true
    elif [ "$NOTES_FILTER" = "FEAT" ] && [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
        # Only scout features that extend existing systems — not greenfield work
        if echo "$TASK$(extract_human_notes)" | grep -qiE "extend|add to|modify|integrate|update|change|existing"; then
            SHOULD_SCOUT=true
        fi
    elif [ "${DYNAMIC_TURNS_ENABLED}" = "true" ]; then
        # Scout for complexity estimation even without human notes
        SHOULD_SCOUT=true
    fi

    if [ "$SHOULD_SCOUT" = true ]; then
        log "Running scout agent to locate relevant files and estimate complexity..."

        export HUMAN_NOTES_CONTENT
        HUMAN_NOTES_CONTENT=$(extract_human_notes)

        # Build architecture block for scout if available
        ARCHITECTURE_BLOCK=""
        if [ -f "${ARCHITECTURE_FILE}" ]; then
            ARCHITECTURE_BLOCK="
## Architecture Map (use this to find files — do NOT explore blindly)
$(cat "${ARCHITECTURE_FILE}")"
        fi

        SCOUT_PROMPT=$(render_prompt "scout")

        run_agent \
            "Scout" \
            "$CLAUDE_SCOUT_MODEL" \
            "${SCOUT_MAX_TURNS}" \
            "$SCOUT_PROMPT" \
            "$LOG_FILE"

        if [ -f "SCOUT_REPORT.md" ]; then
            print_run_summary
            success "Scout agent finished. Relevant files located."

            # Parse complexity estimate before archiving the report
            apply_scout_turn_limits "SCOUT_REPORT.md"

            BUG_SCOUT_CONTEXT="
## Scout Report (pre-located relevant files — read THESE files, not the whole project)
$(cat SCOUT_REPORT.md)
"
            # Archive scout report with the run
            cp "SCOUT_REPORT.md" "${LOG_DIR}/${TIMESTAMP}_SCOUT_REPORT.md"
            rm "SCOUT_REPORT.md"
        elif was_null_run; then
            print_run_summary
            warn "Scout was a null run (${LAST_AGENT_TURNS} turns) — coder will explore independently."
        else
            warn "Scout agent did not produce SCOUT_REPORT.md — coder will explore independently."
        fi
    fi

    # --- Build context blocks for prompt template ----------------------------

    # Human notes block
    HUMAN_NOTES_BLOCK=""
    if [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
        case "$NOTES_FILTER" in
            BUG)
                NOTE_GUIDANCE="${NOTES_GUIDANCE_BUG:-These are confirmed bugs. The scout report below has already located the relevant files — read THOSE files first, not the whole project. Find the root cause, fix it, then document your Root Cause Analysis in CODER_SUMMARY.md.}"
                ;;
            FEAT)
                local _default_feat="These are new feature requests. Read ${PROJECT_RULES_FILE} and ${ARCHITECTURE_FILE} before writing any code. New configurable values must use the project's config system — never hardcoded."
                NOTE_GUIDANCE="${NOTES_GUIDANCE_FEAT:-$_default_feat}"
                ;;
            POLISH)
                NOTE_GUIDANCE="${NOTES_GUIDANCE_POLISH:-These are visual/UX polish items. No logic changes. Focus only on UI files and config.}"
                ;;
            *)
                NOTE_GUIDANCE="${NOTES_GUIDANCE_DEFAULT:-Implement scoped items directly. Flag anything ambiguous or architectural in CODER_SUMMARY.md.}"
                ;;
        esac

        export HUMAN_NOTES_BLOCK
        HUMAN_NOTES_BLOCK="
## Human Notes [${NOTES_FILTER:-ALL}]
${NOTE_GUIDANCE}

$(extract_human_notes)
${BUG_SCOUT_CONTEXT}"
    fi

    # Architecture context
    export ARCHITECTURE_BLOCK=""
    if [ -f "${ARCHITECTURE_FILE}" ]; then
        ARCHITECTURE_BLOCK="
## Architecture Map (read FIRST — saves you 10+ turns of exploration)
$(cat "${ARCHITECTURE_FILE}")"
    fi

    export GLOSSARY_BLOCK=""
    if [ -n "${GLOSSARY_FILE}" ] && [ -f "${GLOSSARY_FILE}" ]; then
        GLOSSARY_BLOCK="
## Glossary (use these terms precisely — do not invent synonyms)
$(cat "${GLOSSARY_FILE}")"
    fi

    export MILESTONE_BLOCK=""
    if [ "$MILESTONE_MODE" = true ]; then
        MILESTONE_BLOCK="
## Milestone Mode
This is a milestone-sized task. Before writing any code:
1. Read the relevant Milestone section in ${PROJECT_RULES_FILE} in full
2. Check the 'Seeds forward' annotations on this milestone for architectural decisions
   that must be made now to avoid rework later
3. Note any 'Watch for' annotations and design those extension points into your implementation
4. Document your architectural decisions in CODER_SUMMARY.md under '## Architecture Decisions'"
    fi

    # Prior reviewer context (unresolved blockers from a previous run)
    export PRIOR_REVIEWER_CONTEXT=""
    if [ -f "REVIEWER_REPORT.md" ] && [ "$START_AT" = "coder" ]; then
        PRIOR_REVIEWER_CONTEXT="
## Prior Reviewer Report (unresolved blockers from last run)
The previous pipeline run ended with these unresolved items.
Fix the Complex and Simple Blockers listed below — do not re-implement anything already done.
Non-Blocking Notes are optional improvements if turns allow.

$(cat REVIEWER_REPORT.md)"
    fi

    # Prior progress context (partial git diff from turn-limit resume)
    export PRIOR_PROGRESS_CONTEXT=""
    if [ -f "$PIPELINE_STATE_FILE" ]; then
        PRIOR_EXIT_REASON=$(grep "^## Exit Reason" -A1 "$PIPELINE_STATE_FILE" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
        if [ "$PRIOR_EXIT_REASON" = "turn_limit" ]; then
            PRIOR_GIT_DIFF=$(awk '/^## Partial Git Changes/{found=1; next} found && /^## /{exit} found{print}' "$PIPELINE_STATE_FILE")
            if [ -n "$PRIOR_GIT_DIFF" ]; then
                PRIOR_PROGRESS_CONTEXT="
## Previous Run Partial Progress
The last coder run hit the turn limit mid-implementation. These files were already modified:
${PRIOR_GIT_DIFF}

Check CODER_SUMMARY.md for what was completed. Do NOT redo work already done.
Pick up from where the previous run left off — read the modified files first to understand current state."
            fi
        fi
    fi

    # Prior tester bugs
    export PRIOR_TESTER_CONTEXT=""
    if [ -f "TESTER_REPORT.md" ] && grep -q "^### Bugs Found\|^## Bugs\|BUG-" TESTER_REPORT.md 2>/dev/null; then
        PRIOR_TESTER_CONTEXT="
## Bugs Found by Tester (must fix)
The tester identified these bugs in the last run. Fix all BUG-* items before
doing anything else. Do not re-implement anything already working.

$(cat TESTER_REPORT.md)"
    fi

    # Accumulated non-blocking notes (injected when above threshold)
    export NON_BLOCKING_CONTEXT=""
    local nb_count
    nb_count=$(count_open_nonblocking_notes)
    local nb_threshold="${NON_BLOCKING_INJECTION_THRESHOLD:-8}"
    if [ "$nb_count" -gt "$nb_threshold" ]; then
        local nb_notes
        nb_notes=$(get_open_nonblocking_notes)
        NON_BLOCKING_CONTEXT="
## Accumulated Tech Debt (${nb_count} items — address what you can)
These are non-blocking reviewer notes that have accumulated over multiple runs.
Address as many as your remaining turns allow. For each item you address,
note the file and what you changed. Items you cannot reach are fine to skip.

${nb_notes}"
        warn "Non-blocking notes (${nb_count}) exceed threshold (${nb_threshold}) — injecting into coder prompt."
    fi

    # --- Invoke coder agent --------------------------------------------------

    # Mark human notes as in-progress before coder runs
    if [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
        claim_human_notes
    fi

    CODER_PROMPT=$(render_prompt "coder")

    log "Invoking coder agent (max ${ADJUSTED_CODER_TURNS:-$CODER_MAX_TURNS} turns)..."
    run_agent \
        "Coder" \
        "$CLAUDE_CODER_MODEL" \
        "${ADJUSTED_CODER_TURNS:-$CODER_MAX_TURNS}" \
        "$CODER_PROMPT" \
        "$LOG_FILE"
    print_run_summary
    success "Coder agent finished."

    # --- Null run detection ---------------------------------------------------

    if was_null_run; then
        error "Coder agent was a null run — it died before doing meaningful work."
        error "This usually means the agent couldn't find files, hit a permission error,"
        error "or the prompt was too complex for initial discovery."

        # Reset claimed notes — coder didn't produce any work
        if [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
            resolve_human_notes
        fi

        write_pipeline_state \
            "coder" \
            "null_run" \
            "--start-at coder" \
            "$TASK" \
            "Agent used ${LAST_AGENT_TURNS} turn(s) and exited ${LAST_AGENT_EXIT_CODE}. Likely died during initial file discovery. Consider: narrower task description, adding a SCOUT_REPORT.md manually, or checking agent logs."

        error "State saved with exit reason 'null_run'. Check the log: ${LOG_FILE}"
        error "Re-run with a more specific task description or add context files."
        exit 1
    fi

    # --- Post-coder validation -----------------------------------------------

    if [ ! -f "CODER_SUMMARY.md" ]; then
        error "Coder did not produce CODER_SUMMARY.md. Check the log: ${LOG_FILE}"
        error "To resume at review stage once resolved: $0 --start-at review \"${TASK}\""
        # Reset claimed notes — coder didn't produce any work
        resolve_human_notes
        exit 1
    fi

    # Resolve human notes based on coder's structured reporting
    if [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
        resolve_human_notes
    fi

    # Check if coder left status as IN PROGRESS (hit turn limit mid-work)
    CODER_STATUS=$(grep "^## Status" CODER_SUMMARY.md 2>/dev/null | head -1 || echo "")
    if [[ "$CODER_STATUS" == *"IN PROGRESS"* ]]; then
        warn "Coder summary shows IN PROGRESS — coder hit turn limit before finishing."

        # Determine if enough was done to proceed to review
        IMPLEMENTED_LINES=$(grep -c "^- " CODER_SUMMARY.md 2>/dev/null || echo "0")
        IMPLEMENTED_LINES=$(echo "$IMPLEMENTED_LINES" | tr -d '[:space:]')

        # Capture git diff context for resume
        GIT_DIFF_STAT=""
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
            GIT_DIFF_STAT=$(git diff --stat HEAD 2>/dev/null | tail -20)
        fi

        if [ "$IMPLEMENTED_LINES" -gt 3 ]; then
            RESUME_FLAG="--milestone --start-at coder"
            RESUME_NOTE="Coder hit turn limit mid-implementation (${IMPLEMENTED_LINES} summary lines). Git diff shows partial work — coder should CONTINUE, not restart."
        else
            RESUME_FLAG="--milestone"
            RESUME_NOTE="Coder hit turn limit with minimal summary output — retry from scratch recommended. Consider either a higher cycle limit or a more specific task description. If the coder struggled to get started, try adding more implementation guidance to the task or breaking it into smaller pieces."
        fi

        # Write state with git diff context so resume knows exactly where coder left off
        local _state_notes="${RESUME_NOTE}"
        if [ -n "$GIT_DIFF_STAT" ]; then
            _state_notes="${_state_notes}

## Partial Git Changes (files touched before turn limit)
\`\`\`
${GIT_DIFF_STAT}
\`\`\`"
        fi

        write_pipeline_state \
            "coder" \
            "turn_limit" \
            "$RESUME_FLAG" \
            "$TASK" \
            "$_state_notes"

        warn "Check the log: ${LOG_FILE}"
        warn "State saved — re-run with no arguments to resume."
        exit 1
    fi

    # --- Completion gate -----------------------------------------------------

    if ! run_completion_gate; then
        warn "Coder did not complete — blocking reviewer and tester."

        GIT_DIFF_STAT=$(git diff --stat HEAD 2>/dev/null | tail -20 || echo "no changes")

        if [ "$MILESTONE_MODE" = true ]; then
            RESUME_FLAG="--milestone --start-at coder"
        else
            RESUME_FLAG="--start-at coder"
        fi

        write_pipeline_state \
            "coder" \
            "incomplete" \
            "$RESUME_FLAG" \
            "$TASK" \
            "Coder hit turn limit mid-implementation. Reviewer and tester were NOT run. Resume will continue coder work before proceeding."

        error "Pipeline halted at completion gate."
        error "State saved — re-run with no arguments to resume."
        exit 1
    fi

    # --- Build gate (with one retry) -----------------------------------------

    BUILD_GATE_RETRY=0
    if ! run_build_gate "post-coder"; then
        if [ "$BUILD_GATE_RETRY" -lt 1 ]; then
            BUILD_GATE_RETRY=1
            warn "Invoking coder to fix build errors (1 retry allowed)..."
            export BUILD_ERRORS_CONTENT
            BUILD_ERRORS_CONTENT=$(cat BUILD_ERRORS.md)
            BUILD_FIX_PROMPT=$(render_prompt "build_fix")

            run_agent \
                "Coder (build fix)" \
                "$CLAUDE_CODER_MODEL" \
                "$((CODER_MAX_TURNS / 3))" \
                "$BUILD_FIX_PROMPT" \
                "$LOG_FILE"
            log "Build fix coder finished."

            if ! run_build_gate "post-coder-fix"; then
                error "Build gate failed again after fix attempt."
                write_pipeline_state \
                    "coder" \
                    "build_failure" \
                    "--start-at coder" \
                    "$TASK" \
                    "Build errors remain after auto-fix attempt. See BUILD_ERRORS.md."
                error "State saved. Review BUILD_ERRORS.md manually then re-run."
                exit 1
            fi
        fi
    fi
}
