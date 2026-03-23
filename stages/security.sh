#!/usr/bin/env bash
# =============================================================================
# stages/security.sh — Stage 2: Security review (scan → classify → rework)
#
# Sourced by tekhton.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, TIMESTAMP, etc.)
#
# Runs after the build gate (end of Stage 1), before the reviewer (Stage 3).
# Invokes a security agent to scan coder output for vulnerabilities, classifies
# findings by severity, and routes fixable CRITICAL/HIGH items to a rework loop.
# =============================================================================

# --- Fast-path skip detection ------------------------------------------------

# _security_is_docs_only — Check if all changed files are non-code (docs, config,
# assets). Returns 0 if security scan can be skipped, 1 otherwise.
_security_is_docs_only() {
    local summary_file="CODER_SUMMARY.md"

    if [[ ! -f "$summary_file" ]]; then
        return 1  # No summary = can't determine, scan anyway
    fi

    local files
    files=$(extract_files_from_coder_summary "$summary_file")

    if [[ -z "$files" ]]; then
        return 0  # No files changed = nothing to scan
    fi

    local f ext
    local -a file_array=()
    read -ra file_array <<< "$files"

    for f in "${file_array[@]}"; do
        ext="${f##*.}"
        case "$ext" in
            md|txt|rst|csv)          continue ;;  # docs
            json|yaml|yml|toml|cfg)  continue ;;  # config
            png|jpg|jpeg|gif|svg|ico|woff|woff2|ttf|eot) continue ;;  # assets
            *)                       return 1 ;;   # code file found
        esac
    done

    return 0  # All files are docs/config/assets
}

# --- Finding parser ----------------------------------------------------------

