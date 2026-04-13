#!/usr/bin/env bash
# =============================================================================
# stages/docs.sh — Dedicated docs agent stage (Milestone 75)
#
# Sourced by tekhton.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, TIMESTAMP, etc.)
# Depends on: lib/docs_agent.sh (docs_agent_should_skip, _docs_extract_public_surface)
#
# Runs after the build gate (end of Stage 1), before the security stage.
# Uses a Haiku-tier model by default to read the coder diff and update
# README/docs/ files. This stage is off by default (DOCS_AGENT_ENABLED=false).
# It never returns non-zero — docs updates are best-effort.
# =============================================================================
set -euo pipefail

# --- Main stage function -----------------------------------------------------

run_stage_docs() {
    local _stage_count="${PIPELINE_STAGE_COUNT:-5}"
    local _stage_pos="${PIPELINE_STAGE_POS:-2}"
    header "Stage ${_stage_pos} / ${_stage_count} — Docs"

    # Gate: disabled
    if [[ "${DOCS_AGENT_ENABLED:-false}" != "true" ]]; then
        log "[docs] Docs agent disabled (DOCS_AGENT_ENABLED=false). Skipping."
        return 0
    fi

    # Gate: --skip-docs flag
    if [[ "${SKIP_DOCS:-false}" == "true" ]]; then
        log "[docs] Docs stage skipped (--skip-docs). Skipping."
        return 0
    fi

    # Gate: no public-surface changes
    if docs_agent_should_skip; then
        return 0
    fi

    # --- Prepare template variables ---
    _docs_prepare_template_vars

    # --- Invoke the docs agent ---
    local docs_turns="${DOCS_AGENT_MAX_TURNS:-10}"
    local prompt
    prompt=$(render_prompt "docs_agent")

    log "[docs] Invoking docs agent (model=${DOCS_AGENT_MODEL:-claude-haiku-4-5-20251001}, turns=${docs_turns})..."

    run_agent \
        "Docs" \
        "${DOCS_AGENT_MODEL:-claude-haiku-4-5-20251001}" \
        "$docs_turns" \
        "$prompt" \
        "$LOG_FILE" \
        "${AGENT_TOOLS_CODER:-Read Write Edit Glob Grep Bash}" || {
        warn "[docs] Docs agent run failed — continuing pipeline without docs updates."
        return 0
    }

    print_run_summary
    log "[docs] Docs agent finished. Report: ${DOCS_AGENT_REPORT_FILE:-}"
    return 0
}

# --- Template variable preparation -------------------------------------------

_docs_prepare_template_vars() {
    # Coder summary content for the prompt
    export CODER_SUMMARY_CONTENT=""
    if [[ -f "${CODER_SUMMARY_FILE:-}" ]]; then
        CODER_SUMMARY_CONTENT=$(_safe_read_file "${CODER_SUMMARY_FILE}" "CODER_SUMMARY")
    fi

    # Git diff stat for changed files overview
    export DOCS_GIT_DIFF_STAT=""
    DOCS_GIT_DIFF_STAT=$(git diff --stat HEAD 2>/dev/null || true)
    if [[ -z "$DOCS_GIT_DIFF_STAT" ]]; then
        DOCS_GIT_DIFF_STAT=$(git diff --cached --stat 2>/dev/null || true)
    fi

    # Extract Documentation Responsibilities section from CLAUDE.md
    export DOCS_SURFACE_SECTION=""
    local rules_file="${PROJECT_RULES_FILE:-CLAUDE.md}"
    if [[ -f "$rules_file" ]]; then
        DOCS_SURFACE_SECTION=$(sed -n \
            '/^##.*[Dd]ocumentation [Rr]esponsibilities/,/^## /{ /^## [^D]/d; p; }' \
            "$rules_file" 2>/dev/null || true)
    fi

    # Ensure DOCS_README_FILE and DOCS_DIRS are exported for the prompt
    export DOCS_README_FILE="${DOCS_README_FILE:-README.md}"
    export DOCS_DIRS="${DOCS_DIRS:-docs/}"
    export DOCS_AGENT_REPORT_FILE="${DOCS_AGENT_REPORT_FILE:-${TEKHTON_DIR:-}.tekhton/DOCS_AGENT_REPORT.md}"
}
