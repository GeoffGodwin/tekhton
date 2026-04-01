#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_triage_flow.sh — Promotion flow, pipeline integration
#
# Sourced by tekhton.sh — do not run directly.
# Expects: notes_triage.sh sourced first (provides triage_note, _TRIAGE_* globals).
# Expects: notes_core.sh sourced first (provides _find_note_by_id, _extract_note_id,
#          _notes_file, _set_note_metadata, extract_note_text).
# Expects: common.sh sourced first (provides log, warn, success, header).
# See also: notes_triage_report.sh (run_triage_report — extracted for size).
#
# Provides:
#   Promotion:   _prompt_promote_note, promote_note_to_milestone
#   Pipeline:    triage_before_claim, triage_bulk_warn
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

