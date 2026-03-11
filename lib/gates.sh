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
    ANALYZE_OUTPUT=$(${ANALYZE_CMD} 2>&1)
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
        COMPILE_OUTPUT=$(eval "${BUILD_CHECK_CMD}")
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
            constraint_output=$(eval "$validation_cmd" 2>&1) || constraint_exit=$?

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

    log "Build gate PASSED (${stage_label})"
    [ -f BUILD_ERRORS.md ] && rm BUILD_ERRORS.md
    return 0
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
        return 0
    fi

    # Status is missing or ambiguous — treat as incomplete
    warn "Completion gate FAILED — CODER_SUMMARY.md has no clear Status field."
    warn "Expected '## Status' line with COMPLETE or IN PROGRESS."
    return 1
}
