#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_triage_flow.sh — Promotion flow, pipeline integration, triage report
#
# Sourced by tekhton.sh — do not run directly.
# Expects: notes_triage.sh sourced first (provides triage_note, _TRIAGE_* globals).
# Expects: notes_core.sh sourced first (provides _find_note_by_id, _extract_note_id,
#          _notes_file, _set_note_metadata, extract_note_text).
# Expects: common.sh sourced first (provides log, warn, success, header).
#
# Provides:
#   Promotion:   _prompt_promote_note, promote_note_to_milestone
#   Pipeline:    triage_before_claim, triage_bulk_warn
#   Report:      run_triage_report
# =============================================================================

# --- Promotion Flow -----------------------------------------------------------

# _prompt_promote_note ID TEXT EST_TURNS
# Interactive prompt for oversized note promotion. Returns: p, k, or s.
_prompt_promote_note() {
    local id="$1"
    local text="$2"
    local est_turns="${3:-?}"
    local threshold="${HUMAN_NOTES_PROMOTE_THRESHOLD:-20}"

    echo "" >&2
    echo "Note ${id} \"${text}\" is estimated at ~${est_turns} turns." >&2
    echo "This exceeds the promotion threshold (${threshold} turns) and would work better as a milestone." >&2
    echo "" >&2
    echo "  [p] Promote to milestone  [k] Keep as note  [s] Skip this note" >&2
    echo "" >&2

    local choice=""
    while true; do
        if [[ ! -t 0 ]]; then
            warn "Non-interactive mode; defaulting to [k] keep."
            choice="k"
            break
        fi
        read -rp "Choice [p/k/s]: " choice < /dev/tty 2>/dev/null || {
            warn "Could not read input; defaulting to [k] keep."
            choice="k"
            break
        }
        case "$choice" in
            p|P) choice="p"; break ;;
            k|K) choice="k"; break ;;
            s|S) choice="s"; break ;;
            *) echo "  Invalid choice. Enter p, k, or s." >&2 ;;
        esac
    done
    echo "$choice"
}

# promote_note_to_milestone ID TEXT [DESCRIPTION]
# Creates a milestone from the note via run_intake_create and marks note [x].
# Returns 0 on success, 1 on failure. Sets PROMOTED_MILESTONE_ID.
PROMOTED_MILESTONE_ID=""

promote_note_to_milestone() {
    local id="$1"
    local text="$2"
    local description="${3:-}"

    local full_desc="$text"
    if [[ -n "$description" ]]; then
        full_desc="${text}

${description}"
    fi

    PROMOTED_MILESTONE_ID=""

    if declare -f run_intake_create >/dev/null 2>&1; then
        run_intake_create "$full_desc"
        # Extract the milestone ID from the manifest (last entry)
        local manifest_file="${MILESTONE_DIR:-${PROJECT_DIR:-.}/.claude/milestones}/${MILESTONE_MANIFEST:-MANIFEST.cfg}"
        if [[ -f "$manifest_file" ]]; then
            local last_id
            last_id=$(tail -1 "$manifest_file" | cut -d'|' -f1)
            PROMOTED_MILESTONE_ID="$last_id"
        fi
    else
        warn "run_intake_create not available; cannot promote note ${id}."
        return 1
    fi

    # Mark note as completed with promoted metadata
    local nf
    nf=$(_notes_file)
    if [[ -f "$nf" ]]; then
        # Mark [x] and add promoted metadata
        local tmpfile
        tmpfile=$(mktemp)
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ \<\!--\ note:${id}\  ]] && [[ "$line" =~ ^-\ \[.\] ]]; then
                # Set to [x]
                line="${line/\[ \]/[x]}"
                line="${line/\[~\]/[x]}"
                # Add promoted metadata
                if [[ -n "$PROMOTED_MILESTONE_ID" ]]; then
                    line="${line/ -->/ promoted:${PROMOTED_MILESTONE_ID} -->}"
                fi
                printf '%s\n' "$line"
            else
                printf '%s\n' "$line"
            fi
        done < "$nf" > "$tmpfile"
        mv "$tmpfile" "$nf"
    fi

    if [[ -n "$PROMOTED_MILESTONE_ID" ]]; then
        success "Note ${id} promoted to milestone ${PROMOTED_MILESTONE_ID}"
    fi
    return 0
}

# --- Pipeline Integration ----------------------------------------------------

# triage_before_claim ID — Run triage and handle promotion flow for a single note.
# Returns: 0 = proceed with execution, 1 = note was promoted/skipped.
triage_before_claim() {
    local id="$1"

    if [[ "${HUMAN_NOTES_TRIAGE_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    if ! triage_note "$id"; then
        return 0  # Note not found — let caller handle
    fi

    local threshold="${HUMAN_NOTES_PROMOTE_THRESHOLD:-20}"
    local est="${_TRIAGE_EST_TURNS:-0}"

    # Only trigger promotion for oversized notes above threshold
    if [[ "$_TRIAGE_DISPOSITION" != "oversized" ]]; then
        return 0
    fi
    if [[ "$est" -le "$threshold" ]] 2>/dev/null; then
        return 0
    fi

    local line
    line=$(_find_note_by_id "$id")
    local text
    text=$(extract_note_text "$line")

    local mode="${HUMAN_NOTES_PROMOTE_MODE:-confirm}"
    if [[ "$mode" == "auto" ]]; then
        log "Auto-promoting oversized note ${id} (~${est} turns)"
        promote_note_to_milestone "$id" "$text" || true
        return 1
    fi

    # Confirm mode
    local choice
    choice=$(_prompt_promote_note "$id" "$text" "$est")
    case "$choice" in
        p)
            promote_note_to_milestone "$id" "$text" || true
            return 1
            ;;
        s)
            log "Skipping note ${id}"
            return 1
            ;;
        k)
            log "Keeping note ${id} as-is (user chose to proceed)"
            return 0
            ;;
    esac
    return 0
}

# triage_bulk_warn — Triage all unchecked notes and warn about oversized ones.
# Used by --with-notes bulk path. Does not auto-promote.
triage_bulk_warn() {
    local filter="${1:-}"

    if [[ "${HUMAN_NOTES_TRIAGE_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    local nf
    nf=$(_notes_file)
    if [[ ! -f "$nf" ]]; then
        return 0
    fi

    local oversized_ids=""
    local oversized_count=0
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^-\ \[\ \] ]]; then
            continue
        fi
        if [[ -n "$filter" ]] && [[ ! "$line" =~ \[${filter}\] ]]; then
            continue
        fi
        local nid
        nid=$(_extract_note_id "$line")
        if [[ -z "$nid" ]]; then
            continue
        fi
        triage_note "$nid" || continue
        if [[ "$_TRIAGE_DISPOSITION" == "oversized" ]]; then
            oversized_ids="${oversized_ids:+${oversized_ids} }${nid}"
            oversized_count=$(( oversized_count + 1 ))
        fi
    done < "$nf"

    if [[ "$oversized_count" -gt 0 ]]; then
        warn "${oversized_count} note(s) flagged as oversized: ${oversized_ids}"
        warn "Consider running 'tekhton --triage' to review before executing."
    fi
}

# --- Triage Report (--triage command) -----------------------------------------

# run_triage_report [TAG_FILTER] — Triage all unchecked notes, print report.
run_triage_report() {
    local filter="${1:-}"

    local nf
    nf=$(_notes_file)
    if [[ ! -f "$nf" ]]; then
        log "No HUMAN_NOTES.md found."
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
