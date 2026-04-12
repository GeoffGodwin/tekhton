#!/usr/bin/env bash
# =============================================================================
# stages/tester_validation.sh — Post-tester output validation and routing
#
# Sourced by tester.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, etc.)
# Provides: _validate_tester_output()
# =============================================================================

set -euo pipefail

# _validate_tester_output — Validate tester agent output and route next steps.
# Handles: missing report, compilation errors, test failures, partial runs,
#          and clean completion.
# Args: $1 = resume_flag, $2 = _tester_stage_start timestamp
_validate_tester_output() {
    local resume_flag="$1"
    local _tester_stage_start="$2"

    if [ ! -f "${TESTER_REPORT_FILE}" ]; then
        warn "Tester did not produce ${TESTER_REPORT_FILE}."
        # Check if test files were created despite missing report
        local _test_file_count=0
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
            _test_file_count=$(git diff --name-only HEAD 2>/dev/null | grep -ciE 'test|spec' || echo "0")
        fi
        if [[ "$_test_file_count" -gt 0 ]]; then
            warn "Tester created ${_test_file_count} test file(s) but no report — synthesizing minimal ${TESTER_REPORT_FILE}."
            local _test_files
            _test_files=$(git diff --name-only HEAD 2>/dev/null | grep -iE 'test|spec' | head -20 || true)
            cat > "${TESTER_REPORT_FILE}" <<TESTER_EOF
## Test Summary
${TESTER_REPORT_FILE} was synthesized by the pipeline. The tester agent created
test files but did not produce a report. Review the test files directly.

## Test Files Created
$(echo "$_test_files" | sed 's/^/- [x] `/' | sed 's/$/`/')

## Bugs Found
None
TESTER_EOF
        else
            warn "Check the log: ${LOG_FILE}"
            warn "Re-run with: $0 --start-at test \"${TASK}\""
        fi
    else
        REMAINING=$(grep -c "^- \[ \]" "${TESTER_REPORT_FILE}" || true)
        REMAINING=$(echo "$REMAINING" | tr -d '[:space:]')

        # Check for compilation errors or test failures in the log
        if grep -q "Compilation failed" "$LOG_FILE" || grep -q "Failed to load" "$LOG_FILE"; then
            error "One or more test files failed to compile. The tester report may be inaccurate."
            error "Compilation errors detected in:"
            local _failed_paths
            _failed_paths=$(grep "Compilation failed for testPath=" "$LOG_FILE" | sed 's/.*testPath=/  /' | sed 's/:.*//' | sort -u)
            echo "$_failed_paths"
            warn "Fix the failing test files, then resume with: $0 --start-at tester \"${TASK}\""
            # Mark affected test files as unchecked in ${TESTER_REPORT_FILE} so resume picks them up
            local FAILED_FILES
            FAILED_FILES=$(grep "Compilation failed for testPath=" "$LOG_FILE" | sed 's/.*testPath=//' | sed 's/:.*//' | sort -u)
            local FAILED
            for FAILED in $FAILED_FILES; do
                local BASENAME
                BASENAME=$(basename "$FAILED")
                # Flip [x] back to [ ] for the failed file in the report
                sed -i "s|\[x\] \`.*${BASENAME}.*\`|- [ ] \`${BASENAME}\` — COMPILATION FAILED: re-read source models before rewriting|g" "${TESTER_REPORT_FILE}"
            done
            warn "${TESTER_REPORT_FILE} updated — failed files reset to unchecked for resume."
        elif grep -qE "^\s+-[0-9]+:" "$LOG_FILE" || grep -q " -[1-9][0-9]*:" "$LOG_FILE"; then
            # --- Inline tester fix agent (M64 — replaces recursive pipeline spawn) ---
            if [[ "${TESTER_FIX_ENABLED:-false}" == "true" ]] \
               && [[ "${TESTER_FIX_MAX_DEPTH:-1}" -gt 0 ]]; then
                _run_tester_inline_fix
            else
                error "${TEST_CMD} reported failures. Review ${TESTER_REPORT_FILE} and the log."
                if [[ "${TESTER_FIX_ENABLED:-false}" != "true" ]]; then
                    warn "Set TESTER_FIX_ENABLED=true in pipeline.conf to enable auto-fix."
                fi
                warn "Resume with: $0 --start-at tester \"${TASK}\""
            fi
        elif [ "$REMAINING" -gt 0 ]; then
            warn "Tester completed partial run — ${REMAINING} planned test(s) not yet written."

            # --- Turn exhaustion continuation for tester (Milestone 14) ---
            # Extracted to stages/tester_continuation.sh
            _TESTER_CONTINUED=false
            _tester_run_continuations "$resume_flag" "$_tester_stage_start"

            if [[ "$_TESTER_CONTINUED" = false ]]; then
                local resume_tester_flag
                resume_tester_flag="$(_build_resume_flag tester)"

                write_pipeline_state \
                    "tester" \
                    "partial_tests" \
                    "$resume_tester_flag" \
                    "${TASK}" \
                    "${REMAINING} test(s) remaining — ${TESTER_REPORT_FILE} has the checklist"

                warn "State saved — re-run with no arguments to resume."
            fi
        else
            print_run_summary
            success "Tester agent finished — all planned tests written and passing."
            # Clean run — clear any stale state
            clear_pipeline_state

            # --- Test integrity audit (M20) ---
            _run_and_record_test_audit
        fi
    fi
}
