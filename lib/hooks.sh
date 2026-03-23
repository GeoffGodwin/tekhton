#!/usr/bin/env bash
# =============================================================================
# hooks.sh — Post-pipeline utility functions (commit, archive, final checks)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: LOG_DIR, TIMESTAMP, ANALYZE_CMD, TEST_CMD (set by caller/config)
# =============================================================================

# --- Report archiving --------------------------------------------------------
#
# Usage:  archive_reports "/path/to/log_dir" "20260305_120000"
# Copies all agent report files to the log directory with a timestamp prefix.
archive_reports() {
    local log_dir="$1"
    local timestamp="$2"

    for f in CODER_SUMMARY.md REVIEWER_REPORT.md TESTER_REPORT.md JR_CODER_SUMMARY.md SECURITY_REPORT.md SECURITY_NOTES.md; do
        if [ -f "$f" ]; then
            cp "$f" "${log_dir}/${timestamp}_${f}"
        fi
    done
}

# --- Git safety checks -------------------------------------------------------

# _check_gitignore_safety — Warns if .gitignore is missing or lacks common
# sensitive file patterns. Called before `git add` to prevent accidental commits
# of credentials, keys, or log files.
_check_gitignore_safety() {
    if [ ! -f ".gitignore" ]; then
        warn "[git] WARNING: No .gitignore found. Sensitive files may be staged."
        warn "[git] Create a .gitignore with at least: .env *.pem *.key id_rsa .claude/logs/"
        return
    fi

    local missing_patterns=()
    for pattern in ".env" "*.pem" "*.key" "id_rsa"; do
        if ! grep -qF "$pattern" .gitignore 2>/dev/null; then
            missing_patterns+=("$pattern")
        fi
    done

    if [ ${#missing_patterns[@]} -gt 0 ]; then
        warn "[git] WARNING: .gitignore may be missing sensitive patterns: ${missing_patterns[*]}"
        warn "[git] Consider adding them to prevent accidental credential commits."
    fi
}

# _sanitize_for_commit — Strips control characters and newlines from a string
# to prevent commit message injection.
_sanitize_for_commit() {
    local input="$1"
    # Strip control characters (except space/tab), carriage returns, and newlines
    printf '%s' "$input" | tr -d '\000-\010\013\014\016-\037\177' | tr '\n\r' '  '
}

# --- Commit message generation -----------------------------------------------
#
# Usage:  generate_commit_message "task description" [milestone_num] [disposition]
# Reads CODER_SUMMARY.md and produces a conventional-commit-style message on stdout.
# When milestone_num is provided, the commit message is prefixed with a milestone
# signature and a status line is appended to the body.
generate_commit_message() {
    local task="$1"
    local milestone_num="${2:-}"
    local disposition="${3:-}"

    # Sanitize task string to prevent commit message injection
    task=$(_sanitize_for_commit "$task")

    # All commands in this function must be guarded against pipefail — awk | head
    # can cause SIGPIPE, and grep -q returns non-zero on no match.
    local what=""
    if [ -f "CODER_SUMMARY.md" ]; then
        what=$(awk '/^## What [Ww]as [Ii]mplemented/{found=1; next} found && /^##/{exit} found && NF{print; exit}' CODER_SUMMARY.md 2>/dev/null || true)
        what=$(echo "$what" | head -c 120)
    fi

    local file_count=0
    if [ -f "CODER_SUMMARY.md" ]; then
        file_count=$(awk '/^## Files ([Cc]reated|[Mm]odified)/{found=1; next} found && /^##/{exit} found && /^[-*]/{count++} END{print count+0}' CODER_SUMMARY.md 2>/dev/null || echo "0")
    fi

    local prefix="feat"
    if echo "$task" | grep -qi "^fix"; then prefix="fix"
    elif echo "$task" | grep -qi "^refactor"; then prefix="refactor"
    elif echo "$task" | grep -qi "^test"; then prefix="test"
    elif echo "$task" | grep -qi "^chore"; then prefix="chore"
    elif echo "$task" | grep -qi "^docs"; then prefix="docs"
    fi

    local subject
    subject="${prefix}: $(echo "$task" | sed "s/^[Ff]ix: //;s/^[Ff]eat: //;s/^[Rr]efactor: //" | cut -c1-72)"

    # Prepend milestone prefix if in milestone mode
    if [ -n "$milestone_num" ]; then
        local ms_prefix
        ms_prefix=$(get_milestone_commit_prefix "$milestone_num" "$disposition")
        if [ -n "$ms_prefix" ]; then
            subject="${ms_prefix} ${subject}"
        fi
    fi

    local body=""
    if [ -n "$what" ]; then
        body=$(awk '/^## What [Ww]as [Ii]mplemented/{found=1; next} found && /^##/{exit} found{print}' CODER_SUMMARY.md 2>/dev/null | sed '/^$/d' | head -15 | sed 's/^[-*] /- /' || true)
    fi

    # Include root cause for bug fixes
    if [ -f "CODER_SUMMARY.md" ] && echo "$task" | grep -Eqi "fix|bug"; then
        local root_cause
        root_cause=$(awk '/^## Root [Cc]ause/{found=1; next} found && /^##/{exit} found && NF{print}' CODER_SUMMARY.md 2>/dev/null | sed '/^$/d' | head -5 || true)
        if [ -n "$root_cause" ] && ! echo "$root_cause" | grep -Eqi "^n/a|^none|^\(fill"; then
            body="${body:+${body}
}
Root cause:
${root_cause}"
        fi
    fi

    # Append git diff --stat for a concrete file list and change summary.
    # Compare working tree against HEAD — no pre-staging required. Staging
    # happens once in _do_git_commit() right before the actual commit.
    local diff_stat=""
    diff_stat=$(git diff HEAD --stat 2>/dev/null || true)
    if [ -z "$diff_stat" ]; then
        diff_stat=$(git diff --stat 2>/dev/null || true)
    fi
    if [ -z "$diff_stat" ]; then
        diff_stat=$(git diff --cached --stat 2>/dev/null || true)
    fi
    if [ -n "$diff_stat" ]; then
        # Last line of diff --stat is the summary (e.g., "7 files changed, 73 insertions(+), 54 deletions(-)")
        local diff_summary
        diff_summary=$(echo "$diff_stat" | tail -1 | sed 's/^ *//')
        # File lines are everything except the summary
        local diff_files
        diff_files=$(echo "$diff_stat" | awk 'NR>1{print prev} {prev=$0}' | sed 's/^ *//' | head -20)
        if [ -n "$diff_summary" ]; then
            body="${body:+${body}
}
Files changed:
${diff_files}
${diff_summary}"
        fi
    elif [ -n "$file_count" ] && [ "$file_count" -gt 0 ] 2>/dev/null; then
        body="${body}
- ${file_count} files created or modified"
    fi

    # Append milestone status line to the body
    if [ -n "$milestone_num" ]; then
        local ms_body
        ms_body=$(get_milestone_commit_body "$milestone_num" "$disposition")
        if [ -n "$ms_body" ]; then
            if [ -n "$body" ]; then
                body="${body}

${ms_body}"
            else
                body="${ms_body}"
            fi
        fi
    fi

    # Append completed non-blocking and resolved drift items to the body.
    # Defensive guards: drift_cleanup.sh is always sourced before hooks.sh in the
    # current pipeline, so these functions always exist. The guards protect against
    # future refactors that might change sourcing order or make drift_cleanup optional.
    local nb_items=""
    if command -v get_completed_nonblocking_notes >/dev/null 2>&1; then
        nb_items=$(get_completed_nonblocking_notes 2>/dev/null || true)
    fi
    local drift_items=""
    if command -v get_resolved_drift_observations >/dev/null 2>&1; then
        drift_items=$(get_resolved_drift_observations 2>/dev/null || true)
    fi

    if [ -n "$nb_items" ] || [ -n "$drift_items" ]; then
        local debt_section=""
        if [ -n "$nb_items" ]; then
            local nb_count
            nb_count=$(echo "$nb_items" | wc -l | tr -d '[:space:]')
            debt_section="Non-blocking notes resolved (${nb_count}):"
            while IFS= read -r item; do
                [ -z "$item" ] && continue
                # Strip the checkbox and date prefix, keep the description
                local desc
                # shellcheck disable=SC2001
                desc=$(echo "$item" | sed 's/^- \[x\] \[[^]]*\] //')
                debt_section="${debt_section}
  - ${desc}"
            done <<< "$nb_items"
        fi
        if [ -n "$drift_items" ]; then
            local dr_count
            dr_count=$(echo "$drift_items" | wc -l | tr -d '[:space:]')
            if [ -n "$debt_section" ]; then
                debt_section="${debt_section}
"
            fi
            debt_section="${debt_section}Drift observations resolved (${dr_count}):"
            while IFS= read -r item; do
                [ -z "$item" ] && continue
                # Strip the [RESOLVED date] prefix and the original date/task prefix
                local desc
                desc=$(echo "$item" | sed 's/^- \[RESOLVED [^]]*\] //' | sed 's/^\[[^]]*\] //')
                debt_section="${debt_section}
  - ${desc}"
            done <<< "$drift_items"
        fi

        if [ -n "$body" ]; then
            body="${body}

${debt_section}"
        else
            body="${debt_section}"
        fi
    fi

    echo "$subject"
    if [ -n "$body" ]; then echo "" && echo "$body"; fi
}

