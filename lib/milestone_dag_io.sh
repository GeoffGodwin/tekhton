#!/usr/bin/env bash
# milestone_dag_io.sh — m13 wedge shim. Manifest parser ported to Go; this
# file keeps the bash-array contract callers depend on by sourcing the
# pure-bash fallback and preferring `tekhton manifest list` when on PATH.
# shellcheck source=milestone_dag_io_bash.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/milestone_dag_io_bash.sh"

_dag_manifest_path() {
    local d="${MILESTONE_DIR:-.claude/milestones}"
    [[ "$d" != /* ]] && d="${PROJECT_DIR}/${d}"
    echo "${d}/${MILESTONE_MANIFEST:-MANIFEST.cfg}"
}

_dag_milestone_dir() {
    local d="${MILESTONE_DIR:-.claude/milestones}"
    [[ "$d" != /* ]] && d="${PROJECT_DIR}/${d}"
    echo "$d"
}

has_milestone_manifest() {
    [[ -f "$(_dag_manifest_path)" ]]
}

# load_manifest [PATH]
# Populates _DAG_IDS/_TITLES/_STATUSES/_DEPS/_FILES/_GROUPS/_IDX. Prefers Go
# (`tekhton manifest list`) for parsing parity; falls back to pure bash when
# the Go binary is not on PATH.
load_manifest() {
    local manifest="${1:-$(_dag_manifest_path)}"
    [[ -f "$manifest" ]] || return 1
    _DAG_IDS=(); _DAG_TITLES=(); _DAG_STATUSES=(); _DAG_DEPS=(); _DAG_FILES=(); _DAG_GROUPS=()
    _DAG_IDX=(); _DAG_LOADED=false

    local out
    if command -v tekhton >/dev/null 2>&1 \
        && out=$(tekhton manifest list --path "$manifest" 2>/dev/null); then
        local idx=0 id title status deps file group
        while IFS='|' read -r id title status deps file group; do
            [[ -z "$id" ]] && continue
            _DAG_IDS+=("$id"); _DAG_TITLES+=("$title"); _DAG_STATUSES+=("$status")
            _DAG_DEPS+=("$deps"); _DAG_FILES+=("$file"); _DAG_GROUPS+=("$group")
            _DAG_IDX["$id"]=$idx; idx=$((idx + 1))
        done <<< "$out"
    else
        _dag_bash_load_arrays "$manifest" || return 1
    fi
    [[ ${#_DAG_IDS[@]} -gt 0 ]] || return 1
    _DAG_LOADED=true
    return 0
}

# save_manifest [PATH]
# Atomic write of the in-memory arrays. The Go writer round-trips comments
# and blank lines when called via `tekhton manifest set-status`; bulk saves
# (split, migrate) go through the bash writer and re-emit the legacy header.
save_manifest() {
    local manifest="${1:-$(_dag_manifest_path)}"
    mkdir -p "$(dirname "$manifest")"
    _dag_bash_save_arrays "$manifest"
}
