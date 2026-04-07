#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_triage.sh — Note triage: heuristic scoring, core triage, agent escalation
#
# Sourced by tekhton.sh — do not run directly.
# Expects: notes_core.sh, notes_single.sh, common.sh sourced first.
# See also: notes_triage_flow.sh (promotion, pipeline integration, report).
#
# Provides:
#   Heuristics:  _triage_heuristic_score, _compute_text_hash
#   Core:        triage_note
#   Agent:       _triage_agent_escalation, _parse_triage_agent_output
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
    _set_note_metadata "$id" "triaged" "$(date -u +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)" || true

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

    # Clean up exported template variables
    unset TRIAGE_NOTE_TEXT TRIAGE_NOTE_TAG TRIAGE_NOTE_DESCRIPTION TRIAGE_ARCHITECTURE_SUMMARY

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
