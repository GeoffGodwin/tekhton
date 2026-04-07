#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# gates_completion.sh — Completion gate and summary accuracy check
#
# Sourced by tekhton.sh after gates.sh — do not run directly.
# Provides: run_completion_gate(), _warn_summary_drift()
#
# Extracted from gates.sh to keep file sizes under the 300-line ceiling.
# =============================================================================

# --- Summary accuracy check ---------------------------------------------------
# Cross-checks CODER_SUMMARY.md "Files Modified" section against actual git diff.
# Logs a warning when the summary underreports changes. Non-blocking — informational only.
_warn_summary_drift() {
    [[ -f "CODER_SUMMARY.md" ]] || return 0

    # Count files actually changed (tracked modifications + staged)
    local actual_count=0
    if command -v git &>/dev/null; then
        actual_count=$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d '[:space:]')
        actual_count="${actual_count:-0}"
    fi
    [[ "$actual_count" -gt 0 ]] || return 0

    # Check if summary mentions files or claims none modified
    local files_section=""
    files_section=$(sed -n '/^## Files Modified/,/^## /p' CODER_SUMMARY.md 2>/dev/null \
        | head -20 || true)

    if [[ -z "$files_section" ]] || echo "$files_section" | grep -qi "no files\|none\|N/A"; then
        warn "CODER_SUMMARY.md reports no files modified but git shows ${actual_count} changed file(s)."
        warn "Summary accuracy drift detected — auto-appending actual file list."
        # Auto-append the actual git diff file list to CODER_SUMMARY.md
        local _actual_files
        _actual_files=$(git diff --name-only HEAD 2>/dev/null | head -30)
        if [[ -n "$_actual_files" ]]; then
            {
                echo ""
                echo "## Files Modified (auto-detected)"
                echo "$_actual_files" | while IFS= read -r f; do echo "- \`${f}\`"; done
            } >> CODER_SUMMARY.md
        fi
    fi
}

# COMPLETION GATE — runs after coder, before build gate
# Blocks pipeline progression if coder did not self-report completion
#
# Usage:  run_completion_gate
# Returns: 0 if CODER_SUMMARY.md shows COMPLETE, 1 otherwise
run_completion_gate() {
    # Handle both "## Status: VALUE" (single-line) and "## Status\nVALUE" (next-line) formats.
    CODER_STATUS=$(awk '/^## Status/{
        sub(/^## Status:?[[:space:]]*/, "")
        if (length($0) > 0) { print; exit }
        getline; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit
    }' CODER_SUMMARY.md 2>/dev/null || echo "")
    export CODER_REMAINING
    CODER_REMAINING=$(grep "^## Remaining Work" -A5 CODER_SUMMARY.md 2>/dev/null || echo "")

    if [[ "$CODER_STATUS" == *"IN PROGRESS"* ]]; then
        warn "Completion gate FAILED — coder self-reported IN PROGRESS."
        return 1
    fi

    if [[ "$CODER_STATUS" == *"COMPLETE"* ]]; then
        log "Completion gate PASSED — coder self-reported COMPLETE."
        _warn_summary_drift

        # --- Test enforcement (M63) ---
        # Run TEST_CMD to verify tests still pass after coder changes.
        if [[ "${COMPLETION_GATE_TEST_ENABLED:-true}" == "true" ]] \
           && [[ -n "${TEST_CMD:-}" ]] && [[ "${TEST_CMD}" != "true" ]]; then
            log "Completion gate: running TEST_CMD for test integrity check..."
            local _cg_output="" _cg_exit=0
            _cg_output=$(bash -c "${TEST_CMD}" 2>&1) || _cg_exit=$?

            if [[ "$_cg_exit" -eq 0 ]]; then
                log "Completion gate: TEST_CMD passed."
            else
                # Compare against baseline — pre-existing failures should not block
                if declare -f compare_test_with_baseline &>/dev/null \
                   && declare -f has_test_baseline &>/dev/null \
                   && has_test_baseline 2>/dev/null; then
                    local _cg_comparison
                    _cg_comparison=$(compare_test_with_baseline "$_cg_output" "$_cg_exit")
                    if [[ "$_cg_comparison" == "pre_existing" ]]; then
                        log "Completion gate: test failures are pre-existing — passing."
                    else
                        warn "Completion gate FAILED — TEST_CMD exited ${_cg_exit} with new failures."
                        return 1
                    fi
                else
                    warn "Completion gate FAILED — TEST_CMD exited ${_cg_exit} (no baseline for comparison)."
                    return 1
                fi
            fi
        fi

        return 0
    fi

    # Status is missing or ambiguous — check if substantive work exists.
    # If files were modified, treat as IN PROGRESS rather than hard-failing.
    if command -v is_substantive_work &>/dev/null && is_substantive_work; then
        warn "Completion gate — Status field missing but substantive work detected."
        warn "Treating as IN PROGRESS. Reviewer will assess actual changes."
        return 1
    fi

    warn "Completion gate FAILED — CODER_SUMMARY.md has no clear Status field."
    warn "Expected '## Status' line with COMPLETE or IN PROGRESS."
    return 1
}
