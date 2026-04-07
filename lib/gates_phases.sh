#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# gates_phases.sh — Extracted build gate phase functions with remediation loops
#
# Sourced by tekhton.sh after gates.sh — do not run directly.
# Provides: _gate_phase_analyze(), _gate_phase_compile()
#
# Milestone 54: Auto-Remediation Engine — phases extracted from gates.sh
# so each can be re-run independently after successful remediation.
# =============================================================================

# --- _gate_write_analyze_errors -----------------------------------------------
# Writes analyze errors to BUILD_ERRORS.md and BUILD_RAW_ERRORS.txt.
_gate_write_analyze_errors() {
    local analyze_errors="$1"
    local analyze_output="$2"
    local stage_label="$3"

    printf '%s\n' "$analyze_errors" > BUILD_RAW_ERRORS.txt

    {
        if command -v annotate_build_errors &>/dev/null; then
            annotate_build_errors "$analyze_errors" "$stage_label"
        else
            echo "# Build Errors — $(date '+%Y-%m-%d %H:%M:%S')"
            echo "## Stage"
            echo "${stage_label}"
        fi
        echo ""
        echo "## Analyze Errors"
        echo '```'
        echo "${analyze_errors}"
        echo '```'
        echo ""
        echo "## Full Analyze Output"
        echo '```'
        echo "${analyze_output}"
        echo '```'
    } > BUILD_ERRORS.md
    log "Build errors written to BUILD_ERRORS.md"
}

# --- _gate_run_analyze --------------------------------------------------------
# Runs ANALYZE_CMD and checks for errors. Sets ANALYZE_OUTPUT/ANALYZE_ERRORS.
# Returns 0 if clean, 1 if errors found.
_gate_run_analyze() {
    local effective_timeout="$1"

    local analyze_exit=0
    ANALYZE_OUTPUT=$(timeout "$effective_timeout" bash -c "${ANALYZE_CMD}" 2>&1) || analyze_exit=$?

    if [[ "$analyze_exit" -eq 124 ]]; then
        warn "ANALYZE_CMD timed out after ${effective_timeout}s. Treating as pass."
        warn "Increase BUILD_GATE_ANALYZE_TIMEOUT if this is expected."
        ANALYZE_OUTPUT=""
    fi

    ANALYZE_ERRORS=$(echo "$ANALYZE_OUTPUT" | grep -E "${ANALYZE_ERROR_PATTERN}" || true)

    if [[ -n "$ANALYZE_ERRORS" ]]; then
        return 1
    fi
    return 0
}

# --- _gate_phase_analyze STAGE_LABEL GATE_START GATE_TIMEOUT ------------------
# Phase 1: Static analysis. Attempts remediation on failure before giving up.
_gate_phase_analyze() {
    local stage_label="$1"
    local gate_start="$2"
    local gate_timeout="$3"

    _phase_start "build_gate_analyze"
    local analyze_timeout="${BUILD_GATE_ANALYZE_TIMEOUT:-300}"
    local effective_timeout
    effective_timeout=$(_gate_effective_timeout "$analyze_timeout" "$gate_start" "$gate_timeout") || {
        _gate_check_timeout "$stage_label" "$gate_start" "$gate_timeout"
        return 1
    }

    if _gate_run_analyze "$effective_timeout"; then
        _phase_end "build_gate_analyze"
        return 0
    fi

    warn "Build gate FAILED (${stage_label}) — analyze errors found:"
    echo "$ANALYZE_ERRORS"

    # --- M54: Attempt auto-remediation before giving up ---
    if _gate_try_remediation "$ANALYZE_ERRORS" "build_gate_analyze"; then
        log "Re-running analyze phase after remediation..."
        effective_timeout=$(_gate_effective_timeout "$analyze_timeout" "$gate_start" "$gate_timeout") || {
            _gate_check_timeout "$stage_label" "$gate_start" "$gate_timeout"
            return 1
        }
        if _gate_run_analyze "$effective_timeout"; then
            log "Analyze phase passed after remediation."
            _phase_end "build_gate_analyze"
            return 0
        fi
        warn "Analyze phase still failing after remediation."
    fi

    _gate_write_analyze_errors "$ANALYZE_ERRORS" "$ANALYZE_OUTPUT" "$stage_label"
    _phase_end "build_gate_analyze"
    return 1
}