# _parse_security_findings — Parse SECURITY_REPORT.md and extract findings.
# Sets arrays: _SEC_SEVERITIES, _SEC_FIXABLES, _SEC_DESCRIPTIONS
# Returns: 0 if findings parsed, 1 if no report or no findings
_parse_security_findings() {
    local report_file="${1:-SECURITY_REPORT.md}"
    _SEC_SEVERITIES=()
    _SEC_FIXABLES=()
    _SEC_DESCRIPTIONS=()

    if [[ ! -f "$report_file" ]]; then
        return 1
    fi

    local in_findings=false
    local line
    while IFS= read -r line; do
        if [[ "$line" == "## Findings"* ]]; then
            in_findings=true
            continue
        fi
        if [[ "$in_findings" == "true" ]] && [[ "$line" == "## "* ]]; then
            break
        fi
        if [[ "$in_findings" == "true" ]] && [[ "$line" == "- "* ]]; then
            # Parse: - [SEVERITY] [fixable:yes|no|unknown] description
            local severity fixable desc
            severity=$(echo "$line" | grep -oE '\[(CRITICAL|HIGH|MEDIUM|LOW)\]' | tr -d '[]' || true)
            fixable=$(echo "$line" | grep -oE 'fixable:(yes|no|unknown)' | cut -d: -f2 || true)
            desc="${line#*] }"

            if [[ -n "$severity" ]]; then
                _SEC_SEVERITIES+=("$severity")
                _SEC_FIXABLES+=("${fixable:-unknown}")
                _SEC_DESCRIPTIONS+=("$desc")
            fi
        fi
    done < "$report_file"

    [[ ${#_SEC_SEVERITIES[@]} -gt 0 ]]
}

# --- Finding classification --------------------------------------------------

# _has_blocking_findings — Check if any findings meet the blocking severity.
# Returns: 0 if blocking findings exist, 1 otherwise
_has_blocking_findings() {
    local block_severity="${SECURITY_BLOCK_SEVERITY:-HIGH}"
    local i severity

    for i in "${!_SEC_SEVERITIES[@]}"; do
        severity="${_SEC_SEVERITIES[$i]}"
        if _severity_meets_threshold "$severity" "$block_severity"; then
            return 0
        fi
    done
    return 1
}

# _severity_meets_threshold — Check if a severity meets or exceeds a threshold.
# Severity order: CRITICAL > HIGH > MEDIUM > LOW
_severity_meets_threshold() {
    local severity="$1" threshold="$2"
    local -A severity_rank=([CRITICAL]=4 [HIGH]=3 [MEDIUM]=2 [LOW]=1)
    local sev_val="${severity_rank[$severity]:-0}"
    local thr_val="${severity_rank[$threshold]:-0}"
    [[ "$sev_val" -ge "$thr_val" ]]
}

# --- Finding routing ---------------------------------------------------------

# _build_fixable_block — Build a block of fixable findings for the rework prompt.
# Output: markdown block of fixable CRITICAL/HIGH findings
_build_fixable_block() {
    local block_severity="${SECURITY_BLOCK_SEVERITY:-HIGH}"
    local result=""
    local i

    for i in "${!_SEC_SEVERITIES[@]}"; do
        if _severity_meets_threshold "${_SEC_SEVERITIES[$i]}" "$block_severity"; then
            if [[ "${_SEC_FIXABLES[$i]}" == "yes" ]]; then
                result+="- [${_SEC_SEVERITIES[$i]}] ${_SEC_DESCRIPTIONS[$i]}"$'\n'
            fi
        fi
    done
    echo "$result"
}

# _build_unfixable_block — Build a block of unfixable blocking findings.
_build_unfixable_block() {
    local block_severity="${SECURITY_BLOCK_SEVERITY:-HIGH}"
    local result=""
    local i

    for i in "${!_SEC_SEVERITIES[@]}"; do
        if _severity_meets_threshold "${_SEC_SEVERITIES[$i]}" "$block_severity"; then
            if [[ "${_SEC_FIXABLES[$i]}" != "yes" ]]; then
                result+="- [${_SEC_SEVERITIES[$i]}] ${_SEC_DESCRIPTIONS[$i]}"$'\n'
            fi
        fi
    done
    echo "$result"
}

# _build_notes_block — Build a block of non-blocking findings for SECURITY_NOTES.md.
_build_notes_block() {
    local block_severity="${SECURITY_BLOCK_SEVERITY:-HIGH}"
    local result=""
    local i

    for i in "${!_SEC_SEVERITIES[@]}"; do
        if ! _severity_meets_threshold "${_SEC_SEVERITIES[$i]}" "$block_severity"; then
            result+="- [${_SEC_SEVERITIES[$i]}] ${_SEC_DESCRIPTIONS[$i]}"$'\n'
        fi
    done
    echo "$result"
}

# --- Unfixable policy handling -----------------------------------------------

# _handle_unfixable_findings — Apply SECURITY_UNFIXABLE_POLICY to unfixable findings.
# Returns: 0 to continue, 1 to halt pipeline
_handle_unfixable_findings() {
    local unfixable_block="$1"
    local policy="${SECURITY_UNFIXABLE_POLICY:-escalate}"

    if [[ -z "$unfixable_block" ]]; then
        return 0
    fi

    case "$policy" in
        escalate)
            log "[security] Escalating unfixable findings to HUMAN_ACTION_REQUIRED.md"
            if command -v append_human_action &>/dev/null; then
                append_human_action "security" "Unfixable security findings require human review:
${unfixable_block}"
            fi
            return 0
            ;;
        halt)
            error "[security] Pipeline halted — unfixable CRITICAL/HIGH security findings detected."
            error "[security] Review SECURITY_REPORT.md and resolve manually."
            write_pipeline_state "security" "security_halt" \
                "${MILESTONE_MODE:+--milestone }--start-at security" \
                "$TASK" \
                "Unfixable security findings with halt policy. Review SECURITY_REPORT.md."
            return 1
            ;;
        waiver)
            log "[security] Waiver policy: logging unfixable findings and continuing."
            return 0
            ;;
        *)
            warn "[security] Unknown SECURITY_UNFIXABLE_POLICY: ${policy}. Defaulting to escalate."
            if command -v append_human_action &>/dev/null; then
                append_human_action "security" "Unfixable security findings:
${unfixable_block}"
            fi
            return 0
            ;;
    esac
}

# --- Write SECURITY_NOTES.md ------------------------------------------------

_write_security_notes() {
    local notes_block="$1"
    local unfixable_block="$2"
    local notes_file="${SECURITY_NOTES_FILE:-SECURITY_NOTES.md}"

    {
        echo "# Security Notes"
        echo ""
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        if [[ -n "$notes_block" ]]; then
            echo "## Non-Blocking Findings (MEDIUM/LOW)"
            echo "$notes_block"
        fi
        if [[ -n "$unfixable_block" ]] && [[ "${SECURITY_UNFIXABLE_POLICY:-escalate}" == "waiver" ]]; then
            echo "## Waivered Findings"
            echo "$unfixable_block"
        fi
    } > "$notes_file"
}

# --- Main stage function -----------------------------------------------------

run_stage_security() {
    header "Stage 2 / 4 — Security"

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

        run_agent \
            "Security (scan)" \
            "${CLAUDE_SECURITY_MODEL:-${CLAUDE_STANDARD_MODEL}}" \
            "$security_turns" \
            "$SECURITY_SCAN_PROMPT" \
            "$LOG_FILE" \
            "${AGENT_TOOLS_REVIEWER:-}"
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

            run_agent \
                "Security Rework (cycle ${security_rework_cycle})" \
                "${CLAUDE_CODER_MODEL}" \
                "${CODER_MAX_TURNS}" \
                "$rework_prompt" \
                "$LOG_FILE" \
                "${AGENT_TOOLS_CODER:-}"
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
