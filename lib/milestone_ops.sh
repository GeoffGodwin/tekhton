#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_ops.sh — Milestone commit signatures, auto-advance orchestration
#
# Sourced by tekhton.sh — do not run directly.
# Sources: milestone_acceptance.sh (sourced below, line 26)
# Expects: milestones.sh to be sourced first by the caller
# Expects: PROJECT_DIR, TEST_CMD, ANALYZE_CMD (from config)
# Expects: log(), warn(), success(), header() from common.sh
# Expects: run_build_gate() from gates.sh
#
# Provides:
#   get_milestone_commit_prefix — commit message prefix for milestone runs
#   get_milestone_commit_body   — commit body line for milestone status
#   tag_milestone_complete      — optional git tag on completion
#   should_auto_advance         — check auto-advance conditions
#   find_next_milestone         — locate next non-done milestone
#   prompt_auto_advance_confirm — interactive confirmation for auto-advance
#   mark_milestone_done         — mark a milestone heading as [DONE] in CLAUDE.md
#   clear_milestone_state       — remove milestone state file
# =============================================================================

# Source acceptance checking from dedicated module
# shellcheck source=/dev/null
source "${TEKHTON_HOME:-.}/lib/milestone_acceptance.sh"

# Milestone commit signatures -----------------------------------------------

# get_milestone_commit_prefix MILESTONE_NUM DISPOSITION
# Returns the appropriate commit message prefix based on milestone disposition.
# Returns empty string if not in milestone mode.
get_milestone_commit_prefix() {
    local milestone_num="$1"
    local disposition="$2"

    if [[ -z "$milestone_num" ]]; then
        return
    fi

    case "$disposition" in
        COMPLETE_AND_CONTINUE|COMPLETE_AND_WAIT)
            echo "[MILESTONE ${milestone_num} ✓]"
            ;;
        INCOMPLETE_REWORK|REPLAN_REQUIRED|NONE|"")
            echo "[MILESTONE ${milestone_num} — partial]"
            ;;
    esac
}

# get_milestone_commit_body MILESTONE_NUM DISPOSITION [CLAUDE_MD_PATH]
# Returns a milestone status line for the commit body.
get_milestone_commit_body() {
    local milestone_num="$1"
    local disposition="$2"
    local claude_md="${3:-${PROJECT_RULES_FILE:-CLAUDE.md}}"

    if [[ -z "$milestone_num" ]]; then
        return
    fi

    local title
    title=$(get_milestone_title "$milestone_num" "$claude_md" 2>/dev/null) || true

    case "$disposition" in
        COMPLETE_AND_CONTINUE|COMPLETE_AND_WAIT)
            echo "Milestone ${milestone_num}: ${title} — COMPLETE"
            ;;
        INCOMPLETE_REWORK)
            echo "Milestone ${milestone_num}: ${title} — PARTIAL (rework needed)"
            ;;
        REPLAN_REQUIRED)
            echo "Milestone ${milestone_num}: ${title} — PARTIAL (replan required)"
            ;;
        *)
            echo "Milestone ${milestone_num}: ${title} — PARTIAL"
            ;;
    esac
}

# tag_milestone_complete MILESTONE_NUM
# Creates a git tag for a completed milestone if MILESTONE_TAG_ON_COMPLETE=true.
# Handles gracefully if tag already exists (warn and continue).
tag_milestone_complete() {
    local milestone_num="$1"

    if [[ "${MILESTONE_TAG_ON_COMPLETE:-false}" != "true" ]]; then
        return 0
    fi

    local tag_name="milestone-${milestone_num}-complete"

    if git tag "$tag_name" 2>/dev/null; then
        success "Created git tag: ${tag_name}"
    else
        warn "Git tag '${tag_name}' already exists or could not be created. Continuing."
    fi
}

# --- Auto-advance orchestration helpers --------------------------------------

# should_auto_advance
# Returns 0 if auto-advance conditions are met, 1 otherwise.
# Checks: AUTO_ADVANCE_ENABLED, session limit, disposition.
should_auto_advance() {
    if [[ "${AUTO_ADVANCE_ENABLED:-false}" != "true" ]]; then
        return 1
    fi

    local completed
    completed=$(get_milestones_completed_this_session)
    local limit="${AUTO_ADVANCE_LIMIT:-3}"

    if [[ "$completed" -ge "$limit" ]]; then
        log "Auto-advance limit reached (${completed}/${limit})"
        return 1
    fi

    local disposition
    disposition=$(get_milestone_disposition)
    if [[ "$disposition" != "COMPLETE_AND_CONTINUE" ]]; then
        return 1
    fi

    return 0
}

