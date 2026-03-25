#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# checkpoint.sh — Git checkpoint management for run safety net & rollback
#
# Sourced by tekhton.sh — do not run directly.
# Expects: log(), warn(), error(), success() from common.sh
# Expects: CHECKPOINT_ENABLED, CHECKPOINT_FILE from config_defaults.sh
# Expects: PROJECT_DIR, TASK, _CURRENT_MILESTONE from tekhton.sh
#
# Provides:
#   create_run_checkpoint      — Save git state before pipeline execution
#   update_checkpoint_commit   — Record commit sha after auto-commit
#   rollback_last_run          — Revert pipeline changes to pre-run state
#   show_checkpoint_info       — Preview what rollback would do
#   has_checkpoint             — Check if a checkpoint exists
# =============================================================================

# --- Checkpoint path helper --------------------------------------------------

_checkpoint_path() {
    echo "${PROJECT_DIR:-.}/${CHECKPOINT_FILE:-.claude/CHECKPOINT_META.json}"
}

# --- JSON helpers (no jq dependency) -----------------------------------------

# _ckpt_read_field FILE KEY — Extract a string value from simple JSON
_ckpt_read_field() {
    local file="$1" key="$2"
    sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -1
}

# _ckpt_read_bool FILE KEY — Extract a boolean value from simple JSON
_ckpt_read_bool() {
    local file="$1" key="$2"
    sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" "$file" | head -1
}

# --- has_checkpoint ----------------------------------------------------------

has_checkpoint() {
    [[ "${CHECKPOINT_ENABLED:-true}" == "true" ]] || return 1
    local ckpt_file
    ckpt_file="$(_checkpoint_path)"
    [[ -f "$ckpt_file" ]]
}

# --- create_run_checkpoint ---------------------------------------------------

