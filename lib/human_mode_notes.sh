#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# human_mode_notes.sh — m24 bash↔Go shim for human-mode note helpers.
#
# The 14 lib/notes*.sh files were deleted in m24; the canonical
# implementation lives in internal/notes. This file holds the thin bash
# wrappers the --human / --with-notes pipeline modes call. Every
# wrapper here exec's `tekhton note <subcommand>` so the in-process
# state machine remains the source of truth.
#
# Names exposed (none match the m24 wedge-audit deny list):
#   _notes_bin                — resolves the tekhton Go binary
#   _extract_note_id          — pure-bash regex; preserved for callers
#   extract_note_text         — pure-bash; preserved for callers
#   _find_note_by_id          — wraps `tekhton note find <ID>`
#   pick_next_note            — wraps `tekhton note pick-next [--tag]`
#   count_unchecked_notes     — wraps `tekhton note count`
#   claim_single_note         — claim a single line by extracting its ID
#                               and calling `tekhton note claim <ID>`
#   resolve_single_note       — exit-code-driven Done / Pending transition
#                               via `tekhton note done` / `note unclaim`
#   triage_before_claim       — non-blocking stub (full triage agent
#                               flow ports as a follow-on; default fit)
#
# CLAIMED_NOTE_IDS — preserved as a bash global because tekhton-legacy.sh
# still threads it into the bulk-resolve helper through the env. The
# shim populates it on successful claim.
# =============================================================================

# CLAIMED_NOTE_IDS — space-separated list of IDs claimed during this run.
# Read by the finalize chain's resolve_notes hook (now Go).
CLAIMED_NOTE_IDS=""

# _notes_bin — resolve the tekhton Go binary or print empty.
_notes_bin() {
    local b="${TEKHTON_BIN:-${TEKHTON_HOME:-.}/bin/tekhton}"
    if [[ -x "$b" ]]; then
        echo "$b"; return 0
    fi
    b="${TEKHTON_HOME:-.}/tekhton"
    if [[ -x "$b" ]]; then
        echo "$b"; return 0
    fi
    command -v tekhton 2>/dev/null || echo ""
}

