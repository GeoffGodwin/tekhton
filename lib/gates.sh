#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# gates.sh — Build and completion gate functions
#
# Sourced by tekhton.sh — do not run directly.
# Expects: ANALYZE_CMD, ANALYZE_ERROR_PATTERN, BUILD_CHECK_CMD,
#           BUILD_ERROR_PATTERN (set by config.sh)
# =============================================================================

# _gate_effective_timeout PHASE_TIMEOUT GATE_START GATE_TIMEOUT
# Returns the effective timeout for a phase: min(phase_timeout, remaining_gate_time).
# Prints the timeout value. Returns 1 if gate time is already exceeded.
_gate_effective_timeout() {
    local phase_timeout="$1"
    local gate_start="$2"
    local gate_timeout="$3"
    local now elapsed remaining

    now=$(date +%s)
    elapsed=$((now - gate_start))
    remaining=$((gate_timeout - elapsed))

    if [[ "$remaining" -le 0 ]]; then
        return 1
    fi

    if [[ "$phase_timeout" -gt "$remaining" ]]; then
        echo "$remaining"
    else
        echo "$phase_timeout"
    fi
}

# _gate_check_timeout STAGE_LABEL GATE_START GATE_TIMEOUT
# Checks if the overall gate timeout has been exceeded.
# If exceeded, writes BUILD_ERRORS.md and returns 1. Otherwise returns 0.
_gate_check_timeout() {
    local stage_label="$1"
    local gate_start="$2"
    local gate_timeout="$3"
    local now elapsed

    now=$(date +%s)
    elapsed=$((now - gate_start))

    if [[ "$elapsed" -ge "$gate_timeout" ]]; then
        warn "Build gate TIMED OUT after ${gate_timeout}s (${stage_label})."
        warn "This is a safety timeout — the build gate took too long."
        cat > BUILD_ERRORS.md << EOF
# Build Errors — $(date '+%Y-%m-%d %H:%M:%S')
## Stage
${stage_label}

## Gate Timeout
The build gate exceeded the overall timeout of ${gate_timeout}s.
This typically indicates a hanging subprocess (e.g., static analysis,
UI server, or headless browser). Check BUILD_GATE_TIMEOUT in pipeline.conf.
EOF
        return 1
    fi
    return 0
}

