#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# checkpoint_display.sh — Checkpoint display helpers
#
# Sourced by tekhton.sh after checkpoint.sh — do not run directly.
# Expects: _checkpoint_path(), _ckpt_read_field(), _ckpt_read_bool()
#          from checkpoint.sh
# =============================================================================

# --- show_checkpoint_info ----------------------------------------------------

show_checkpoint_info() {
    if [[ "${CHECKPOINT_ENABLED:-true}" != "true" ]]; then
        echo "Checkpoints are disabled (CHECKPOINT_ENABLED=false)."
        return 0
    fi

    local ckpt_file
    ckpt_file="$(_checkpoint_path)"
    if [[ ! -f "$ckpt_file" ]]; then
        echo "No checkpoint found — nothing to rollback."
        return 0
    fi

    local timestamp head_sha auto_committed commit_sha stash_ref had_uncommitted task milestone
    timestamp=$(_ckpt_read_field "$ckpt_file" "timestamp")
    head_sha=$(_ckpt_read_field "$ckpt_file" "head_sha")
    auto_committed=$(_ckpt_read_bool "$ckpt_file" "auto_committed")
    commit_sha=$(_ckpt_read_field "$ckpt_file" "commit_sha")
    stash_ref=$(_ckpt_read_field "$ckpt_file" "stash_ref")
    had_uncommitted=$(_ckpt_read_bool "$ckpt_file" "had_uncommitted")
    task=$(_ckpt_read_field "$ckpt_file" "task")
    milestone=$(_ckpt_read_field "$ckpt_file" "milestone")

    # Calculate age
    local age_str="unknown"
    if [[ -n "$timestamp" ]]; then
        local ckpt_epoch now_epoch
        ckpt_epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo "0")
        now_epoch=$(date +%s)
        if [[ "$ckpt_epoch" -gt 0 ]]; then
            local age_secs=$(( now_epoch - ckpt_epoch ))
            if [[ "$age_secs" -lt 60 ]]; then
                age_str="${age_secs}s ago"
            elif [[ "$age_secs" -lt 3600 ]]; then
                age_str="$(( age_secs / 60 ))m ago"
            elif [[ "$age_secs" -lt 86400 ]]; then
                age_str="$(( age_secs / 3600 ))h ago"
            else
                age_str="$(( age_secs / 86400 ))d ago"
            fi
        fi
    fi

    echo
    echo "════════════════════════════════════════"
    echo "  Checkpoint Info (rollback preview)"
    echo "════════════════════════════════════════"
    echo "  Task:       ${task:-unknown}"
    if [[ -n "$milestone" ]]; then
        echo "  Milestone:  ${milestone}"
    fi
    echo "  Created:    ${timestamp} (${age_str})"
    echo "  Base HEAD:  ${head_sha}"
    echo

    if [[ "$auto_committed" == "true" ]] && [[ -n "$commit_sha" ]] && [[ "$commit_sha" != "null" ]]; then
        local short_sha
        short_sha=$(git rev-parse --short "$commit_sha" 2>/dev/null || echo "$commit_sha")
        local commit_subject
        commit_subject=$(git log --format='%s' -1 "$commit_sha" 2>/dev/null || echo "unknown")
        echo "  Would revert: commit ${short_sha} (\"${commit_subject}\")"
        # Show changed files
        local changed_files
        changed_files=$(git diff --name-only "${commit_sha}~1" "$commit_sha" 2>/dev/null || true)
        if [[ -n "$changed_files" ]]; then
            local file_count
            file_count=$(echo "$changed_files" | wc -l | tr -d '[:space:]')
            echo "  Files affected: ${file_count}"
            echo "$changed_files" | head -10 | sed 's/^/    /'
            if [[ "$file_count" -gt 10 ]]; then
                echo "    ... and $(( file_count - 10 )) more"
            fi
        fi
    else
        echo "  Would discard: uncommitted pipeline changes"
    fi

    if [[ "$had_uncommitted" == "true" ]] && [[ -n "$stash_ref" ]]; then
        echo "  Would restore: pre-run uncommitted changes from stash"
    fi
    echo "════════════════════════════════════════"
    echo
}
