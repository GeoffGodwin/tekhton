#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_audit.sh — Test integrity audit orchestration
#
# Sourced by tekhton.sh — do not run directly.
# Expects: prompts.sh, agent.sh, common.sh sourced first.
# Expects: test_audit_helpers.sh, test_audit_detection.sh,
#          test_audit_verdict.sh sourced before this file.
# Expects: TASK, LOG_FILE, PROJECT_DIR, TEST_AUDIT_* config vars set.
#
# Companion modules:
#   lib/test_audit_helpers.sh   — Pre-audit collection + context assembly
#   lib/test_audit_detection.sh — Orphan and weakening detection
#   lib/test_audit_verdict.sh   — Verdict parsing and routing
#   lib/test_audit_symbols.sh   — Symbol-level stale reference detection (M88)
#   lib/test_audit_sampler.sh   — Rolling freshness sampler (M89)
#
# Provides:
#   run_test_audit            — Main entry: collect context, run audit, route verdict
#   run_standalone_test_audit — Full audit of ALL test files (--audit-tests)
# =============================================================================

# --- Main audit function (pipeline integration) ------------------------------

# run_test_audit
# Called after tester completes within the test stage.
# 1. Collects audit context (test files, impl files, deleted files)
# 2. Runs shell-based orphan and weakening detection
# 3. Invokes reviewer agent with test_audit prompt
# 4. Parses verdict and routes accordingly
# Returns: 0 on PASS/CONCERNS, 1 on NEEDS_WORK (triggers rework)
run_test_audit() {
    if [[ "${TEST_AUDIT_ENABLED:-true}" != "true" ]]; then
        log "Test audit disabled (TEST_AUDIT_ENABLED=false). Skipping."
        return 0
    fi

    header "Test Integrity Audit"

    # Step 1: Collect context
    _collect_audit_context

    # Rolling freshness sample (M89): K oldest-audited tests get re-evaluated.
    # Sampler is in lib/test_audit_sampler.sh (optional companion module).
    if [[ "${TEST_AUDIT_ROLLING_ENABLED:-true}" == "true" ]] \
        && command -v _sample_unaudited_test_files &>/dev/null; then
        _sample_unaudited_test_files
    fi

    # Skip audit only when neither modified nor sampled files are available
    if [[ -z "$_AUDIT_TEST_FILES" ]] && [[ -z "${_AUDIT_SAMPLE_FILES:-}" ]]; then
        log "No test files written this run and no sample available — skipping audit."
        return 0
    fi

    local _modified_count _sample_count
    _modified_count=$(echo "${_AUDIT_TEST_FILES:-}" | grep -c '.' || echo 0)
    _sample_count=$(echo "${_AUDIT_SAMPLE_FILES:-}" | grep -c '.' || echo 0)
    log "Auditing ${_modified_count} modified + ${_sample_count} sampled test file(s)..."

    # Step 2: Shell-based detection (instant, no agent needed)
    if [[ "${TEST_AUDIT_ORPHAN_DETECTION:-true}" == "true" ]]; then
        _detect_orphaned_tests
    fi
    if command -v _detect_stale_symbol_refs &>/dev/null; then
        _detect_stale_symbol_refs
    fi
    if [[ "${TEST_AUDIT_WEAKENING_DETECTION:-true}" == "true" ]]; then
        _detect_test_weakening
    fi

    # Log shell findings
    if [[ -n "${_AUDIT_ORPHAN_FINDINGS:-}" ]]; then
        log "Orphan detection found issues:"
        echo "$_AUDIT_ORPHAN_FINDINGS" | while IFS= read -r line; do
            [[ -n "$line" ]] && warn "  $line"
        done
    fi
    if [[ -n "${_AUDIT_WEAKENING_FINDINGS:-}" ]]; then
        log "Weakening detection found issues:"
        echo "$_AUDIT_WEAKENING_FINDINGS" | while IFS= read -r line; do
            [[ -n "$line" ]] && warn "  $line"
        done
    fi

    # Step 3: Build audit context for the agent prompt
    _build_test_audit_context

    # Step 4: Invoke audit agent
    local audit_prompt
    audit_prompt=$(render_prompt "test_audit")

    log "Invoking test audit agent (max ${TEST_AUDIT_MAX_TURNS:-8} turns)..."
    run_agent \
        "Test Audit" \
        "${CLAUDE_REVIEWER_MODEL}" \
        "${TEST_AUDIT_MAX_TURNS:-8}" \
        "$audit_prompt" \
        "$LOG_FILE" \
        "${AGENT_TOOLS_REVIEWER:-Read Glob Grep}"

    # Step 5: Parse verdict and route
    local verdict
    verdict=$(_parse_audit_verdict)
    log "Test audit verdict: ${verdict}"

    # Emit causal event
    if command -v emit_event &>/dev/null; then
        emit_event "test_audit" "tester" "verdict=${verdict}" "" "" \
            "{\"verdict\":\"${verdict}\",\"orphans\":\"${_AUDIT_ORPHAN_FINDINGS:+found}\",\"weakening\":\"${_AUDIT_WEAKENING_FINDINGS:+found}\"}" \
            >/dev/null 2>&1 || true
    fi

    if [[ "$verdict" != "NEEDS_WORK" ]]; then
        # PASS or CONCERNS — record audit history for files we evaluated.
        # NEEDS_WORK records only after a successful rework cycle (below).
        if command -v _record_audit_history &>/dev/null; then
            _record_audit_history "${_AUDIT_TEST_FILES:-}
${_AUDIT_SAMPLE_FILES:-}"
        fi
    fi

    if ! _route_audit_verdict "$verdict"; then
        # NEEDS_WORK — attempt rework
        local rework_cycles=0
        local max_rework="${TEST_AUDIT_MAX_REWORK_CYCLES:-1}"

        while [[ "$rework_cycles" -lt "$max_rework" ]]; do
            rework_cycles=$((rework_cycles + 1))
            log "Test audit rework cycle ${rework_cycles}/${max_rework}..."

            export TEST_AUDIT_FINDINGS=""
            if [[ -f "${TEST_AUDIT_REPORT_FILE:-}" ]]; then
                TEST_AUDIT_FINDINGS=$(_safe_read_file "${TEST_AUDIT_REPORT_FILE:-}" "TEST_AUDIT_REPORT")
            fi

            local rework_prompt
            rework_prompt=$(render_prompt "test_audit_rework")

            run_agent \
                "Tester (audit rework ${rework_cycles})" \
                "${CLAUDE_TESTER_MODEL}" \
                "${ADJUSTED_TESTER_TURNS:-$TESTER_MAX_TURNS}" \
                "$rework_prompt" \
                "$LOG_FILE" \
                "${AGENT_TOOLS_TESTER:-Read Glob Grep Write Edit Bash}"

            # Re-run audit after rework
            _collect_audit_context
            if [[ "${TEST_AUDIT_ORPHAN_DETECTION:-true}" == "true" ]]; then
                _detect_orphaned_tests
            fi
            if command -v _detect_stale_symbol_refs &>/dev/null; then
                _detect_stale_symbol_refs
            fi
            if [[ "${TEST_AUDIT_WEAKENING_DETECTION:-true}" == "true" ]]; then
                _detect_test_weakening
            fi

            # Rebuild context (sample is preserved across rework — same files)
            _build_test_audit_context

            audit_prompt=$(render_prompt "test_audit")
            run_agent \
                "Test Audit (re-check ${rework_cycles})" \
                "${CLAUDE_REVIEWER_MODEL}" \
                "${TEST_AUDIT_MAX_TURNS:-8}" \
                "$audit_prompt" \
                "$LOG_FILE" \
                "${AGENT_TOOLS_REVIEWER:-Read Glob Grep}"

            verdict=$(_parse_audit_verdict)
            log "Test audit re-check verdict: ${verdict}"

            if [[ "$verdict" != "NEEDS_WORK" ]]; then
                if command -v _record_audit_history &>/dev/null; then
                    _record_audit_history "${_AUDIT_TEST_FILES:-}
${_AUDIT_SAMPLE_FILES:-}"
                fi
                _route_audit_verdict "$verdict"
                return 0
            fi
        done

        # Exhausted rework cycles
        warn "Test audit NEEDS_WORK after ${max_rework} rework cycle(s). Escalating to human."
        warn "Review ${TEST_AUDIT_REPORT_FILE} and fix tests manually."
        return 0  # Don't block pipeline — log and proceed
    fi

    return 0
}

