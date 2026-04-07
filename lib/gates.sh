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

# --- _gate_try_remediation ERRORS PHASE_LABEL --------------------------------
# Attempts auto-remediation on classified errors. Returns 0 if any remediation
# succeeded (caller should re-run the failed phase), 1 otherwise.
_gate_try_remediation() {
    local raw_errors="$1"
    local phase_label="$2"

    # Skip if remediation functions not available
    command -v attempt_remediation &>/dev/null || return 1

    local classifications
    classifications=$(classify_build_errors_all "$raw_errors")
    [[ -z "$classifications" ]] && return 1

    attempt_remediation "$classifications" "$phase_label"
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

    # Guarantee a clean slate — remove stale artifacts from previous runs
    rm -f BUILD_RAW_ERRORS.txt
    rm -f BUILD_ERRORS.md

    # Reset remediation state for this gate invocation (M54)
    if command -v reset_remediation_state &>/dev/null; then
        reset_remediation_state
    fi

    log "Running build gate (${stage_label})..."
    _phase_start "build_gate"

    # --- Phase 1: Static analysis (ANALYZE_CMD) ---
    if ! _gate_phase_analyze "$stage_label" "$gate_start" "$gate_timeout"; then
        _phase_end "build_gate"
        return 1
    fi

    # Check overall gate timeout before next phase
    _gate_check_timeout "$stage_label" "$gate_start" "$gate_timeout" || { _phase_end "build_gate"; return 1; }

    # --- Phase 2: Compile check (BUILD_CHECK_CMD) ---
    if [ -n "${BUILD_CHECK_CMD}" ]; then
        if ! _gate_phase_compile "$stage_label" "$gate_start" "$gate_timeout"; then
            _phase_end "build_gate"
            return 1
        fi
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
    # Delegated to gates_ui.sh: _run_ui_test_phase()
    if ! _run_ui_test_phase "$stage_label"; then
        _phase_end "build_gate"
        return 1
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

# --- Completion gate and summary drift check live in gates_completion.sh ---
