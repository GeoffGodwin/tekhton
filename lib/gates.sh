#!/usr/bin/env bash
# =============================================================================
# gates.sh — Build and completion gate functions
#
# Sourced by tekhton.sh — do not run directly.
# Expects: ANALYZE_CMD, ANALYZE_ERROR_PATTERN, BUILD_CHECK_CMD,
#           BUILD_ERROR_PATTERN (set by config.sh)
# =============================================================================

# BUILD GATE — runs after coder, before reviewer
# Catches broken builds before wasting reviewer/tester turns on bad code
#
# Usage:  run_build_gate "post-coder"
# Returns: 0 on pass, 1 on failure (writes BUILD_ERRORS.md on failure)
run_build_gate() {
    local stage_label="$1"  # "post-coder" or "post-jr-coder"
    log "Running build gate (${stage_label})..."

    # Capture analyze errors only (warnings are ok, errors are not)
    # Use bash -c instead of unquoted expansion to avoid word-splitting issues
    ANALYZE_OUTPUT=$(bash -c "${ANALYZE_CMD}" 2>&1)
    ANALYZE_ERRORS=$(echo "$ANALYZE_OUTPUT" | grep -E "${ANALYZE_ERROR_PATTERN}" || true)

    if [ -n "$ANALYZE_ERRORS" ]; then
        warn "Build gate FAILED (${stage_label}) — analyze errors found:"
        echo "$ANALYZE_ERRORS"

        # Write errors to a file so the coder can read them directly
        cat > BUILD_ERRORS.md << EOF
# Build Errors — $(date '+%Y-%m-%d %H:%M:%S')
## Stage
${stage_label}

## Analyze Errors
\`\`\`
${ANALYZE_ERRORS}
\`\`\`

## Full Analyze Output
\`\`\`
${ANALYZE_OUTPUT}
\`\`\`
EOF
        log "Build errors written to BUILD_ERRORS.md"
        return 1
    fi

    # Also run a quick compile check (no device needed)
    if [ -n "${BUILD_CHECK_CMD}" ]; then
        # Use bash -c instead of eval to avoid arbitrary code execution
        COMPILE_OUTPUT=$(bash -c "${BUILD_CHECK_CMD}" 2>&1)
        if echo "$COMPILE_OUTPUT" | grep -q "${BUILD_ERROR_PATTERN}"; then
            COMPILE_ERRORS=$(echo "$COMPILE_OUTPUT" | grep "${BUILD_ERROR_PATTERN}" | head -20)
            warn "Build gate FAILED (${stage_label}) — compile errors found:"
            echo "$COMPILE_ERRORS"

            cat >> BUILD_ERRORS.md << EOF

## Compile Errors
\`\`\`
${COMPILE_ERRORS}
\`\`\`
EOF
            return 1
        fi
    fi  # end BUILD_CHECK_CMD guard

    # --- Dependency constraint validation (P5) ---
    # Runs the validation_command from the constraint manifest, if configured.
    # This is deterministic enforcement — no LLM judgment needed.
    if [ -n "${DEPENDENCY_CONSTRAINTS_FILE:-}" ] && [ -f "${DEPENDENCY_CONSTRAINTS_FILE}" ]; then
        local validation_cmd
        validation_cmd=$(grep "^validation_command:" "${DEPENDENCY_CONSTRAINTS_FILE}" \
            | sed 's/^validation_command: *//' | tr -d '"'"'" 2>/dev/null || true)

        if [ -n "$validation_cmd" ]; then
            log "Running dependency constraint validation: ${validation_cmd}"
            local constraint_output=""
            local constraint_exit=0
            # Use bash -c instead of eval to avoid arbitrary code execution
            constraint_output=$(bash -c "$validation_cmd" 2>&1) || constraint_exit=$?

            if [ "$constraint_exit" -ne 0 ]; then
                warn "Build gate FAILED (${stage_label}) — dependency constraint violations:"
                echo "$constraint_output"

                # Append or create BUILD_ERRORS.md
                cat >> BUILD_ERRORS.md << EOF

## Dependency Constraint Violations
\`\`\`
${constraint_output}
\`\`\`
EOF
                return 1
            fi
            log "Dependency constraints passed."
        fi
    fi

    # --- UI test validation (Milestone 28) ---
    # Runs UI_TEST_CMD when configured and non-empty. Missing command = warning, not failure.
    # Retries once on failure (E2E tests are inherently flaky).
    if [[ -n "${UI_TEST_CMD:-}" ]] && [[ "${UI_VALIDATION_ENABLED:-true}" == "true" ]]; then
        local _ui_cmd_bin
        _ui_cmd_bin=$(echo "$UI_TEST_CMD" | awk '{print $1}')

        # Check if command is available (npx/npm resolve at runtime)
        local _ui_cmd_available=true
        if [[ "$_ui_cmd_bin" != "npx" ]] && [[ "$_ui_cmd_bin" != "npm" ]]; then
            if ! command -v "$_ui_cmd_bin" &>/dev/null; then
                _ui_cmd_available=false
            fi
        fi

        if [[ "$_ui_cmd_available" == "true" ]]; then
            log "Running UI tests: ${UI_TEST_CMD}"
            local _ui_output="" _ui_exit=0
            local _ui_timeout="${UI_TEST_TIMEOUT:-120}"
            _ui_output=$(timeout "$_ui_timeout" bash -c "$UI_TEST_CMD" 2>&1) || _ui_exit=$?

            # Retry once on failure (E2E flakiness mitigation)
            if [[ "$_ui_exit" -ne 0 ]]; then
                log "UI tests failed (exit ${_ui_exit}). Retrying once..."
                _ui_exit=0
                _ui_output=$(timeout "$_ui_timeout" bash -c "$UI_TEST_CMD" 2>&1) || _ui_exit=$?
            fi

            if [[ "$_ui_exit" -ne 0 ]]; then
                warn "Build gate FAILED (${stage_label}) — UI tests failed:"
                echo "$_ui_output" | tail -30

                cat > UI_TEST_ERRORS.md << UIEOF
# UI Test Errors — $(date '+%Y-%m-%d %H:%M:%S')
## Stage
${stage_label}

## UI Test Command
\`${UI_TEST_CMD}\`

## Exit Code
${_ui_exit}

## Output (last 100 lines)
\`\`\`
$(echo "$_ui_output" | tail -100)
\`\`\`
UIEOF
                log "UI test errors written to UI_TEST_ERRORS.md"
                return 1
            fi
            log "UI tests passed."
        else
            warn "[build gate] UI_TEST_CMD command '${_ui_cmd_bin}' not found. Skipping UI test gate."
            warn "Install the E2E framework or update UI_TEST_CMD in pipeline.conf."
        fi
    fi

    log "Build gate PASSED (${stage_label})"
    [ -f BUILD_ERRORS.md ] && rm BUILD_ERRORS.md
    [ -f UI_TEST_ERRORS.md ] && rm UI_TEST_ERRORS.md
    return 0
}

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
        warn "Summary accuracy drift detected — review CODER_SUMMARY.md before committing."
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
