#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# gates_ui.sh — UI test validation phase for build gate
#
# Sourced by tekhton.sh after gates.sh — do not run directly.
# Provides: _run_ui_test_phase()
#
# M126 hooks: every subprocess invocation runs through `env "${_env_list[@]}"`
# with a deterministic env profile. On `interactive_report` timeout signature,
# M54 remediation and the generic flakiness retry are skipped in favor of a
# single hardened rerun. Helpers live in lib/gates_ui_helpers.sh.
# =============================================================================

# _ui_run_cmd HARDENED? TIMEOUT OP_LABEL
# Runs UI_TEST_CMD under `env <KEY=VAL>... timeout <T> bash -c "$UI_TEST_CMD"`.
# Sets _ui_output and _ui_exit (caller-scoped). Apply env at the env(1)
# boundary so it never leaks into the parent shell.
_ui_run_cmd() {
    local hardened="$1"
    local _t="$2"
    local op_label="$3"

    local _env_list=()
    mapfile -t _env_list < <(_normalize_ui_gate_env "$hardened")

    _ui_output=""
    _ui_exit=0
    _ui_output=$(run_op "$op_label" \
        env "${_env_list[@]}" timeout "$_t" \
        bash -c "$UI_TEST_CMD" 2>&1) || _ui_exit=$?
}

# _run_ui_test_phase STAGE_LABEL
# Runs UI_TEST_CMD when configured. Retries once on failure (E2E flakiness).
# Attempts registry-based auto-remediation for env_setup errors (M53/M54).
# On interactive_report timeout, skips remediation/generic retry and runs
# a single hardened rerun (M126).
# Returns 0 on pass (or skip), 1 on failure. Writes "${BUILD_ERRORS_FILE}"
# on failure.
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

    # --- Run #1: normal-run deterministic env ---
    _ui_run_cmd 0 "$_ui_timeout" "Running UI tests"

    if [[ "$_ui_exit" -eq 0 ]]; then
        log "UI tests passed."
        _phase_end "build_gate_ui_test"
        return 0
    fi

    # --- M126: classify timeout signature ---
    local _ui_signature
    _ui_signature=$(_ui_timeout_signature "$_ui_exit" "$_ui_output")

    local _hardened_attempted="no"
    if [[ "$_ui_signature" == "interactive_report" ]]; then
        # Skip M54 remediation and generic retry: same hang would recur.
        log "UI tests timed out with interactive-report signature; skipping remediation and generic retry."

        if [[ "${UI_GATE_ENV_RETRY_ENABLED:-true}" == "true" ]]; then
            local _hardened_t
            _hardened_t=$(_ui_hardened_timeout "$_ui_timeout" "${UI_GATE_ENV_RETRY_TIMEOUT_FACTOR:-0.5}")
            log "Re-running UI tests with hardened deterministic env (timeout ${_hardened_t}s)..."
            _hardened_attempted="yes"
            _ui_run_cmd 1 "$_hardened_t" "Hardened UI test rerun"

            if [[ "$_ui_exit" -eq 0 ]]; then
                log "UI tests passed after deterministic reporter hardening."
                _phase_end "build_gate_ui_test"
                return 0
            fi
        else
            log "UI_GATE_ENV_RETRY_ENABLED=false; skipping hardened rerun."
        fi
    else
        # --- Existing M54 registry-based auto-remediation ---
        if command -v _gate_try_remediation &>/dev/null \
           && _gate_try_remediation "$_ui_output" "build_gate_ui_test"; then
            log "Re-running UI tests after remediation..."
            _ui_run_cmd 0 "$_ui_timeout" "Re-running UI tests"
        fi

        # Existing generic flakiness retry
        if [[ "$_ui_exit" -ne 0 ]]; then
            log "UI tests failed (exit ${_ui_exit}). Retrying once..."
            _ui_run_cmd 0 "$_ui_timeout" "Retrying UI tests"
        fi
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
    printf '%s\n' "$_ui_output" > "${BUILD_RAW_ERRORS_FILE}"

    cat > "${UI_TEST_ERRORS_FILE}" << UIEOF
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
    log "UI test errors written to ${UI_TEST_ERRORS_FILE}"

    # Append UI test errors to "${BUILD_ERRORS_FILE}" so the build-fix agent
    # has full visibility (it only reads "${BUILD_ERRORS_FILE}").
    if [[ ! -f "${BUILD_ERRORS_FILE}" ]]; then
        {
            echo "# Build Errors — $(date '+%Y-%m-%d %H:%M:%S')"
            echo "## Stage"
            echo "${stage_label}"
            echo ""
        } > "${BUILD_ERRORS_FILE}"
    fi
    {
        echo "## UI Test Failures"
        echo "Command: \`${UI_TEST_CMD}\`"
        echo "Exit code: ${_ui_exit}"
        echo ""
        echo "\`\`\`"
        echo "$_ui_output" | tail -100
        echo "\`\`\`"
    } >> "${BUILD_ERRORS_FILE}"
    log "UI test errors also appended to ${BUILD_ERRORS_FILE}"

    # M126: structured gate diagnosis (after raw output blocks).
    local _normal_applied="no" _hardened_applied="no"
    if [[ "$(_ui_detect_framework)" == "playwright" ]]; then
        _normal_applied="yes"
        if [[ "$_hardened_attempted" == "yes" ]]; then
            _hardened_applied="yes"
        fi
    fi
    _ui_write_gate_diagnosis "$_ui_signature" "$_normal_applied" \
        "$_hardened_applied" "$_hardened_attempted"

    _phase_end "build_gate_ui_test"
    return 1
}