# --- Final checks (analyze + test) -------------------------------------------
#
# Usage:  run_final_checks "$LOG_FILE"
# Runs analyze, optionally spawns a cleanup agent, then runs the test suite.
# Returns: 0 if both clean, 1 if issues remain.
run_final_checks() {
    local log_file="$1"
    local final_result=0

    header "Final Checks"

    log "Running ${ANALYZE_CMD}..."
    set +e
    ANALYZE_OUTPUT=$(bash -c "${ANALYZE_CMD}" 2>&1)
    ANALYZE_EXIT=$?
    set -e
    echo "$ANALYZE_OUTPUT" >> "$log_file"

    if [ $ANALYZE_EXIT -eq 0 ] && ! echo "$ANALYZE_OUTPUT" | grep -qE "^  (warning|error|info)"; then
        print_run_summary
        success "${ANALYZE_CMD}: clean"
    else
        # Count errors vs warnings
        ERROR_COUNT=$(echo "$ANALYZE_OUTPUT" | grep -c "^  error" || true)
        WARN_COUNT=$(echo "$ANALYZE_OUTPUT" | grep -c "^  warning" || true)
        INFO_COUNT=$(echo "$ANALYZE_OUTPUT" | grep -c "^  info" || true)
        ERROR_COUNT=$(echo "$ERROR_COUNT" | tr -d '[:space:]')
        WARN_COUNT=$(echo "$WARN_COUNT" | tr -d '[:space:]')
        INFO_COUNT=$(echo "$INFO_COUNT" | tr -d '[:space:]')

        warn "${ANALYZE_CMD}: ${ERROR_COUNT} error(s), ${WARN_COUNT} warning(s), ${INFO_COUNT} info(s)"

        # Run a jr coder cleanup pass for warnings/infos — senior coder for errors
        CLEANUP_MODEL="$CLAUDE_JR_CODER_MODEL"
        CLEANUP_TURNS="$JR_CODER_MAX_TURNS"
        if [ "$ERROR_COUNT" -gt 0 ]; then
            warn "Errors found — escalating cleanup to senior coder."
            CLEANUP_MODEL="$CLAUDE_CODER_MODEL"
            CLEANUP_TURNS="$CODER_MAX_TURNS"
        fi

        warn "Running analyze cleanup pass (${CLEANUP_MODEL})..."

        export ANALYZE_ISSUES
        ANALYZE_ISSUES=$(echo "$ANALYZE_OUTPUT" | grep -E "^  (error|warning|info)" || true)
        CLEANUP_PROMPT=$(render_prompt "analyze_cleanup")

        run_agent \
            "Analyze Cleanup" \
            "$CLEANUP_MODEL" \
            "$CLEANUP_TURNS" \
            "$CLEANUP_PROMPT" \
            "$log_file" \
            "$AGENT_TOOLS_CLEANUP"

        # Re-run analyze to confirm cleanup worked
        log "Re-running ${ANALYZE_CMD} after cleanup..."
        if bash -c "${ANALYZE_CMD}" 2>&1 | tee -a "$log_file" | grep -qE "^  (error|warning)"; then
            print_run_summary
            error "${ANALYZE_CMD}: warnings or errors remain after cleanup. Review before merging."
            final_result=1
        else
            print_run_summary
            success "${ANALYZE_CMD}: clean after cleanup pass."
        fi
    fi

    echo
    log "Running ${TEST_CMD}..."
    if bash -c "${TEST_CMD}" 2>&1 | tee -a "$log_file"; then
        print_run_summary
        success "${TEST_CMD}: all passing"
    else
        print_run_summary
        error "${TEST_CMD}: failures detected (see output above)."
        final_result=1
    fi

    return $final_result
}