# --- Standalone audit (--audit-tests) ----------------------------------------

# run_standalone_test_audit
# Scans ALL test files in the project (not just current diff).
# Used as a one-time bootstrap command for projects adopting M20.
run_standalone_test_audit() {
    header "Tekhton — Standalone Test Audit"

    local all_test_files
    all_test_files=$(_discover_all_test_files)

    if [[ -z "$all_test_files" ]]; then
        log "No test files found in project."
        return 0
    fi

    local file_count
    file_count=$(echo "$all_test_files" | grep -c '.' || echo "0")
    log "Discovered ${file_count} test file(s) for audit."

    # Set globals for audit context
    _AUDIT_TEST_FILES="$all_test_files"
    _AUDIT_IMPL_FILES=""
    _AUDIT_DELETED_FILES=""
    _AUDIT_ORPHAN_FINDINGS=""
    _AUDIT_WEAKENING_FINDINGS=""

    # Build context for full-suite audit
    local _standalone_ctx
    # shellcheck disable=SC2001  # sed needed for multiline prefix
    _standalone_ctx="## Test Files Under Audit (full suite)
$(echo "$all_test_files" | sed 's/^/- /')

## Mode: Standalone full-suite audit (--audit-tests)
All test files are included regardless of current diff.
"
    export TEST_AUDIT_CONTEXT="$_standalone_ctx"
    export CODER_DELETED_FILES=""

    # Invoke audit agent
    local audit_prompt
    audit_prompt=$(render_prompt "test_audit")

    log "Invoking test audit agent (max ${TEST_AUDIT_MAX_TURNS:-8} turns)..."
    run_agent \
        "Test Audit (standalone)" \
        "${CLAUDE_REVIEWER_MODEL}" \
        "${TEST_AUDIT_MAX_TURNS:-8}" \
        "$audit_prompt" \
        "${LOG_DIR:-/tmp}/$(date +%Y%m%d_%H%M%S)_test-audit.log" \
        "${AGENT_TOOLS_REVIEWER:-Read Glob Grep}"

    # Parse and display verdict
    local verdict
    verdict=$(_parse_audit_verdict)

    echo
    echo "════════════════════════════════════════"
    echo "  Test Audit Results"
    echo "════════════════════════════════════════"
    echo "  Files audited: ${file_count}"
    echo "  Verdict:       ${verdict}"
    if [[ -f "${TEST_AUDIT_REPORT_FILE:-}" ]]; then
        echo "  Report:        ${TEST_AUDIT_REPORT_FILE:-}"
        echo
        # Show findings summary
        local high_count
        high_count=$(grep -c 'Severity: HIGH' "${TEST_AUDIT_REPORT_FILE:-}" 2>/dev/null || echo "0")
        local medium_count
        medium_count=$(grep -c 'Severity: MEDIUM' "${TEST_AUDIT_REPORT_FILE:-}" 2>/dev/null || echo "0")
        echo "  HIGH findings:   ${high_count}"
        echo "  MEDIUM findings: ${medium_count}"
    fi
    echo "════════════════════════════════════════"
}
