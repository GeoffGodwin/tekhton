#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_triage.sh — Note triage: sizing gate, agent escalation, promotion flow
#
# Sourced by tekhton.sh — do not run directly.
# Expects: notes_core.sh, notes_single.sh, common.sh sourced first.
#
# Provides:
#   Heuristics:  _triage_heuristic_score, triage_note
#   Promotion:   _prompt_promote_note, promote_note_to_milestone
#   Pipeline:    triage_before_claim, triage_bulk_warn
#   Report:      run_triage_report
# =============================================================================

# --- Heuristic Scoring -------------------------------------------------------

# Scope keywords that indicate large, milestone-scale work (score +3 each)
readonly _TRIAGE_SCOPE_KEYWORDS="rewrite|redesign|migrate|new system|replace|overhaul|refactor entire|add support for"

# Scale indicators suggesting breadth (score +2 each)
readonly _TRIAGE_SCALE_INDICATORS="\\ball\\b|\\bevery\\b|\\bentire\\b|across the codebase"

# _triage_heuristic_score NOTE_TEXT TAG
# Returns score on stdout, sets _TRIAGE_CONFIDENCE (high|low).
_triage_heuristic_score() {
    local text="$1"
    local tag="${2:-}"
    local score=0
    local lower_text
    lower_text=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')

    # Scope keywords: +3 each
    local kw
    while IFS='|' read -ra kws; do
        for kw in "${kws[@]}"; do
            if [[ "$lower_text" == *"$kw"* ]]; then
                score=$(( score + 3 ))
            fi
        done
    done <<< "${_TRIAGE_SCOPE_KEYWORDS}"

    # Scale indicators: +2 each (regex match for word boundaries)
    local ind
    while IFS='|' read -ra inds; do
        for ind in "${inds[@]}"; do
            if printf '%s ' "$lower_text" | grep -qE "$ind" 2>/dev/null; then
                score=$(( score + 2 ))
            fi
        done
    done <<< "${_TRIAGE_SCALE_INDICATORS}"

    # Length heuristic: > 120 chars → +1
    if [[ "${#text}" -gt 120 ]]; then
        score=$(( score + 1 ))
    fi

    # Tag weight: BUG -2, POLISH -1
    case "$tag" in
        BUG)    score=$(( score - 2 )) ;;
        POLISH) score=$(( score - 1 )) ;;
    esac

    # Floor at 0
    if [[ "$score" -lt 0 ]]; then
        score=0
    fi

    # Confidence determination
    if [[ "$score" -ge 5 ]]; then
        _TRIAGE_CONFIDENCE="high"
    elif [[ "$score" -le 1 ]]; then
        _TRIAGE_CONFIDENCE="high"
    else
        _TRIAGE_CONFIDENCE="low"
    fi

    echo "$score"
}

# _compute_text_hash TEXT — Returns a short hash for change detection.
_compute_text_hash() {
    local text="$1"
    # Use cksum for portability (no dependency on md5sum/shasum)
    printf '%s' "$text" | cksum | cut -d' ' -f1
}

# --- Triage Core --------------------------------------------------------------

# _TRIAGE_RESULT vars set by triage_note
_TRIAGE_DISPOSITION=""    # fit|oversized
_TRIAGE_EST_TURNS=""      # estimated turns (numeric)
_TRIAGE_CONFIDENCE=""     # high|low

