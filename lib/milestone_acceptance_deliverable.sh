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

# _milestone_criteria_semijoined MILESTONE_NUM
# S5 — reads the active milestone's "## Acceptance Criteria" checkbox items from
# its DAG .md file and joins them with ';' (the shape check_milestone_acceptance
# check 3 expects). The checkbox prefix and backticks are stripped; any literal
# ';' inside an item is replaced with ',' so it doesn't split the join. Empty
# when the file/section is absent (caller falls back to CLAUDE.md for inline
# mode). Closes the DAG-mode hole where authored criteria were never read.
_milestone_criteria_semijoined() {
    local num="$1" content
    declare -f _read_milestone_file >/dev/null 2>&1 || return 0
    content=$(_read_milestone_file "$num" 2>/dev/null) || return 0
    [ -n "$content" ] || return 0
    printf '%s\n' "$content" | awk '
        /^## Acceptance Criteria/ { ins=1; next }
        ins && /^## / { exit }
        ins && /^[[:space:]]*-[[:space:]]*\[[ xX]\]/ {
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*/, "", line)
            gsub(/`/, "", line)
            gsub(/;/, ",", line)
            sub(/[[:space:]]+$/, "", line)
            if (line != "") printf "%s;", line
        }
    '
}

# _run_automatable_criteria CRITERIA_LINE
# Iterates ';'-joined acceptance criteria: runs `bash -n <safe-target>` style
# criteria, logs everything else as MANUAL. Returns 1 if any automatable
# criterion FAILED, 0 otherwise. Extracted from check_milestone_acceptance
# (S5) to keep that file under the 300-line ceiling; uses log/success/warn from
# the sourcing context.
_run_automatable_criteria() {
    local criteria_line="$1"
    [[ -n "$criteria_line" ]] || return 0
    local has_manual=false rc=0 item check_target check_exit
    local -a _crit_items
    IFS=';' read -ra _crit_items <<< "$criteria_line"
    for item in "${_crit_items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -z "$item" ]] && continue
        if [[ "$item" =~ (bash[[:space:]]+-n|shellcheck)[[:space:]]+(.*) ]]; then
            check_target="${BASH_REMATCH[2]}"
            if [[ "$check_target" =~ ^[a-zA-Z0-9_./*-]+$ ]]; then
                check_exit=0
                if [[ "$item" =~ ^bash[[:space:]]+-n ]]; then
                    bash -n "${check_target}" 2>/dev/null || check_exit=$?
                fi
                if [[ "$check_exit" -eq 0 ]]; then
                    success "Criterion: ${item}"
                else
                    warn "Criterion FAILED: ${item}"
                    rc=1
                fi
            else
                log "MANUAL: ${item}"; has_manual=true
            fi
        else
            log "MANUAL: ${item}"; has_manual=true
        fi
    done
    [[ "$has_manual" = true ]] && log "(Manual criteria require human verification)"
    return "$rc"
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
