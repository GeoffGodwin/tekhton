#!/usr/bin/env bash
# =============================================================================
# milestone_acceptance_deliverable.sh — S2 deliverable gate helpers
#
# Sourced by lib/milestone_acceptance.sh — do not run directly.
#
# S2 (2026-06-14): the deterministic half of "did the milestone actually do
# what it promised". m27 only proves SOME non-artifact file changed; it does
# not prove the DECLARED deliverables were produced (m22 was marked done having
# changed an unrelated file, never creating internal/provider/profile.go). This
# parses the active milestone's "## Files Modified" table and lets the caller
# assert each declared deliverable appears in the changeset.
#
# Expects: _read_milestone_file (lib/milestone_window.sh) for DAG file lookup.
# =============================================================================

# _milestone_declared_files MILESTONE_NUM
# Echoes "path<TAB>changetype" for each row of the milestone's "## Files
# Modified" table. Empty output when the file/table can't be read (caller then
# skips the gate rather than blocking on an unparseable milestone).
_milestone_declared_files() {
    local num="$1" content
    declare -f _read_milestone_file >/dev/null 2>&1 || return 0
    content=$(_read_milestone_file "$num" 2>/dev/null) || return 0
    [ -n "$content" ] || return 0
    printf '%s\n' "$content" | awk '
        /^## Files Modified/ { ins=1; next }
        ins && /^## / { exit }
        ins && /^\|/ {
            n=split($0, c, "|")
            if (n < 3) next
            path=c[2]; type=c[3]
            gsub(/`/, "", path)
            gsub(/^[ \t]+|[ \t]+$/, "", path)
            gsub(/^[ \t]+|[ \t]+$/, "", type)
            if (path=="" || path=="File" || path ~ /^-+$/) next
            print path "\t" type
        }
    '
}

# _milestone_changed_set
# Echoes every path changed vs HEAD plus untracked files (one per line) — the
# milestone's complete output at acceptance time (nothing commits mid-milestone).
_milestone_changed_set() {
    {
        git diff --name-only HEAD 2>/dev/null || true
        git ls-files --others --exclude-standard 2>/dev/null || true
    } | sort -u
}