# triage_note ID — Evaluate a single note and set _TRIAGE_* globals.
# Returns 0 on success (result set), 1 if note not found.
triage_note() {
    local id="$1"
    _TRIAGE_DISPOSITION="fit"
    _TRIAGE_EST_TURNS=""
    _TRIAGE_CONFIDENCE="high"

    if [[ "${HUMAN_NOTES_TRIAGE_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    local line
    line=$(_find_note_by_id "$id")
    if [[ -z "$line" ]]; then
        return 1
    fi

    # Extract text and tag
    local text
    text=$(extract_note_text "$line")
    local tag=""
    if [[ "$line" =~ \[BUG\] ]]; then tag="BUG"
    elif [[ "$line" =~ \[FEAT\] ]]; then tag="FEAT"
    elif [[ "$line" =~ \[POLISH\] ]]; then tag="POLISH"
    fi

    # Check cached triage
    local cached_triage="" cached_hash="" current_hash=""
    _parse_note_metadata "$line"
    cached_triage="${_NM_TRIAGE:-}"
    if [[ "$line" =~ text_hash:([^ ]+) ]]; then
        cached_hash="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ est_turns:([^ ]+) ]]; then
        _TRIAGE_EST_TURNS="${BASH_REMATCH[1]}"
    fi

    current_hash=$(_compute_text_hash "$text")

    # If cached and text unchanged, use cached result
    if [[ -n "$cached_triage" ]] && [[ "$cached_hash" == "$current_hash" ]]; then
        _TRIAGE_DISPOSITION="$cached_triage"
        _TRIAGE_CONFIDENCE="high"
        return 0
    fi

    # Run heuristic scoring
    local score
    score=$(_triage_heuristic_score "$text" "$tag")

    if [[ "$score" -ge 5 ]]; then
        _TRIAGE_DISPOSITION="oversized"
        # Rough estimate: 5 turns per scope keyword hit
        if [[ -z "$_TRIAGE_EST_TURNS" ]]; then
            _TRIAGE_EST_TURNS=$(( score * 5 ))
        fi
    elif [[ "$score" -le 1 ]]; then
        _TRIAGE_DISPOSITION="fit"
        if [[ -z "$_TRIAGE_EST_TURNS" ]]; then
            _TRIAGE_EST_TURNS=$(( (score + 1) * 3 ))
        fi
    fi

    # Low confidence → agent escalation
    if [[ "$_TRIAGE_CONFIDENCE" == "low" ]]; then
        _triage_agent_escalation "$text" "$tag" "$id"
    fi

    # Persist triage metadata
    _set_note_metadata "$id" "triage" "$_TRIAGE_DISPOSITION" || true
    if [[ -n "$_TRIAGE_EST_TURNS" ]]; then
        _set_note_metadata "$id" "est_turns" "$_TRIAGE_EST_TURNS" || true
    fi
    _set_note_metadata "$id" "text_hash" "$current_hash" || true
    _set_note_metadata "$id" "triaged" "$(date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)" || true

    return 0
}

# --- Agent Escalation ---------------------------------------------------------

# _triage_agent_escalation TEXT TAG ID
# Calls a lightweight agent (Haiku by default) for definitive triage.
_triage_agent_escalation() {
    local text="$1"
    local tag="${2:-}"
    local id="${3:-}"

    # Skip if run_agent is not available (e.g. --triage in minimal sourcing)
    if ! declare -f run_agent >/dev/null 2>&1; then
        # Fall back to heuristic midpoint: score 2-4 defaults to fit
        _TRIAGE_DISPOSITION="fit"
        _TRIAGE_EST_TURNS="${_TRIAGE_EST_TURNS:-10}"
        _TRIAGE_CONFIDENCE="high"
        warn "Agent escalation unavailable; defaulting to fit for note ${id}"
        return 0
    fi

    local model="${HUMAN_NOTES_TRIAGE_MODEL:-haiku}"

    # Build architecture summary (first 2K chars if available)
    local arch_summary=""
    if [[ -n "${ARCHITECTURE_FILE:-}" ]] && [[ -f "${ARCHITECTURE_FILE}" ]]; then
        arch_summary=$(head -c 2048 "$ARCHITECTURE_FILE" 2>/dev/null || true)
    fi

    # Build description block if present
    local nf
    nf=$(_notes_file)
    local desc_block=""
    if [[ -f "$nf" ]]; then
        local found_note=false
        while IFS= read -r line; do
            if [[ "$found_note" == true ]]; then
                if [[ "$line" =~ ^[[:space:]]*\> ]]; then
                    local desc_text="${line#"${line%%[! ]*}"}"
                    desc_text="${desc_text#> }"
                    desc_text="${desc_text#>}"
                    desc_block="${desc_block:+${desc_block}
}${desc_text}"
                else
                    break
                fi
            elif [[ "$line" =~ \<\!--\ note:${id}\  ]]; then
                found_note=true
            fi
        done < "$nf"
    fi

    # Set template variables and render prompt
    export TRIAGE_NOTE_TEXT="$text"
    export TRIAGE_NOTE_TAG="$tag"
    export TRIAGE_NOTE_DESCRIPTION="$desc_block"
    export TRIAGE_ARCHITECTURE_SUMMARY="$arch_summary"

    local prompt
    prompt=$(render_prompt "notes_triage" 2>/dev/null || true)
    if [[ -z "$prompt" ]]; then
        warn "Triage prompt template not found; defaulting to fit for note ${id}"
        _TRIAGE_DISPOSITION="fit"
        _TRIAGE_EST_TURNS="${_TRIAGE_EST_TURNS:-10}"
        _TRIAGE_CONFIDENCE="high"
        return 0
    fi

    local log_file="${LOG_DIR:-/tmp}/triage_${id}.log"
    local agent_exit=0
    run_agent "Triage" "$model" 3 "$prompt" "$log_file" || agent_exit=$?

    if [[ "$agent_exit" -ne 0 ]]; then
        warn "Triage agent failed (exit ${agent_exit}); defaulting to fit for note ${id}"
        _TRIAGE_DISPOSITION="fit"
        _TRIAGE_EST_TURNS="${_TRIAGE_EST_TURNS:-10}"
        _TRIAGE_CONFIDENCE="high"
        return 0
    fi

    # Parse agent output from log
    _parse_triage_agent_output "$log_file"
}

# _parse_triage_agent_output LOG_FILE
# Extracts DISPOSITION, ESTIMATED_TURNS, RATIONALE from agent output.
_parse_triage_agent_output() {
    local log_file="$1"
    if [[ ! -f "$log_file" ]]; then
        return 0
    fi

    local disp=""
    local turns=""
    disp=$(grep -i '^DISPOSITION:' "$log_file" 2>/dev/null | head -1 | sed 's/^DISPOSITION:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' || true)
    turns=$(grep -i '^ESTIMATED_TURNS:' "$log_file" 2>/dev/null | head -1 | sed 's/^ESTIMATED_TURNS:[[:space:]]*//' | grep -oE '[0-9]+' || true)

    if [[ "$disp" == "fit" ]] || [[ "$disp" == "oversized" ]]; then
        _TRIAGE_DISPOSITION="$disp"
        _TRIAGE_CONFIDENCE="high"
    fi
    if [[ -n "$turns" ]]; then
        _TRIAGE_EST_TURNS="$turns"
    fi
}

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
