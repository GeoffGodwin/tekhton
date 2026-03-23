#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# security_helpers.sh — Security stage helper functions
#
# Extracted from stages/security.sh to stay under the 300-line ceiling.
# Sourced by tekhton.sh — do not run directly.
# Depends on: common.sh (log, warn, error, success)
#             agent_helpers.sh (extract_files_from_coder_summary)
#             state.sh (write_pipeline_state)
#             drift.sh (append_human_action)
# Provides: _security_is_docs_only(), _parse_security_findings(),
#           _has_blocking_findings(), _severity_meets_threshold(),
#           _build_fixable_block(), _build_unfixable_block(),
#           _build_notes_block(), _handle_unfixable_findings(),
#           _write_security_notes()
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