# find_next_milestone CURRENT_NUM CLAUDE_MD_PATH
# Returns the next non-done milestone number after CURRENT_NUM.
# Uses DAG-aware ordering when manifest exists, falls back to inline.
# Returns empty string if no more milestones.
find_next_milestone() {
    local current="$1"
    local claude_md="${2:-CLAUDE.md}"

    # DAG path: use dag_find_next for dependency-aware ordering
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest 2>/dev/null || true
        fi
        local current_id
        current_id=$(dag_number_to_id "$current")
        local next_id
        next_id=$(dag_find_next "$current_id" 2>/dev/null) || true
        if [[ -n "$next_id" ]]; then
            dag_id_to_number "$next_id"
        fi
        return
    fi

    # Inline path: sequential ordering
    local next=""
    local all_ms
    all_ms=$(parse_milestones "$claude_md" 2>/dev/null) || true
    while IFS='|' read -r num _title _criteria; do
        if [[ -n "$num" ]] && awk -v n="$num" -v c="$current" 'BEGIN {exit !(n > c)}'; then
            if ! is_milestone_done "$num" "$claude_md"; then
                next="$num"
                break
            fi
        fi
    # sort -n handles decimals (e.g., 0.5 sorts before 1) on both GNU and BSD sort
    done < <(echo "$all_ms" | sort -t'|' -k1 -n)

    echo "$next"
}

# prompt_auto_advance_confirm NEXT_NUM NEXT_TITLE
# Prompts the user to confirm advancing to the next milestone.
# Returns 0 if confirmed, 1 if declined.
prompt_auto_advance_confirm() {
    local next_num="$1"
    local next_title="$2"

    echo
    log "Auto-advance: ready to proceed to Milestone ${next_num}: ${next_title}"
    log "Continue? [y/n]"
    echo "  y = advance to milestone ${next_num}"
    echo "  n = stop here (state saved for resume)"

    local choice
    if [[ -t 0 ]]; then
        read -r choice
    else
        read -r choice < /dev/tty 2>/dev/null || choice="n"
    fi

    [[ "$choice" =~ ^[Yy]$ ]]
}

# mark_milestone_done MILESTONE_NUM [CLAUDE_MD_PATH]
# Marks a milestone as done. In DAG mode, updates manifest status.
# In inline mode, adds [DONE] marker to CLAUDE.md heading.
# Idempotent — returns 0 if already done.
mark_milestone_done() {
    local milestone_num="$1"
    local claude_md="${2:-${PROJECT_RULES_FILE:-CLAUDE.md}}"

    # DAG path: update manifest status
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest 2>/dev/null || true
        fi
        local id
        id=$(dag_number_to_id "$milestone_num")
        local current_status
        current_status=$(dag_get_status "$id" 2>/dev/null) || true
        if [[ "$current_status" == "done" ]]; then
            log "Milestone ${milestone_num} already marked done in manifest"
            return 0
        fi
        dag_set_status "$id" "done"
        save_manifest
        # Also update the milestone .md file metadata if emit_milestone_metadata exists
        if declare -f emit_milestone_metadata &>/dev/null; then
            emit_milestone_metadata "$milestone_num" "done" 2>/dev/null || true
        fi
        success "Marked Milestone ${milestone_num} (${id}) as done in manifest"
        # Emit milestone_advance event (Milestone 13)
        if command -v emit_event &>/dev/null; then
            emit_event "milestone_advance" "pipeline" "Milestone ${milestone_num} done" \
                "${_LAST_STAGE_EVT:-}" "" \
                "{\"milestone\":\"$(_json_escape "$milestone_num")\"}" 2>/dev/null || true
        fi
        if command -v emit_dashboard_milestones &>/dev/null; then
            emit_dashboard_milestones 2>/dev/null || true
        fi
        return 0
    fi

    # Inline path: mark [DONE] in CLAUDE.md
    if [[ ! -f "$claude_md" ]]; then
        warn "mark_milestone_done: ${claude_md} not found"
        return 1
    fi

    local num_pattern="${milestone_num//./\\.}"

    if grep -qE "^#{1,5}[[:space:]]*\[DONE\][[:space:]]+Milestone[[:space:]]+${num_pattern}:" "$claude_md" 2>/dev/null; then
        log "Milestone ${milestone_num} already marked [DONE]"
        return 0
    fi

    if ! grep -qE "^#{1,5}[[:space:]]+Milestone[[:space:]]+${num_pattern}:" "$claude_md" 2>/dev/null; then
        warn "mark_milestone_done: Milestone ${milestone_num} heading not found in ${claude_md}"
        return 1
    fi

    local tmpfile
    tmpfile=$(mktemp)
    sed -E "s/^(#{1,5})[[:space:]]+(Milestone[[:space:]]+${num_pattern}:)/\1 [DONE] \2/" "$claude_md" > "$tmpfile"
    mv "$tmpfile" "$claude_md"

    success "Marked Milestone ${milestone_num} as [DONE] in ${claude_md}"
    return 0
}

# clear_milestone_state
# Removes the milestone state file.
clear_milestone_state() {
    if [[ -f "$MILESTONE_STATE_FILE" ]]; then
        rm "$MILESTONE_STATE_FILE"
        log "Milestone state cleared"
    fi
}
