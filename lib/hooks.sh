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

    for f in CODER_SUMMARY.md REVIEWER_REPORT.md TESTER_REPORT.md JR_CODER_SUMMARY.md; do
        if [ -f "$f" ]; then
            cp "$f" "${log_dir}/${timestamp}_${f}"
        fi
    done
}

# --- Commit message generation -----------------------------------------------
#
# Usage:  generate_commit_message "task description"
# Reads CODER_SUMMARY.md and produces a conventional-commit-style message on stdout.
generate_commit_message() {
    local task="$1"

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
    local body=""
    if [ -n "$what" ]; then
        body=$(awk '/^## What [Ww]as [Ii]mplemented/{found=1; next} found && /^##/{exit} found{print}' CODER_SUMMARY.md 2>/dev/null | sed '/^$/d' | head -5 | sed 's/^[-*] /- /' || true)
    fi
    if [ -n "$file_count" ] && [ "$file_count" -gt 0 ] 2>/dev/null; then
        body="${body}
- ${file_count} files created or modified"
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
    ANALYZE_OUTPUT=$(${ANALYZE_CMD} 2>&1)
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
            "$log_file"

        # Re-run analyze to confirm cleanup worked
        log "Re-running ${ANALYZE_CMD} after cleanup..."
        if ${ANALYZE_CMD} 2>&1 | tee -a "$log_file" | grep -qE "^  (error|warning)"; then
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
    if ${TEST_CMD} 2>&1 | tee -a "$log_file"; then
        print_run_summary
        success "${TEST_CMD}: all passing"
    else
        print_run_summary
        error "${TEST_CMD}: failures detected (see output above)."
        final_result=1
    fi

    return $final_result
}