# _extract_note_id LINE — Extract the nNN id from a note line. Pure bash
# regex (no subprocess) because callers run this in tight loops.
_extract_note_id() {
    local line="${1:-}"
    if [[ "$line" =~ \<\!--\ note:([^ ]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

# extract_note_text LINE — Strip the checkbox prefix + trailing
# metadata. Pure bash (mirrors lib/notes_single.sh::extract_note_text).
extract_note_text() {
    local note_line="${1:-}"
    local text="${note_line#- \[?\] }"
    text="${text%% <!-- note:*}"
    echo "$text"
}

# _find_note_by_id ID — Print the raw line for the note with the given
# ID, or empty when not found.
_find_note_by_id() {
    local id="${1:-}"
    local bin
    bin="$(_notes_bin)"
    if [[ -z "$id" ]] || [[ -z "$bin" ]]; then
        echo ""; return 0
    fi
    "$bin" note find --project-dir "${PROJECT_DIR:-.}" "$id" 2>/dev/null || echo ""
}

# pick_next_note [TAG] — Print the line of the next Pending note.
pick_next_note() {
    local tag="${1:-}"
    local bin
    bin="$(_notes_bin)"
    if [[ -z "$bin" ]]; then
        echo ""; return 0
    fi
    if [[ -n "$tag" ]]; then
        "$bin" note pick-next --project-dir "${PROJECT_DIR:-.}" --tag "$tag" 2>/dev/null || echo ""
    else
        "$bin" note pick-next --project-dir "${PROJECT_DIR:-.}" 2>/dev/null || echo ""
    fi
}

# count_unchecked_notes [TAG] — Print the count of Pending notes.
# When TAG empty, NOTES_FILTER env applies (preserves bash semantics).
count_unchecked_notes() {
    local tag="${1:-}"
    local bin
    bin="$(_notes_bin)"
    if [[ -z "$bin" ]]; then
        echo "0"; return 0
    fi
    if [[ -n "$tag" ]]; then
        "$bin" note count --project-dir "${PROJECT_DIR:-.}" --tag "$tag" 2>/dev/null || echo "0"
    else
        "$bin" note count --project-dir "${PROJECT_DIR:-.}" 2>/dev/null || echo "0"
    fi
}

# (m24: the bash clear-completed wrapper was removed. tekhton-legacy.sh
# now exec's `tekhton note clear-completed` directly at the lone call
# site.)

# claim_single_note LINE — Claim a single note by extracting its ID.
# Mirrors the old lib/notes_single.sh contract: marks the matching
# Pending note Active and appends its ID to CLAIMED_NOTE_IDS.
claim_single_note() {
    local note_line="${1:-}"
    local bin
    bin="$(_notes_bin)"
    if [[ -z "$note_line" ]] || [[ -z "$bin" ]]; then
        return 1
    fi
    local nid
    nid="$(_extract_note_id "$note_line")"
    if [[ -z "$nid" ]]; then
        return 1
    fi
    if "$bin" note claim --project-dir "${PROJECT_DIR:-.}" "$nid" >/dev/null 2>&1; then
        CLAIMED_NOTE_IDS="${CLAIMED_NOTE_IDS:+${CLAIMED_NOTE_IDS} }${nid}"
        return 0
    fi
    # Already-Active is a soft success (resume path).
    if [[ "$note_line" =~ ^-\ \[~\] ]]; then
        CLAIMED_NOTE_IDS="${CLAIMED_NOTE_IDS:+${CLAIMED_NOTE_IDS} }${nid}"
        return 0
    fi
    return 1
}

# resolve_single_note LINE EXIT_CODE — Done (exit 0) or Pending (else)
# transition for a single Active/Pending note line.
resolve_single_note() {
    local note_line="${1:-}"
    local exit_code="${2:-1}"
    local bin
    bin="$(_notes_bin)"
    if [[ -z "$note_line" ]] || [[ -z "$bin" ]]; then
        return 1
    fi
    local nid
    nid="$(_extract_note_id "$note_line")"
    if [[ -z "$nid" ]]; then
        return 1
    fi
    if [[ "$exit_code" -eq 0 ]]; then
        # shellcheck disable=SC1010  # `done` is a cobra subcommand here.
        "$bin" note "done" --project-dir "${PROJECT_DIR:-.}" "$nid" >/dev/null 2>&1 || return 1
    else
        # Pipeline failed — return claimed Active note to Pending.
        "$bin" note unclaim --project-dir "${PROJECT_DIR:-.}" "$nid" >/dev/null 2>&1 || true
    fi
    return 0
}

# triage_before_claim ID — m24 minimal stub. Always returns 0 ("proceed")
# so the human-mode loop runs the note. The full interactive promotion
# flow (oversized-note detection + agent escalation + milestone
# promotion prompt) ports as a follow-on milestone; until then the
# bash flag HUMAN_NOTES_TRIAGE_ENABLED=false produces the same effective
# behavior we ship today.
triage_before_claim() {
    return 0
}

# --- Bulk wrappers used by stages/coder.sh ---------------------------------

# _m24_notes_bin — alias of _notes_bin so call sites in stages/coder.sh
# (which used _m24_* names) keep working without re-import.
_m24_notes_bin() { _notes_bin; }

# _m24_notes_should_claim — Notes-claim predicate. WITH_NOTES,
# HUMAN_MODE, NOTES_FILTER env honored.
_m24_notes_should_claim() {
    local b; b="$(_notes_bin)"
    if [[ -z "$b" ]]; then return 1; fi
    WITH_NOTES="${WITH_NOTES:-false}" \
    HUMAN_MODE="${HUMAN_MODE:-false}" \
    NOTES_FILTER="${NOTES_FILTER:-}" \
        "$b" note should-claim >/dev/null 2>&1
}

# _m24_notes_extract — Print HUMAN_NOTES_BLOCK content (replaces the
# extract-block helper from the deleted lib/notes.sh).
_m24_notes_extract() {
    local b; b="$(_notes_bin)"
    if [[ -z "$b" ]]; then return 0; fi
    if [[ -n "${NOTES_FILTER:-}" ]]; then
        "$b" note extract --project-dir "${PROJECT_DIR:-.}" --tag "$NOTES_FILTER" 2>/dev/null || true
    else
        "$b" note extract --project-dir "${PROJECT_DIR:-.}" 2>/dev/null || true
    fi
}

# _m24_notes_claim_bulk — Bulk-claim Pending notes by NOTES_FILTER;
# populates CLAIMED_NOTE_IDS so the finalize chain can resolve them.
_m24_notes_claim_bulk() {
    local b; b="$(_notes_bin)"
    if [[ -z "$b" ]]; then return 0; fi
    local out
    if [[ -n "${NOTES_FILTER:-}" ]]; then
        out=$("$b" note claim-bulk --project-dir "${PROJECT_DIR:-.}" --tag "$NOTES_FILTER" 2>/dev/null || true)
    else
        out=$("$b" note claim-bulk --project-dir "${PROJECT_DIR:-.}" 2>/dev/null || true)
    fi
    if [[ -n "$out" ]]; then
        CLAIMED_NOTE_IDS="${CLAIMED_NOTE_IDS:+${CLAIMED_NOTE_IDS} }${out}"
        local n; n=$(echo "$out" | wc -w | tr -d '[:space:]')
        if [[ -n "${NOTES_FILTER:-}" ]]; then
            log "${HUMAN_NOTES_FILE:-.tekhton/HUMAN_NOTES.md} — ${n} [${NOTES_FILTER}] item(s) marked in-progress [~]."
        else
            log "${HUMAN_NOTES_FILE:-.tekhton/HUMAN_NOTES.md} — ${n} item(s) marked in-progress [~]."
        fi
    fi
}

# _m24_notes_resolve_bulk — Bulk-resolve based on _PIPELINE_EXIT_CODE.
_m24_notes_resolve_bulk() {
    local b; b="$(_notes_bin)"
    if [[ -z "$b" ]]; then return 0; fi
    local exit_code="${_PIPELINE_EXIT_CODE:-1}"
    "$b" note resolve-bulk --project-dir "${PROJECT_DIR:-.}" \
        --exit-code "$exit_code" --ids "${CLAIMED_NOTE_IDS:-}" >/dev/null 2>&1 || true
}
