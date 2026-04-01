#!/usr/bin/env bash
# stages/review.sh — Stage 2: Review loop (review → rework → build gate)
# Sourced by tekhton.sh. Sets: VERDICT (global).

# run_stage_review — Review loop: invoke reviewer, parse verdict, route rework,
# build gate, repeat up to MAX_REVIEW_CYCLES. Exits on max-cycle exhaustion.
run_stage_review() {
    local _stage_count="${PIPELINE_STAGE_COUNT:-4}"
    local _stage_pos="${PIPELINE_STAGE_POS:-3}"
    header "Stage ${_stage_pos} / ${_stage_count} — Reviewer"

    # Polish reviewer skip heuristic (M42): if all changed files are non-logic,
    # skip the review cycle entirely. Tests still run in the tester stage.
    if command -v should_skip_review_for_polish &>/dev/null \
       && should_skip_review_for_polish; then
        log "Polish note: all changes are non-logic files. Skipping reviewer."
        VERDICT="APPROVED_WITH_NOTES"
        export REVIEWER_SKIPPED="true"
        return 0
    fi

    # M48: Diff-size review threshold — skip review for trivial diffs.
    # Never applies in milestone mode (milestones always get full review).
    local _skip_threshold="${REVIEW_SKIP_THRESHOLD:-0}"
    if [[ "$_skip_threshold" -gt 0 ]] && [[ "${MILESTONE_MODE:-false}" != "true" ]]; then
        local _diff_lines
        _diff_lines=$(git diff --stat HEAD 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo "0")
        if [[ "$_diff_lines" -gt 0 ]] && [[ "$_diff_lines" -lt "$_skip_threshold" ]]; then
            log "Diff size (${_diff_lines} lines) below review threshold (${_skip_threshold}). Skipping review."
            VERDICT="APPROVED_WITH_NOTES"
            export REVIEWER_SKIPPED="true"
            return 0
        fi
    fi

    estimate_post_coder_turns "${ACTUAL_CODER_TURNS:-0}"
    REVIEW_CYCLE=0
    VERDICT="CHANGES_REQUIRED"

    while [ "$VERDICT" = "CHANGES_REQUIRED" ] && [ "$REVIEW_CYCLE" -lt "$MAX_REVIEW_CYCLES" ]; do
        REVIEW_CYCLE=$((REVIEW_CYCLE + 1))
        log "Review cycle ${REVIEW_CYCLE} / ${MAX_REVIEW_CYCLES}..."

        # M47: use cached architecture content
        export ARCHITECTURE_CONTENT
        ARCHITECTURE_CONTENT=$(_get_cached_architecture_content)
        if [[ -z "$ARCHITECTURE_CONTENT" ]]; then
            ARCHITECTURE_CONTENT="(${ARCHITECTURE_FILE} not found)"
        fi

        # Repo map slice: changed files + their callers/callees
        # Note: Map is regenerated each review cycle (cleared on line 26, refreshed below if needed)
        export REPO_MAP_CONTENT=""
        if [[ "${INDEXER_AVAILABLE:-false}" == "true" ]] && [[ "${REPO_MAP_ENABLED:-false}" == "true" ]]; then
            local _review_files
            _review_files=$(extract_files_from_coder_summary "CODER_SUMMARY.md")
            if [[ -n "$_review_files" ]]; then
                run_repo_map "$TASK" || true
                if [[ -n "$REPO_MAP_CONTENT" ]]; then
                    local _review_slice
                    if _review_slice=$(get_repo_map_slice "$_review_files"); then
                        REPO_MAP_CONTENT="$_review_slice"
                        log "[indexer] Repo map sliced for reviewer (changed files)."
                    fi
                fi
            fi
        fi

        export PRIOR_BLOCKERS_BLOCK=""
        if [ "$REVIEW_CYCLE" -gt 1 ]; then
            PRIOR_BLOCKERS_BLOCK="yes"
        fi

        build_context_packet "review" "$TASK" "$CLAUDE_REVIEWER_MODEL"
        _add_context_component "Architecture" "$ARCHITECTURE_CONTENT"
        _add_context_component "Repo Map" "${REPO_MAP_CONTENT:-}"
        log_context_report "reviewer (cycle ${REVIEW_CYCLE})" "$CLAUDE_REVIEWER_MODEL"

        _phase_start "reviewer_prompt"
        REVIEWER_PROMPT=$(render_prompt "reviewer")
        _phase_end "reviewer_prompt"

        _phase_start "reviewer_agent"
        run_agent \
            "Reviewer (cycle ${REVIEW_CYCLE})" \
            "$CLAUDE_REVIEWER_MODEL" \
            "${ADJUSTED_REVIEWER_TURNS:-$REVIEWER_MAX_TURNS}" \
            "$REVIEWER_PROMPT" \
            "$LOG_FILE" \
            "$AGENT_TOOLS_REVIEWER"
        _phase_end "reviewer_agent"
        print_run_summary
        success "Reviewer finished."

        # UPSTREAM error detection (12.2)
        if [[ "${AGENT_ERROR_CATEGORY:-}" = "UPSTREAM" ]]; then
            warn "Reviewer hit an API error (${AGENT_ERROR_SUBCATEGORY}). Will retry on next cycle."
            VERDICT="CHANGES_REQUIRED"
            if [ "$REVIEW_CYCLE" -ge "$MAX_REVIEW_CYCLES" ]; then
                error "Reviewer API error at max review cycles — cannot proceed."
                write_pipeline_state "review" "upstream_error" \
                    "$(_build_resume_flag review)" \
                    "$TASK" \
                    "API error (${AGENT_ERROR_SUBCATEGORY}): ${AGENT_ERROR_MESSAGE}. Re-run the same command."
                exit 1
            fi
            continue
        fi

        if was_null_run; then
            warn "Reviewer was a null run (${LAST_AGENT_TURNS} turns, exit ${LAST_AGENT_EXIT_CODE})."
            warn "Skipping review parse — will retry on next cycle or fail at max cycles."
            VERDICT="CHANGES_REQUIRED"
            if [ "$REVIEW_CYCLE" -ge "$MAX_REVIEW_CYCLES" ]; then
                error "Reviewer null run at max review cycles — cannot proceed."
                write_pipeline_state "review" "null_run" \
                    "$(_build_resume_flag review)" \
                    "$TASK" \
                    "Reviewer agent died without producing output (${LAST_AGENT_TURNS} turns). Check logs."
                exit 1
            fi
            continue
        fi

        if [ ! -f "REVIEWER_REPORT.md" ]; then
            warn "Reviewer did not produce REVIEWER_REPORT.md."
            if [ "$REVIEW_CYCLE" -lt "$MAX_REVIEW_CYCLES" ]; then
                warn "Will retry on next review cycle."
                VERDICT="CHANGES_REQUIRED"
                continue
            fi
            # Last cycle — synthesize a minimal report so pipeline can proceed
            warn "Synthesizing minimal REVIEWER_REPORT.md — tester will validate."
            cat > REVIEWER_REPORT.md <<REVIEW_EOF
## Verdict
APPROVED_WITH_NOTES

## Summary
REVIEWER_REPORT.md was synthesized by the pipeline after the reviewer agent
failed to produce it. The reviewer may have encountered issues reading or
writing the report file. The tester should validate all changes thoroughly.

## Complex Blockers
- None (reviewer did not report)

## Simple Blockers
- None (reviewer did not report)

## Non-Blocking Notes
- Reviewer agent did not produce a report — extra tester scrutiny recommended.
REVIEW_EOF
            VERDICT="APPROVED_WITH_NOTES"
            log "Synthesized REVIEWER_REPORT.md with APPROVED_WITH_NOTES verdict."
        fi

        VERDICT=$(grep -m1 "^## Verdict" -A1 REVIEWER_REPORT.md 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
        # Also catch inline verdict formats like "Verdict: APPROVED" or "**Verdict: CHANGES_REQUIRED**"
        if [ -z "$VERDICT" ] || [ "$VERDICT" = "##Verdict" ]; then
            VERDICT=$(grep -oi "REPLAN_REQUIRED\|APPROVED_WITH_NOTES\|CHANGES_REQUIRED\|APPROVED" REVIEWER_REPORT.md 2>/dev/null | head -1 || true)
        fi
        log "Reviewer verdict: ${BOLD}${VERDICT}${NC}"

        if detect_replan_required "REVIEWER_REPORT.md"; then
            warn "Reviewer recommends REPLAN_REQUIRED."
            if ! trigger_replan "REVIEWER_REPORT.md"; then
                # User aborted or chose split — exit saved by trigger_replan
                exit 1
            fi
            # User chose continue or replan was applied — proceed to tester
            VERDICT="APPROVED_WITH_NOTES"
            log "Proceeding after replan decision (verdict overridden to APPROVED_WITH_NOTES)."
        fi

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
            TMPDIR_BLOCKS=$(mktemp -d "${TEKHTON_SESSION_DIR:-/tmp}/blocks_XXXXXXXX")
            awk '/^## Complex Blockers/{found=1; next} found && /^##/{exit} found{print}' \
                REVIEWER_REPORT.md > "${TMPDIR_BLOCKS}/complex.txt" 2>/dev/null || true
            awk '/^## Simple Blockers/{found=1; next} found && /^##/{exit} found{print}' \
                REVIEWER_REPORT.md > "${TMPDIR_BLOCKS}/simple.txt" 2>/dev/null || true

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
            if [ "$REVIEW_CYCLE" -lt "$MAX_REVIEW_CYCLES" ]; then
                if [ "$HAS_COMPLEX" -gt 0 ]; then
                    warn "Complex blockers found. Re-invoking senior coder..."

                    REWORK_PROMPT=$(render_prompt "coder_rework")

                    _phase_start "rework_agent"
                    run_agent \
                        "Coder (rework cycle ${REVIEW_CYCLE})" \
                        "$CLAUDE_CODER_MODEL" \
                        "$CODER_MAX_TURNS" \
                        "$REWORK_PROMPT" \
                        "$LOG_FILE" \
                        "$AGENT_TOOLS_CODER"
                    _phase_end "rework_agent"
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
                            "$LOG_FILE" \
                            "$AGENT_TOOLS_JR_CODER"
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
                        "$LOG_FILE" \
                        "$AGENT_TOOLS_JR_CODER"
                    print_run_summary
                    success "Jr coder cleanup finished."
                fi
                if ! run_build_gate "post-fix-pass"; then
                    error "Build gate failed after fix pass — escalating to senior coder."
                    BUILD_FIX_PROMPT=$(render_prompt "build_fix_minimal")
                    run_agent \
                        "Coder (post-fix-pass build fix)" \
                        "$CLAUDE_CODER_MODEL" \
                        "$((CODER_MAX_TURNS / 3))" \
                        "$BUILD_FIX_PROMPT" \
                        "$LOG_FILE" \
                        "$AGENT_TOOLS_BUILD_FIX"
                    if ! run_build_gate "post-fix-pass-retry"; then
                        error "Build gate failed again. See BUILD_ERRORS.md."
                        write_pipeline_state "review" "build_failure" \
                            "$(_build_resume_flag review)" \
                            "$TASK" "Build broken after fix pass. See BUILD_ERRORS.md."
                        exit 1
                    fi
                fi

            else
                error "Max review cycles (${MAX_REVIEW_CYCLES}) reached with unresolved blockers."

                BLOCKER_SUMMARY="Complex: ${HAS_COMPLEX}, Simple: ${HAS_SIMPLE} — see REVIEWER_REPORT.md"
                RESUME_FLAG="$(_build_resume_flag review)"

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

    if [[ "$VERDICT" = "APPROVED" || "$VERDICT" = "APPROVED_WITH_NOTES" ]]; then
        if ! run_specialist_reviews; then
            _route_specialist_rework
        fi
    fi

    print_run_summary
    success "Review passed (verdict: ${VERDICT})."
}

# _route_specialist_rework — Handles specialist blocker rework and re-review.
_route_specialist_rework() {
    warn "Specialist blocker(s) detected. Routing to senior coder rework."

    if has_specialist_blockers; then
        {
            echo ""
            echo "## Specialist Blockers"
            echo "$SPECIALIST_BLOCKERS"
        } >> "REVIEWER_REPORT.md"
    fi

    VERDICT="CHANGES_REQUIRED"

    if [[ "$REVIEW_CYCLE" -ge "$MAX_REVIEW_CYCLES" ]]; then
        error "Specialist blockers found but no review cycles remain."
        write_pipeline_state "review" "specialist_blockers" \
            "$(_build_resume_flag review)" \
            "$TASK" "Specialist reviewers found blockers. See SPECIALIST_REPORT.md."
        exit 1
    fi

    REWORK_PROMPT=$(render_prompt "coder_rework")
    run_agent \
        "Coder (specialist rework)" \
        "$CLAUDE_CODER_MODEL" \
        "$CODER_MAX_TURNS" \
        "$REWORK_PROMPT" \
        "$LOG_FILE" \
        "$AGENT_TOOLS_CODER"
    print_run_summary
    success "Specialist rework finished."

    if ! run_build_gate "post-specialist-rework"; then
        error "Build gate failed after specialist rework."
        BUILD_FIX_PROMPT=$(render_prompt "build_fix_minimal")
        run_agent \
            "Coder (post-specialist build fix)" \
            "$CLAUDE_CODER_MODEL" \
            "$((CODER_MAX_TURNS / 3))" \
            "$BUILD_FIX_PROMPT" \
            "$LOG_FILE" \
            "$AGENT_TOOLS_BUILD_FIX"
        if ! run_build_gate "post-specialist-retry"; then
            error "Build gate failed again after specialist rework."
            write_pipeline_state "review" "specialist_build_failure" \
                "$(_build_resume_flag review)" \
                "$TASK" "Build broken after specialist rework. See BUILD_ERRORS.md."
            exit 1
        fi
    fi

    REVIEW_CYCLE=$((REVIEW_CYCLE + 1))
    log "Re-running reviewer to verify specialist fixes (cycle ${REVIEW_CYCLE})..."

    REVIEWER_PROMPT=$(render_prompt "reviewer")
    run_agent \
        "Reviewer (post-specialist cycle ${REVIEW_CYCLE})" \
        "$CLAUDE_REVIEWER_MODEL" \
        "${ADJUSTED_REVIEWER_TURNS:-$REVIEWER_MAX_TURNS}" \
        "$REVIEWER_PROMPT" \
        "$LOG_FILE" \
        "$AGENT_TOOLS_REVIEWER"
    print_run_summary

    if [[ -f "REVIEWER_REPORT.md" ]]; then
        VERDICT=$(grep -m1 "^## Verdict" -A1 REVIEWER_REPORT.md 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
        if [[ -z "$VERDICT" || "$VERDICT" = "##Verdict" ]]; then
            VERDICT=$(grep -oi "REPLAN_REQUIRED\|APPROVED_WITH_NOTES\|CHANGES_REQUIRED\|APPROVED" REVIEWER_REPORT.md 2>/dev/null | head -1 || true)
        fi
        log "Post-specialist reviewer verdict: ${BOLD}${VERDICT}${NC}"
    fi
}