create_run_checkpoint() {
    if [[ "${CHECKPOINT_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    local ckpt_file
    ckpt_file="$(_checkpoint_path)"
    local ckpt_dir
    ckpt_dir="$(dirname "$ckpt_file")"

    # Warn if previous checkpoint exists
    if [[ -f "$ckpt_file" ]]; then
        warn "Previous checkpoint exists — overwriting (only the most recent run is rollback-able)"
    fi

    mkdir -p "$ckpt_dir"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
    local head_sha
    head_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

    local had_uncommitted=false
    local stash_ref=""

    # Check for uncommitted changes (tracked or untracked)
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null \
       || [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        had_uncommitted=true
        local stash_msg="tekhton-checkpoint-${timestamp}"
        # Use --include-untracked to also save new files
        if git stash push --include-untracked -m "$stash_msg" -- . 2>/dev/null; then
            # Find the stash by message (not index, which can shift)
            stash_ref="$stash_msg"
            log "Stashed uncommitted changes: ${stash_msg}"
        else
            warn "git stash failed — checkpoint created without stash"
            had_uncommitted=false
            stash_ref=""
        fi
    fi

    local milestone_id="${_CURRENT_MILESTONE:-}"
    local task_escaped
    # Escape quotes and backslashes for JSON
    task_escaped=$(printf '%s' "${TASK:-}" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Write checkpoint metadata (atomic: tmpfile + mv)
    local tmpfile
    tmpfile=$(mktemp "${ckpt_dir}/checkpoint.XXXXXX")
    cat > "$tmpfile" << EOF
{
  "timestamp": "${timestamp}",
  "head_sha": "${head_sha}",
  "had_uncommitted": ${had_uncommitted},
  "stash_ref": "${stash_ref}",
  "task": "${task_escaped}",
  "milestone": "${milestone_id}",
  "auto_committed": false,
  "commit_sha": null
}
EOF
    mv -f "$tmpfile" "$ckpt_file"
    log "Checkpoint created — use \`tekhton --rollback\` to undo this run"
}

# --- update_checkpoint_commit ------------------------------------------------

update_checkpoint_commit() {
    local commit_sha="${1:-}"
    if [[ "${CHECKPOINT_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    local ckpt_file
    ckpt_file="$(_checkpoint_path)"
    if [[ ! -f "$ckpt_file" ]]; then
        return 0
    fi

    if [[ -z "$commit_sha" ]]; then
        commit_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    fi

    # Read existing checkpoint, update auto_committed and commit_sha
    local tmpfile
    tmpfile=$(mktemp "$(dirname "$ckpt_file")/checkpoint.XXXXXX")
    sed -e "s/\"auto_committed\": false/\"auto_committed\": true/" \
        -e "s/\"commit_sha\": null/\"commit_sha\": \"${commit_sha}\"/" \
        "$ckpt_file" > "$tmpfile"
    mv -f "$tmpfile" "$ckpt_file"
}

# --- _find_stash_by_message --------------------------------------------------
# Find stash index by message string (robust against index shifts)

_find_stash_by_message() {
    local msg="$1"
    local stash_line
    stash_line=$(git stash list 2>/dev/null | grep -F "$msg" | head -1) || true
    if [[ -n "$stash_line" ]]; then
        echo "$stash_line" | cut -d: -f1
        return 0
    fi
    return 1
}

# --- rollback_last_run -------------------------------------------------------

rollback_last_run() {
    if [[ "${CHECKPOINT_ENABLED:-true}" != "true" ]]; then
        error "Checkpoints are disabled (CHECKPOINT_ENABLED=false). Nothing to rollback."
        return 1
    fi

    local ckpt_file
    ckpt_file="$(_checkpoint_path)"
    if [[ ! -f "$ckpt_file" ]]; then
        error "No checkpoint found — nothing to rollback."
        return 1
    fi

    # Read checkpoint fields
    local head_sha auto_committed commit_sha stash_ref had_uncommitted
    head_sha=$(_ckpt_read_field "$ckpt_file" "head_sha")
    auto_committed=$(_ckpt_read_bool "$ckpt_file" "auto_committed")
    commit_sha=$(_ckpt_read_field "$ckpt_file" "commit_sha")
    stash_ref=$(_ckpt_read_field "$ckpt_file" "stash_ref")
    had_uncommitted=$(_ckpt_read_bool "$ckpt_file" "had_uncommitted")

    # Safety check: refuse if uncommitted changes exist that would be lost
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        error "Uncommitted changes detected. Stash or commit them first."
        return 1
    fi

    local reverted_msg=""
    local restored_msg=""

    if [[ "$auto_committed" == "true" ]] && [[ -n "$commit_sha" ]] && [[ "$commit_sha" != "null" ]]; then
        # Verify HEAD is the commit_sha (no additional commits on top)
        local current_head
        current_head=$(git rev-parse HEAD 2>/dev/null)
        if [[ "$current_head" != "$commit_sha" ]]; then
            error "Cannot rollback — commits have been made after the pipeline run."
            error "Use \`git revert ${commit_sha}\` manually."
            return 1
        fi

        # Revert the auto-committed changes (creates a new revert commit)
        local short_sha
        short_sha=$(git rev-parse --short "$commit_sha" 2>/dev/null || echo "$commit_sha")
        local commit_subject
        commit_subject=$(git log --format='%s' -1 "$commit_sha" 2>/dev/null || echo "unknown")
        if git revert --no-edit "$commit_sha" 2>/dev/null; then
            reverted_msg="Reverted: commit ${short_sha} (\"${commit_subject}\")"
        else
            error "git revert failed. Resolve conflicts manually."
            return 1
        fi
    elif [[ "$auto_committed" != "true" ]]; then
        # No commit was made — discard uncommitted changes back to checkpoint HEAD
        git checkout -- . 2>/dev/null || true
        # Also clean untracked files that the pipeline may have created
        git clean -fd 2>/dev/null || true
        reverted_msg="Discarded uncommitted pipeline changes"
    fi

    # Restore pre-run stash if it exists
    if [[ "$had_uncommitted" == "true" ]] && [[ -n "$stash_ref" ]]; then
        local stash_idx
        if stash_idx=$(_find_stash_by_message "$stash_ref"); then
            if git stash pop "$stash_idx" 2>/dev/null; then
                local stash_file_count
                stash_file_count=$(git diff --name-only 2>/dev/null | wc -l | tr -d '[:space:]')
                restored_msg="Restored: ${stash_file_count} file(s) from pre-run state"
            else
                warn "git stash pop failed — your pre-run changes are still in the stash."
                warn "Recover manually with: git stash list | grep tekhton-checkpoint"
            fi
        else
            warn "Pre-run stash not found (may have been manually popped)."
        fi
    fi

    # Clean up checkpoint and pipeline state
    rm -f "$ckpt_file"
    local state_file="${PROJECT_DIR:-.}/${PIPELINE_STATE_FILE:-.claude/PIPELINE_STATE.md}"
    if [[ -f "$state_file" ]]; then
        rm -f "$state_file"
    fi
    local failure_ctx="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
    if [[ -f "$failure_ctx" ]]; then
        rm -f "$failure_ctx"
    fi

    # Print summary
    echo
    success "Rollback complete"
    if [[ -n "$reverted_msg" ]]; then
        echo "  ${reverted_msg}"
    fi
    if [[ -n "$restored_msg" ]]; then
        echo "  ${restored_msg}"
    fi
    echo "  Pipeline state: cleared"
    echo
}

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
