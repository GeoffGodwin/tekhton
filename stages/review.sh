#!/usr/bin/env bash
# =============================================================================
# stages/review.sh — Stage 2: Review loop (review → rework → build gate)
#
# Sourced by tekhton.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, etc.)
# Sets: VERDICT (global, read by later stages and the final summary)
# =============================================================================

# run_stage_review — Runs the review loop:
#   1. Invoke reviewer agent
#   2. Parse verdict and blocker counts
#   3. Route complex blockers → senior coder, simple → jr coder
#   4. Post-fix build gate
#   5. Repeat up to MAX_REVIEW_CYCLES
#
# On success, sets VERDICT to the final reviewer verdict.
# Exits the pipeline (exit 1) if max cycles reached with unresolved blockers.
run_stage_review() {
    header "Stage 2 / 3 — Reviewer"

    # Estimate review/tester turns from coder output if scout didn't already set them
    estimate_post_coder_turns

    REVIEW_CYCLE=0
    VERDICT="CHANGES_REQUIRED"

    while [ "$VERDICT" = "CHANGES_REQUIRED" ] && [ "$REVIEW_CYCLE" -lt "$MAX_REVIEW_CYCLES" ]; do
        REVIEW_CYCLE=$((REVIEW_CYCLE + 1))
        log "Review cycle ${REVIEW_CYCLE} / ${MAX_REVIEW_CYCLES}..."

        # --- Invoke reviewer -------------------------------------------------

        export ARCHITECTURE_CONTENT
        ARCHITECTURE_CONTENT=$([ -f "${ARCHITECTURE_FILE}" ] && cat "${ARCHITECTURE_FILE}" || echo "(${ARCHITECTURE_FILE} not found)")
        export PRIOR_BLOCKERS_BLOCK=""
        if [ "$REVIEW_CYCLE" -gt 1 ]; then
            PRIOR_BLOCKERS_BLOCK="yes"
        fi
        REVIEWER_PROMPT=$(render_prompt "reviewer")

        run_agent \
            "Reviewer (cycle ${REVIEW_CYCLE})" \
            "$CLAUDE_STANDARD_MODEL" \
            "${ADJUSTED_REVIEWER_TURNS:-$REVIEWER_MAX_TURNS}" \
            "$REVIEWER_PROMPT" \
            "$LOG_FILE"
        print_run_summary
        success "Reviewer finished."

        # Check for null run before parsing output
        if was_null_run; then
            warn "Reviewer was a null run (${LAST_AGENT_TURNS} turns, exit ${LAST_AGENT_EXIT_CODE})."
            warn "Skipping review parse — will retry on next cycle or fail at max cycles."
            VERDICT="CHANGES_REQUIRED"
            if [ "$REVIEW_CYCLE" -ge "$MAX_REVIEW_CYCLES" ]; then
                error "Reviewer null run at max review cycles — cannot proceed."
                write_pipeline_state "review" "null_run" \
                    "${MILESTONE_MODE:+--milestone }--start-at review" \
                    "$TASK" \
                    "Reviewer agent died without producing output (${LAST_AGENT_TURNS} turns). Check logs."
                exit 1
            fi
            continue
        fi

        if [ ! -f "REVIEWER_REPORT.md" ]; then
            error "Reviewer did not produce REVIEWER_REPORT.md. Check the log: ${LOG_FILE}"
            error "To resume at test stage: $0 --start-at test \"${TASK}\""
            exit 1
        fi

        # --- Parse verdict ---------------------------------------------------

        VERDICT=$(grep -m1 "^## Verdict" -A1 REVIEWER_REPORT.md 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
        # Also catch inline verdict formats like "Verdict: APPROVED" or "**Verdict: CHANGES_REQUIRED**"
        if [ -z "$VERDICT" ] || [ "$VERDICT" = "##Verdict" ]; then
            VERDICT=$(grep -oi "APPROVED_WITH_NOTES\|CHANGES_REQUIRED\|APPROVED" REVIEWER_REPORT.md 2>/dev/null | head -1 || true)
        fi
        log "Reviewer verdict: ${BOLD}${VERDICT}${NC}"

        # --- Parse ACP verdicts (if present) ---------------------------------
        # Extract accepted ACPs for downstream processing (P3 drift log will consume)
        ACCEPTED_ACPS=""
        if grep -q "^## ACP Verdicts" REVIEWER_REPORT.md 2>/dev/null; then
            ACCEPTED_ACPS=$(awk '/^## ACP Verdicts/{found=1; next} found && /^##/{exit} found && /ACCEPT/{print}' \
                REVIEWER_REPORT.md 2>/dev/null || true)
            if [ -n "$ACCEPTED_ACPS" ]; then
                log "Accepted ACPs found:"
                # shellcheck disable=SC2001
                echo "$ACCEPTED_ACPS" | sed 's/^/  /'
            fi
        fi

        if [ "$VERDICT" = "CHANGES_REQUIRED" ]; then
            # --- Count blockers ----------------------------------------------
            TMPDIR_BLOCKS=$(mktemp -d)
            awk '/^## Complex Blockers/{found=1; next} found && /^##/{exit} found{print}' \
                REVIEWER_REPORT.md > "${TMPDIR_BLOCKS}/complex.txt" 2>/dev/null || true
            awk '/^## Simple Blockers/{found=1; next} found && /^##/{exit} found{print}' \
                REVIEWER_REPORT.md > "${TMPDIR_BLOCKS}/simple.txt" 2>/dev/null || true

            # A section containing only "None" (or "- None") counts as zero
            HAS_COMPLEX=0
            HAS_SIMPLE=0
            if ! grep -qE "^\-?\s*None\s*$" "${TMPDIR_BLOCKS}/complex.txt" 2>/dev/null; then
                HAS_COMPLEX=$(grep -c "^- " "${TMPDIR_BLOCKS}/complex.txt" 2>/dev/null || echo "0")
            fi
            if ! grep -qE "^\-?\s*None\s*$" "${TMPDIR_BLOCKS}/simple.txt" 2>/dev/null; then
                HAS_SIMPLE=$(grep -c "^- " "${TMPDIR_BLOCKS}/simple.txt" 2>/dev/null || echo "0")
            fi
            HAS_COMPLEX=$(echo "$HAS_COMPLEX" | tr -d '[:space:]')
            HAS_SIMPLE=$(echo "$HAS_SIMPLE" | tr -d '[:space:]')
            rm -rf "$TMPDIR_BLOCKS"

            log "Complex blockers: ${HAS_COMPLEX}, Simple blockers: ${HAS_SIMPLE}"

            # --- Route rework ------------------------------------------------
            if [ "$REVIEW_CYCLE" -lt "$MAX_REVIEW_CYCLES" ]; then
                if [ "$HAS_COMPLEX" -gt 0 ]; then
                    warn "Complex blockers found. Re-invoking senior coder..."

                    REWORK_PROMPT=$(render_prompt "coder_rework")

                    run_agent \
                        "Coder (rework cycle ${REVIEW_CYCLE})" \
                        "$CLAUDE_CODER_MODEL" \
                        "$CODER_MAX_TURNS" \
                        "$REWORK_PROMPT" \
                        "$LOG_FILE"
                    print_run_summary
                    success "Senior coder rework finished."

                    if [ "$HAS_SIMPLE" -gt 0 ]; then
                        log "Simple blockers remain. Invoking jr coder..."

                        JR_AFTER_SENIOR="yes"
                        JR_REWORK_PROMPT=$(render_prompt "jr_coder")
                        JR_AFTER_SENIOR=""

                        run_agent \
                            "Jr Coder (cycle ${REVIEW_CYCLE})" \
                            "$CLAUDE_JR_CODER_MODEL" \
                            "$JR_CODER_MAX_TURNS" \
                            "$JR_REWORK_PROMPT" \
                            "$LOG_FILE"
                        print_run_summary
                        success "Jr coder cleanup finished."
                    fi

                elif [ "$HAS_SIMPLE" -gt 0 ]; then
                    warn "Only simple blockers found. Invoking jr coder..."

                    export JR_AFTER_SENIOR=""
                    JR_REWORK_PROMPT=$(render_prompt "jr_coder")

                    run_agent \
                        "Jr Coder (cycle ${REVIEW_CYCLE})" \
                        "$CLAUDE_JR_CODER_MODEL" \
                        "$JR_CODER_MAX_TURNS" \
                        "$JR_REWORK_PROMPT" \
                        "$LOG_FILE"
                    print_run_summary
                    success "Jr coder cleanup finished."
                fi

                # --- Post-fix build gate -------------------------------------
                if ! run_build_gate "post-fix-pass"; then
                    error "Build gate failed after fix pass — escalating to senior coder."
                    BUILD_FIX_PROMPT=$(render_prompt "build_fix_minimal")
                    run_agent \
                        "Coder (post-fix-pass build fix)" \
                        "$CLAUDE_CODER_MODEL" \
                        "$((CODER_MAX_TURNS / 3))" \
                        "$BUILD_FIX_PROMPT" \
                        "$LOG_FILE"
                    if ! run_build_gate "post-fix-pass-retry"; then
                        error "Build gate failed again. See BUILD_ERRORS.md."
                        write_pipeline_state "review" "build_failure" \
                            "${MILESTONE_MODE:+--milestone }--start-at review" \
                            "$TASK" "Build broken after fix pass. See BUILD_ERRORS.md."
                        exit 1
                    fi
                fi

            else
                # --- Max cycles reached --------------------------------------
                error "Max review cycles (${MAX_REVIEW_CYCLES}) reached with unresolved blockers."

                BLOCKER_SUMMARY="Complex: ${HAS_COMPLEX}, Simple: ${HAS_SIMPLE} — see REVIEWER_REPORT.md"
                if [ "$MILESTONE_MODE" = true ]; then
                    RESUME_FLAG="--milestone --start-at review"
                else
                    RESUME_FLAG="--start-at review"
                fi

                write_pipeline_state \
                    "review" \
                    "blockers_remain" \
                    "$RESUME_FLAG" \
                    "$TASK" \
                    "$BLOCKER_SUMMARY"

                error "State saved — fix blockers manually then re-run with no arguments to resume."
                exit 1
            fi
        fi
    done

    print_run_summary
    success "Review passed (verdict: ${VERDICT})."
}
