#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# stages/security.sh — Stage 2: Security review (scan → classify → rework)
#
# Sourced by tekhton.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, TIMESTAMP, etc.)
# Depends on: lib/security_helpers.sh (all _security_* and _*_block helpers)
#
# Runs after the build gate (end of Stage 1), before the reviewer (Stage 3).
# Invokes a security agent to scan coder output for vulnerabilities, classifies
# findings by severity, and routes fixable CRITICAL/HIGH items to a rework loop.
# =============================================================================

# --- Main stage function -----------------------------------------------------

run_stage_security() {
    local _stage_count="${PIPELINE_STAGE_COUNT:-4}"
    local _stage_pos="${PIPELINE_STAGE_POS:-2}"
    header "Stage ${_stage_pos} / ${_stage_count} — Security"

    # Skip if disabled
    if [[ "${SECURITY_AGENT_ENABLED:-true}" != "true" ]]; then
        log "[security] Security stage disabled (SECURITY_AGENT_ENABLED=false). Skipping."
        return 0
    fi

    # Skip if --skip-security flag was set
    if [[ "${SKIP_SECURITY:-false}" == "true" ]]; then
        log "[security] Security stage skipped (--skip-security). Skipping."
        return 0
    fi

    # Fast-path skip: docs/config/asset-only changes
    if _security_is_docs_only; then
        log "[security] All changed files are docs/config/assets. Skipping security scan."
        return 0
    fi

    local security_rework_cycle=0
    local max_rework="${SECURITY_MAX_REWORK_CYCLES:-2}"
    local scan_needed=true

    while [[ "$scan_needed" == "true" ]]; do
        scan_needed=false

        # --- Invoke security agent ---
        local security_turns="${SECURITY_MAX_TURNS:-15}"
        if [[ "${MILESTONE_MODE:-}" == "true" ]]; then
            security_turns="${MILESTONE_SECURITY_MAX_TURNS:-$(( security_turns * 2 ))}"
        fi

        # Clamp to min/max
        if [[ "$security_turns" -lt "${SECURITY_MIN_TURNS:-8}" ]]; then
            security_turns="${SECURITY_MIN_TURNS:-8}"
        fi
        if [[ "$security_turns" -gt "${SECURITY_MAX_TURNS_CAP:-30}" ]]; then
            security_turns="${SECURITY_MAX_TURNS_CAP:-30}"
        fi

        export SECURITY_REPORT_CONTENT=""
        if [[ -f "${SECURITY_REPORT_FILE:-SECURITY_REPORT.md}" ]]; then
            SECURITY_REPORT_CONTENT=$(cat "${SECURITY_REPORT_FILE:-SECURITY_REPORT.md}")
        fi

        SECURITY_SCAN_PROMPT=$(render_prompt "security_scan")

        local _sec_scan_start="$SECONDS"
        run_agent \
            "Security (scan)" \
            "${CLAUDE_SECURITY_MODEL:-${CLAUDE_STANDARD_MODEL}}" \
            "$security_turns" \
            "$SECURITY_SCAN_PROMPT" \
            "$LOG_FILE" \
            "${AGENT_TOOLS_REVIEWER:-}"
        # Record security scan sub-step (M66)
        if declare -p _STAGE_DURATION &>/dev/null; then
            _STAGE_DURATION["security_scan"]="$(( SECONDS - _sec_scan_start ))"
            _STAGE_TURNS["security_scan"]="${LAST_AGENT_TURNS:-0}"
        fi
        print_run_summary
        success "Security scan finished."

        # Parse findings
        local report_file="${SECURITY_REPORT_FILE:-SECURITY_REPORT.md}"
        if ! _parse_security_findings "$report_file"; then
            log "[security] No structured findings in SECURITY_REPORT.md. Proceeding."
            return 0
        fi

        log "[security] Found ${#_SEC_SEVERITIES[@]} finding(s)."

        # Build classification blocks
        local fixable_block unfixable_block notes_block
        fixable_block=$(_build_fixable_block)
        unfixable_block=$(_build_unfixable_block)
        notes_block=$(_build_notes_block)

        # Write non-blocking notes
        _write_security_notes "$notes_block" "$unfixable_block"

        # Handle unfixable findings per policy
        if [[ -n "$unfixable_block" ]]; then
            if ! _handle_unfixable_findings "$unfixable_block"; then
                return 1  # halt policy
            fi
        fi

        # Route fixable findings to rework
        if [[ -n "$fixable_block" ]] && [[ "$security_rework_cycle" -lt "$max_rework" ]]; then
            security_rework_cycle=$((security_rework_cycle + 1))
            log "[security] Rework cycle ${security_rework_cycle} / ${max_rework} — fixing ${fixable_block%%$'\n'*}..."

            # Set the fixable block for the rework prompt
            export SECURITY_FIXABLE_BLOCK="$fixable_block"

            local rework_prompt
            rework_prompt=$(render_prompt "security_rework")

            local _sec_rework_start="$SECONDS"
            run_agent \
                "Security Rework (cycle ${security_rework_cycle})" \
                "${CLAUDE_CODER_MODEL}" \
                "${CODER_MAX_TURNS}" \
                "$rework_prompt" \
                "$LOG_FILE" \
                "${AGENT_TOOLS_CODER:-}"
            # Record security rework sub-step (M66)
            if declare -p _STAGE_DURATION &>/dev/null; then
                _STAGE_DURATION["security_rework_${security_rework_cycle}"]="$(( SECONDS - _sec_rework_start ))"
                _STAGE_TURNS["security_rework_${security_rework_cycle}"]="${LAST_AGENT_TURNS:-0}"
            fi
            print_run_summary

            # Post-rework build gate
            if ! run_build_gate "security-rework"; then
                warn "[security] Build gate failed after security rework. Proceeding to reviewer."
                break
            fi

            # Re-scan after rework
            scan_needed=true
        fi
    done

    # Build summary blocks for downstream stages
    export SECURITY_FINDINGS_BLOCK=""
    export SECURITY_FIXES_BLOCK=""

    if [[ ${#_SEC_SEVERITIES[@]} -gt 0 ]]; then
        local i
        for i in "${!_SEC_SEVERITIES[@]}"; do
            SECURITY_FINDINGS_BLOCK+="- [${_SEC_SEVERITIES[$i]}] ${_SEC_DESCRIPTIONS[$i]}"$'\n'
        done
    fi

    if [[ "$security_rework_cycle" -gt 0 ]]; then
        SECURITY_FIXES_BLOCK="Security rework applied ${security_rework_cycle} cycle(s). "
        SECURITY_FIXES_BLOCK+="Review SECURITY_REPORT.md for details of findings and fixes."
    fi

    export SECURITY_REWORK_CYCLES_DONE="$security_rework_cycle"
    log "[security] Security stage complete. Rework cycles: ${security_rework_cycle}."
    return 0
}
