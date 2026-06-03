#!/usr/bin/env bash
# security_helpers.sh — m35.1 shim. Logic in internal/security/ (Go).
# m35.2 ports stages/security.sh and deletes this file.
_security_is_docs_only() {
    "${TEKHTON_BIN:-tekhton}" security is-docs-only \
        --summary "${CODER_SUMMARY_FILE:-.tekhton/CODER_SUMMARY.md}"
}
_parse_security_findings() {
    local report_file="${1:-${SECURITY_REPORT_FILE:-.tekhton/SECURITY_REPORT.md}}" sev fix desc
    _SEC_SEVERITIES=(); _SEC_FIXABLES=(); _SEC_DESCRIPTIONS=()
    while IFS=$'\t' read -r sev fix desc; do
        [[ -z "$sev" ]] && continue
        _SEC_SEVERITIES+=("$sev"); _SEC_FIXABLES+=("$fix"); _SEC_DESCRIPTIONS+=("$desc")
    done < <("${TEKHTON_BIN:-tekhton}" security parse-findings --report "$report_file" --format tsv 2>/dev/null)
    [[ ${#_SEC_SEVERITIES[@]} -gt 0 ]]
}
_severity_meets_threshold() {
    "${TEKHTON_BIN:-tekhton}" security meets-threshold --severity "$1" --threshold "$2"
}
_has_blocking_findings() {
    local block_severity="${SECURITY_BLOCK_SEVERITY:-HIGH}" i
    for i in "${!_SEC_SEVERITIES[@]}"; do
        _severity_meets_threshold "${_SEC_SEVERITIES[$i]}" "$block_severity" && return 0
    done
    return 1
}
_build_fixable_block()   { _build_block_via_go fixable; }
_build_unfixable_block() { _build_block_via_go unfixable; }
_build_notes_block()     { _build_block_via_go notes; }
_build_block_via_go() {
    "${TEKHTON_BIN:-tekhton}" security build-block --kind "$1" \
        --report "${SECURITY_REPORT_FILE:-.tekhton/SECURITY_REPORT.md}" \
        --threshold "${SECURITY_BLOCK_SEVERITY:-HIGH}"
}
_handle_unfixable_findings() { # halt branch keeps state-write inline; m35.2 lifts it.
    local block="$1" policy="${SECURITY_UNFIXABLE_POLICY:-escalate}" ha
    [[ -z "$block" ]] && return 0
    if [[ "$policy" == "halt" ]]; then
        error "[security] Pipeline halted — unfixable CRITICAL/HIGH security findings detected."
        write_pipeline_state "security" "security_halt" \
            "${MILESTONE_MODE:+--milestone }--start-at security" \
            "${TASK:-}" "Unfixable security findings with halt policy."
        return 1
    fi
    ha="${HUMAN_ACTION_FILE:-}"; local -a ha_args=()
    [[ -n "$ha" ]] && ha_args=(--human-action-file "$ha")
    "${TEKHTON_BIN:-tekhton}" security handle-unfixable --policy "$policy" \
        --block "$block" --task "${TASK:-}" --project-dir "${PROJECT_DIR:-$PWD}" "${ha_args[@]}"
}
# _write_security_notes stays bash for m35.1; m35.2 ports and deletes.
_write_security_notes() {
    local notes="$1" unfix="$2" out="${SECURITY_NOTES_FILE:-}"
    [[ -z "$out" ]] && return 0
    {
        printf '# Security Notes\n\nGenerated: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        [[ -n "$notes" ]] && printf '## Non-Blocking Findings (MEDIUM/LOW)\n%s\n' "$notes"
        [[ -n "$unfix" && "${SECURITY_UNFIXABLE_POLICY:-escalate}" == "waiver" ]] && \
            printf '## Waivered Findings\n%s\n' "$unfix"
    } > "$out"
}
