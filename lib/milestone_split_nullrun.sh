#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_split_nullrun.sh — Null-run auto-split handler
#
# Sourced by milestone_split.sh — do not run directly.
# Expects: get_split_depth(), record_milestone_attempt(), split_milestone()
#          from milestone_split.sh
# Expects: log(), warn(), error() from common.sh
#
# Provides:
#   handle_null_run_split     — auto-split after null-run detection
# =============================================================================

# handle_null_run_split MILESTONE_NUM CLAUDE_MD_PATH
# Called when the coder produces a null-run or minimal output on a milestone.
# Checks for substantive partial work before splitting.
# Returns 0 if split succeeded and pipeline should retry, 1 otherwise.
handle_null_run_split() {
    local milestone_num="$1"
    local claude_md="${2:-CLAUDE.md}"

    if [[ "${MILESTONE_AUTO_RETRY:-true}" != "true" ]]; then
        log "MILESTONE_AUTO_RETRY is disabled — skipping auto-split."
        return 1
    fi

    if [[ "${MILESTONE_SPLIT_ENABLED:-true}" != "true" ]]; then
        log "MILESTONE_SPLIT_ENABLED is disabled — skipping auto-split."
        return 1
    fi

    # Check split depth
    local depth
    depth=$(get_split_depth "$milestone_num")
    local max_depth="${MILESTONE_MAX_SPLIT_DEPTH:-3}"

    if [[ "$depth" -ge "$max_depth" ]]; then
        error "Milestone ${milestone_num} at max split depth (${depth}/${max_depth}) — cannot split further."
        return 1
    fi

    # Check for substantive partial work.
    # We use `git diff --quiet` (unstaged) and `git diff --cached --quiet` (staged)
    # as the activation condition. Then `git diff --stat HEAD` measures scope —
    # `git diff HEAD` (not bare `git diff`) is intentional because it captures
    # both staged and unstaged changes in a single pass.
    local has_substantive_work=false
    local diff_stat=""
    local summary_lines=0

    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        diff_stat=$(git diff --stat HEAD 2>/dev/null | tail -1 || true)
    fi

    if [[ -f "${CODER_SUMMARY_FILE:-.tekhton/CODER_SUMMARY.md}" ]]; then
        summary_lines=$(wc -l < "${CODER_SUMMARY_FILE:-.tekhton/CODER_SUMMARY.md}" 2>/dev/null || echo "0")
        summary_lines=$(echo "$summary_lines" | tr -d '[:space:]')
    fi

    # If there's substantial work (files changed AND summary > 20 lines),
    # this is partial progress — don't split, let it resume
    if [[ -n "$diff_stat" ]] && [[ "$summary_lines" -gt 20 ]]; then
        has_substantive_work=true
    fi

    if [[ "$has_substantive_work" = true ]]; then
        log "Coder produced substantive partial work — preserving for resume (not splitting)."
        return 1
    fi

    # Record the failed attempt
    record_milestone_attempt "$milestone_num" "null_run" "${LAST_AGENT_TURNS:-0}"

    # Perform the split
    warn "Null-run detected on milestone ${milestone_num} — attempting auto-split..."

    if ! split_milestone "$milestone_num" "$claude_md"; then
        error "Auto-split failed for milestone ${milestone_num}."
        return 1
    fi

    return 0
}