# BUILD GATE — runs after coder, before reviewer
# Catches broken builds before wasting reviewer/tester turns on bad code
#
# Usage:  run_build_gate "post-coder"
# Returns: 0 on pass, 1 on failure (writes BUILD_ERRORS.md on failure)
run_build_gate() {
    local stage_label="$1"  # "post-coder" or "post-jr-coder"
    local gate_timeout="${BUILD_GATE_TIMEOUT:-600}"
    local gate_start
    gate_start=$(date +%s)

    log "Running build gate (${stage_label})..."
    _phase_start "build_gate"

    # --- Phase 1: Static analysis (ANALYZE_CMD) ---
    _phase_start "build_gate_analyze"
    local analyze_timeout="${BUILD_GATE_ANALYZE_TIMEOUT:-300}"
    local effective_timeout
    effective_timeout=$(_gate_effective_timeout "$analyze_timeout" "$gate_start" "$gate_timeout") || {
        _gate_check_timeout "$stage_label" "$gate_start" "$gate_timeout"
        return 1
    }

    local analyze_exit=0
    # Capture analyze errors only (warnings are ok, errors are not)
    # Wrapped in a configurable timeout to prevent runaway static analysis
    ANALYZE_OUTPUT=$(timeout "$effective_timeout" bash -c "${ANALYZE_CMD}" 2>&1) || analyze_exit=$?

    if [[ "$analyze_exit" -eq 124 ]]; then
        warn "ANALYZE_CMD timed out after ${effective_timeout}s (${stage_label}). Treating as pass."
        warn "Increase BUILD_GATE_ANALYZE_TIMEOUT if this is expected."
        ANALYZE_OUTPUT=""
    fi

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
        _phase_end "build_gate_analyze"
        _phase_end "build_gate"
        return 1
    fi

    _phase_end "build_gate_analyze"

    # Check overall gate timeout before next phase
    _gate_check_timeout "$stage_label" "$gate_start" "$gate_timeout" || { _phase_end "build_gate"; return 1; }

    # --- Phase 2: Compile check (BUILD_CHECK_CMD) ---
    if [ -n "${BUILD_CHECK_CMD}" ]; then
        _phase_start "build_gate_compile"
        local compile_timeout="${BUILD_GATE_COMPILE_TIMEOUT:-120}"
        effective_timeout=$(_gate_effective_timeout "$compile_timeout" "$gate_start" "$gate_timeout") || {
            _gate_check_timeout "$stage_label" "$gate_start" "$gate_timeout"
            return 1
        }

        local compile_exit=0
        # Use bash -c instead of eval to avoid arbitrary code execution
        COMPILE_OUTPUT=$(timeout "$effective_timeout" bash -c "${BUILD_CHECK_CMD}" 2>&1) || compile_exit=$?

        if [[ "$compile_exit" -eq 124 ]]; then
            warn "BUILD_CHECK_CMD timed out after ${effective_timeout}s (${stage_label}). Treating as pass."
            COMPILE_OUTPUT=""
        fi
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
            _phase_end "build_gate_compile"
            _phase_end "build_gate"
            return 1
        fi
        _phase_end "build_gate_compile"
    fi  # end BUILD_CHECK_CMD guard

    # Check overall gate timeout before next phase
    _gate_check_timeout "$stage_label" "$gate_start" "$gate_timeout" || { _phase_end "build_gate"; return 1; }

    # --- Phase 3: Dependency constraint validation (P5) ---
    # Runs the validation_command from the constraint manifest, if configured.
    # This is deterministic enforcement — no LLM judgment needed.
    if [ -n "${DEPENDENCY_CONSTRAINTS_FILE:-}" ] && [ -f "${DEPENDENCY_CONSTRAINTS_FILE}" ]; then
        local validation_cmd
        validation_cmd=$(grep "^validation_command:" "${DEPENDENCY_CONSTRAINTS_FILE}" \
            | sed 's/^validation_command: *//' | tr -d '"'"'" 2>/dev/null || true)

        if [ -n "$validation_cmd" ]; then
            _phase_start "build_gate_constraints"
            local constraint_timeout="${BUILD_GATE_CONSTRAINT_TIMEOUT:-60}"
            effective_timeout=$(_gate_effective_timeout "$constraint_timeout" "$gate_start" "$gate_timeout") || {
                _phase_end "build_gate_constraints"
                _gate_check_timeout "$stage_label" "$gate_start" "$gate_timeout"
                return 1
            }

            log "Running dependency constraint validation: ${validation_cmd}"
            local constraint_output=""
            local constraint_exit=0
            # Use bash -c instead of eval to avoid arbitrary code execution
            constraint_output=$(timeout "$effective_timeout" bash -c "$validation_cmd" 2>&1) || constraint_exit=$?

            if [[ "$constraint_exit" -eq 124 ]]; then
                warn "Constraint validation timed out after ${effective_timeout}s (${stage_label}). Treating as pass."
                constraint_exit=0
                constraint_output=""
            fi

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
                _phase_end "build_gate_constraints"
                _phase_end "build_gate"
                return 1
            fi
            _phase_end "build_gate_constraints"
            log "Dependency constraints passed."
        fi
    fi

    # Check overall gate timeout before next phase
    _gate_check_timeout "$stage_label" "$gate_start" "$gate_timeout" || return 1

    # --- Phase 4: UI test validation (Milestone 28) ---
    # Runs UI_TEST_CMD when configured and non-empty. Missing command = warning, not failure.
    # Retries once on failure (E2E tests are inherently flaky).
    if [[ -n "${UI_TEST_CMD:-}" ]] && [[ "${UI_VALIDATION_ENABLED:-true}" == "true" ]]; then
        _phase_start "build_gate_ui_test"
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
                _phase_end "build_gate_ui_test"
                _phase_end "build_gate"
                return 1
            fi
            log "UI tests passed."
        else
            warn "[build gate] UI_TEST_CMD command '${_ui_cmd_bin}' not found. Skipping UI test gate."
            warn "Install the E2E framework or update UI_TEST_CMD in pipeline.conf."
        fi
        _phase_end "build_gate_ui_test"
    fi

    # Check overall gate timeout before next phase
    _gate_check_timeout "$stage_label" "$gate_start" "$gate_timeout" || { _phase_end "build_gate"; return 1; }

    # --- Phase 5: UI validation gate (Milestone 29: headless browser smoke tests) ---
    # Runs AFTER UI_TEST_CMD (M28). Soft-fails when no headless browser available.
    if command -v run_ui_validation &>/dev/null; then
        if ! run_ui_validation "$stage_label"; then
            warn "Build gate FAILED (${stage_label}) — UI validation detected rendering issues."
            # Append UI validation report to BUILD_ERRORS.md so the build-fix
            # agent has full context about rendering failures.
            if [[ -f "UI_VALIDATION_REPORT.md" ]]; then
                {
                    echo ""
                    echo "## UI Validation Failures"
                    echo "The UI validation gate detected rendering issues."
                    echo "Fix these before the build gate can pass."
                    echo ""
                    cat "UI_VALIDATION_REPORT.md"
                } >> BUILD_ERRORS.md
            fi
            _phase_end "build_gate"
            return 1
        fi
    fi

    _phase_end "build_gate"
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
