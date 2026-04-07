#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_rollback.sh — Note state snapshot and restore for rollback support
#
# Sourced by tekhton.sh after notes_core.sh — do not run directly.
# Expects: notes_core.sh sourced first (_notes_file, _extract_note_id).
#
# Provides:
#   snapshot_note_states  — capture current note checkbox states as JSON
#   restore_note_states   — reset [~] notes to pre-run state from snapshot
# =============================================================================

# snapshot_note_states — Record which note IDs are in which state.
# Writes JSON-ish state to stdout for checkpoint embedding.
snapshot_note_states() {
    local nf
    nf="$(_notes_file)"
    if [[ ! -f "$nf" ]]; then
        echo "{}"
        return 0
    fi

    local json="{"
    local first=true
    while IFS= read -r line; do
        local nid=""
        if [[ "$line" =~ \<\!--\ note:([^ ]+) ]]; then
            nid="${BASH_REMATCH[1]}"
        else
            continue
        fi

        local state=""
        if [[ "$line" =~ ^-\ \[x\] ]]; then
            state="x"
        elif [[ "$line" =~ ^-\ \[~\] ]]; then
            state="~"
        elif [[ "$line" =~ ^-\ \[\ \] ]]; then
            state=" "
        else
            continue
        fi

        if [[ "$first" == true ]]; then
            first=false
        else
            json="${json},"
        fi
        json="${json}\"${nid}\":\"${state}\""
    done < "$nf"

    json="${json}}"
    echo "$json"
}

# restore_note_states SNAPSHOT_JSON — Restore note states after rollback.
# Any note that was [~] (claimed by this run) gets reset to [ ].
# Notes that were [x] before the run stay [x].
# Notes added mid-run (no entry in snapshot) are left untouched.
restore_note_states() {
    local snapshot="$1"
    local nf
    nf="$(_notes_file)"
    if [[ ! -f "$nf" ]] || [[ -z "$snapshot" ]] || [[ "$snapshot" == "{}" ]]; then
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        local nid=""
        if [[ "$line" =~ \<\!--\ note:([^ ]+) ]]; then
            nid="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$nid" ]] && [[ "$line" =~ ^-\ \[~\] ]]; then
            # Check if this note was [ ] in the snapshot — if so, reset it
            if echo "$snapshot" | grep -q "\"${nid}\":\" \"" 2>/dev/null; then
                printf '%s\n' "${line/\[~\]/[ ]}"
                continue
            fi
        fi
        printf '%s\n' "$line"
    done < "$nf" > "$tmpfile"
    mv "$tmpfile" "$nf"
}
