#!/usr/bin/env bash
# stages/review_helpers.sh — Review stage helper functions
# Sourced by tekhton.sh after review.sh — do not run directly.

set -euo pipefail

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
