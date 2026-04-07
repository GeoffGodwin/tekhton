#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# gates_ui.sh — UI test validation phase for build gate
#
# Sourced by tekhton.sh after gates.sh — do not run directly.
# Provides: _run_ui_test_phase()
#
# Extracted from gates.sh to keep file sizes under the 300-line ceiling.
# =============================================================================

# _run_ui_test_phase STAGE_LABEL
# Runs UI_TEST_CMD when configured. Retries once on failure (E2E flakiness).
# Attempts registry-based auto-remediation for env_setup errors (M53).
# Returns 0 on pass (or skip), 1 on failure. Writes BUILD_ERRORS.md on failure.
_run_ui_test_phase() {
    local stage_label="$1"

    # Skip when UI tests not configured or disabled
    [[ -n "${UI_TEST_CMD:-}" ]] && [[ "${UI_VALIDATION_ENABLED:-true}" == "true" ]] || return 0

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

    if [[ "$_ui_cmd_available" != "true" ]]; then
        warn "[build gate] UI_TEST_CMD command '${_ui_cmd_bin}' not found. Skipping UI test gate."
        warn "Install the E2E framework or update UI_TEST_CMD in pipeline.conf."
        _phase_end "build_gate_ui_test"
        return 0
    fi

    log "Running UI tests: ${UI_TEST_CMD}"
    local _ui_output="" _ui_exit=0
    local _ui_timeout="${UI_TEST_TIMEOUT:-120}"
    _ui_output=$(timeout "$_ui_timeout" bash -c "$UI_TEST_CMD" 2>&1) || _ui_exit=$?

    # --- Registry-based auto-remediation (M54) ---
    # Use centralized attempt_remediation() for classified errors.
    if [[ "$_ui_exit" -ne 0 ]] && command -v _gate_try_remediation &>/dev/null; then
        if _gate_try_remediation "$_ui_output" "build_gate_ui_test"; then
            log "Re-running UI tests after remediation..."
            _ui_exit=0
            _ui_output=$(timeout "$_ui_timeout" bash -c "$UI_TEST_CMD" 2>&1) || _ui_exit=$?
        fi
    fi

    # Retry once on failure (E2E flakiness mitigation)
    if [[ "$_ui_exit" -ne 0 ]]; then
        log "UI tests failed (exit ${_ui_exit}). Retrying once..."
        _ui_exit=0
        _ui_output=$(timeout "$_ui_timeout" bash -c "$UI_TEST_CMD" 2>&1) || _ui_exit=$?
    fi

    if [[ "$_ui_exit" -eq 0 ]]; then
        log "UI tests passed."
        _phase_end "build_gate_ui_test"
        return 0
    fi

    # --- Failure path ---
    warn "Build gate FAILED (${stage_label}) — UI tests failed:"
    echo "$_ui_output" | tail -30

    # Write raw output so coder.sh bypass logic reads unadorned text
    printf '%s\n' "$_ui_output" > BUILD_RAW_ERRORS.txt

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

    # Append UI test errors to BUILD_ERRORS.md so the build-fix agent
    # has full visibility (it only reads BUILD_ERRORS.md).
    if [[ ! -f BUILD_ERRORS.md ]]; then
        {
            echo "# Build Errors — $(date '+%Y-%m-%d %H:%M:%S')"
            echo "## Stage"
            echo "${stage_label}"
            echo ""
        } > BUILD_ERRORS.md
    fi
    {
        echo "## UI Test Failures"
        echo "Command: \`${UI_TEST_CMD}\`"
        echo "Exit code: ${_ui_exit}"
        echo ""
        echo "\`\`\`"
        echo "$_ui_output" | tail -100
        echo "\`\`\`"
    } >> BUILD_ERRORS.md
    log "UI test errors also appended to BUILD_ERRORS.md"

    _phase_end "build_gate_ui_test"
    return 1
}