# --- _gate_write_compile_errors -----------------------------------------------
# Writes compile errors to BUILD_ERRORS.md.
_gate_write_compile_errors() {
    local compile_errors="$1"
    local stage_label="$2"

    printf '%s\n' "$compile_errors" >> BUILD_RAW_ERRORS.txt

    if [[ ! -f BUILD_ERRORS.md ]]; then
        {
            echo "# Build Errors — $(date '+%Y-%m-%d %H:%M:%S')"
            echo "## Stage"
            echo "${stage_label}"
            echo ""
        } >> BUILD_ERRORS.md
    fi
    {
        if command -v classify_build_errors_all &>/dev/null; then
            echo ""
            echo "## Error Classification (compile)"
            classify_build_errors_all "$compile_errors" | while IFS='|' read -r _cat _saf _rem _diag; do
                [[ -z "$_cat" ]] && continue
                echo "- **${_cat}** (${_saf}): ${_diag}"
            done
        fi
        echo ""
        echo "## Compile Errors"
        echo '```'
        echo "${compile_errors}"
        echo '```'
    } >> BUILD_ERRORS.md
}

# --- _gate_run_compile --------------------------------------------------------
# Runs BUILD_CHECK_CMD and checks for errors. Sets COMPILE_OUTPUT/COMPILE_ERRORS.
# Returns 0 if clean, 1 if errors found.
_gate_run_compile() {
    local effective_timeout="$1"

    local compile_exit=0
    COMPILE_OUTPUT=$(timeout "$effective_timeout" bash -c "${BUILD_CHECK_CMD}" 2>&1) || compile_exit=$?

    if [[ "$compile_exit" -eq 124 ]]; then
        warn "BUILD_CHECK_CMD timed out after ${effective_timeout}s. Treating as pass."
        COMPILE_OUTPUT=""
    fi

    if echo "$COMPILE_OUTPUT" | grep -q "${BUILD_ERROR_PATTERN}"; then
        COMPILE_ERRORS=$(echo "$COMPILE_OUTPUT" | grep "${BUILD_ERROR_PATTERN}" | head -20)
        return 1
    fi
    return 0
}

# --- _gate_phase_compile STAGE_LABEL GATE_START GATE_TIMEOUT ------------------
# Phase 2: Compile check. Attempts remediation on failure before giving up.
_gate_phase_compile() {
    local stage_label="$1"
    local gate_start="$2"
    local gate_timeout="$3"

    _phase_start "build_gate_compile"
    local compile_timeout="${BUILD_GATE_COMPILE_TIMEOUT:-120}"
    local effective_timeout
    effective_timeout=$(_gate_effective_timeout "$compile_timeout" "$gate_start" "$gate_timeout") || {
        _gate_check_timeout "$stage_label" "$gate_start" "$gate_timeout"
        return 1
    }

    if _gate_run_compile "$effective_timeout"; then
        _phase_end "build_gate_compile"
        return 0
    fi

    warn "Build gate FAILED (${stage_label}) — compile errors found:"
    echo "$COMPILE_ERRORS"

    # --- M54: Attempt auto-remediation before giving up ---
    if _gate_try_remediation "$COMPILE_ERRORS" "build_gate_compile"; then
        log "Re-running compile phase after remediation..."
        effective_timeout=$(_gate_effective_timeout "$compile_timeout" "$gate_start" "$gate_timeout") || {
            _gate_check_timeout "$stage_label" "$gate_start" "$gate_timeout"
            return 1
        }
        if _gate_run_compile "$effective_timeout"; then
            log "Compile phase passed after remediation."
            _phase_end "build_gate_compile"
            return 0
        fi
        warn "Compile phase still failing after remediation."
    fi

    _gate_write_compile_errors "$COMPILE_ERRORS" "$stage_label"
    _phase_end "build_gate_compile"
    return 1
}
