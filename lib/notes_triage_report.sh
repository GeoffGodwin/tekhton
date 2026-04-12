#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_triage_report.sh — Triage report display (--triage command)
#
# Sourced by tekhton.sh — do not run directly.
# Extracted from notes_triage_flow.sh for file-size compliance.
# Expects: notes_triage.sh sourced first (provides triage_note, _TRIAGE_* globals).
# Expects: notes_core.sh sourced first (provides _extract_note_id, extract_note_text).
# Expects: common.sh sourced first (provides log, warn, header).
#
# Provides:
#   run_triage_report  — Triage all unchecked notes, print report
# =============================================================================

# run_triage_report [TAG_FILTER] — Triage all unchecked notes, print report.
run_triage_report() {
    local filter="${1:-}"

    local nf
    nf=$(_notes_file)
    if [[ ! -f "$nf" ]]; then
        log "No ${HUMAN_NOTES_FILE} found."
        return 0
    fi

    local total=0 fit_count=0 oversized_count=0
    # Collect results for tabular display
    local -a result_ids=() result_tags=() result_disps=() result_turns=() result_titles=()

    while IFS= read -r line; do
        if [[ ! "$line" =~ ^-\ \[\ \] ]]; then
            continue
        fi
        # Tag extraction
        local tag=""
        if [[ "$line" =~ \[BUG\] ]]; then tag="BUG"
        elif [[ "$line" =~ \[FEAT\] ]]; then tag="FEAT"
        elif [[ "$line" =~ \[POLISH\] ]]; then tag="POLISH"
        fi

        if [[ -n "$filter" ]] && [[ "$tag" != "$filter" ]]; then
            continue
        fi

        local nid
        nid=$(_extract_note_id "$line")
        if [[ -z "$nid" ]]; then
            continue
        fi

        triage_note "$nid" || continue
        total=$(( total + 1 ))

        local title
        title=$(extract_note_text "$line")
        # Truncate title for display
        if [[ "${#title}" -gt 50 ]]; then
            title="${title:0:47}..."
        fi

        result_ids+=("$nid")
        result_tags+=("$tag")
        result_disps+=("$_TRIAGE_DISPOSITION")
        result_turns+=("${_TRIAGE_EST_TURNS:-?}")
        result_titles+=("$title")

        if [[ "$_TRIAGE_DISPOSITION" == "oversized" ]]; then
            oversized_count=$(( oversized_count + 1 ))
        else
            fit_count=$(( fit_count + 1 ))
        fi
    done < "$nf"

    if [[ "$total" -eq 0 ]]; then
        if [[ -n "$filter" ]]; then
            log "No unchecked [${filter}] notes to triage."
        else
            log "No unchecked notes to triage."
        fi
        return 0
    fi

    # Print formatted report
    echo ""
    header "Human Notes Triage Report"
    printf "  %-6s %-8s %-12s %-11s %s\n" "ID" "Tag" "Disposition" "Est. Turns" "Title"
    echo "  $(printf '%0.s─' {1..70})"

    local idx
    for (( idx=0; idx<total; idx++ )); do
        local disp_display="${result_disps[$idx]}"
        printf "  %-6s %-8s %-12s %-11s %s\n" \
            "${result_ids[$idx]}" \
            "${result_tags[$idx]}" \
            "$disp_display" \
            "${result_turns[$idx]}" \
            "${result_titles[$idx]}"
    done

    echo "  $(printf '%0.s─' {1..70})"
    echo "  ${total} notes: ${fit_count} fit, ${oversized_count} oversized"

    if [[ "$oversized_count" -gt 0 ]]; then
        echo ""
        local oversized_list=""
        for (( idx=0; idx<total; idx++ )); do
            if [[ "${result_disps[$idx]}" == "oversized" ]]; then
                oversized_list="${oversized_list:+${oversized_list}, }${result_ids[$idx]}"
            fi
        done
        echo "  Recommendation: Promote ${oversized_list} to milestone(s) before executing."
    fi
    echo ""

    # Refresh dashboard if available
    if declare -f emit_dashboard_notes >/dev/null 2>&1; then
        emit_dashboard_notes || true
    fi

    return 0
}
