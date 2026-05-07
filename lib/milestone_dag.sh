#!/usr/bin/env bash
# milestone_dag.sh — m14 wedge shim. The state machine ports to internal/dag
# in Go; this file keeps the in-memory _DAG_* array query API (callers iterate
# arrays directly) and forwards cross-process ops (validate / migrate /
# pointer-rewrite) to `tekhton dag <subcommand>`.
# Sourced by tekhton.sh — do not run directly.

_DAG_IDS=(); _DAG_TITLES=(); _DAG_STATUSES=(); _DAG_DEPS=(); _DAG_FILES=(); _DAG_GROUPS=()
declare -A _DAG_IDX=()
_DAG_LOADED=false

# shellcheck source=milestone_dag_io.sh disable=SC1091
source "${TEKHTON_HOME}/lib/milestone_dag_io.sh"

dag_get_count()       { echo "${#_DAG_IDS[@]}"; }
dag_get_id_at_index() { local i="$1"; [[ "$i" -ge 0 && "$i" -lt "${#_DAG_IDS[@]}" ]] || return 1; echo "${_DAG_IDS[$i]}"; }
dag_get_status()      { [[ -n "${_DAG_IDX[$1]+set}" ]] || return 1; echo "${_DAG_STATUSES[${_DAG_IDX[$1]}]}"; }
dag_set_status()      { [[ -n "${_DAG_IDX[$1]+set}" ]] || { warn "dag_set_status: unknown id '$1'"; return 1; }; _DAG_STATUSES[${_DAG_IDX[$1]}]="$2"; }
dag_get_file()        { [[ -n "${_DAG_IDX[$1]+set}" ]] || return 1; echo "${_DAG_FILES[${_DAG_IDX[$1]}]}"; }
dag_get_title()       { [[ -n "${_DAG_IDX[$1]+set}" ]] || return 1; echo "${_DAG_TITLES[${_DAG_IDX[$1]}]}"; }
dag_get_active()      { local i; for ((i=0; i<${#_DAG_IDS[@]}; i++)); do [[ "${_DAG_STATUSES[$i]}" == "in_progress" ]] && echo "${_DAG_IDS[$i]}"; done; return 0; }

# dag_deps_satisfied ID — true when every dep has status=done.
dag_deps_satisfied() {
    [[ -n "${_DAG_IDX[$1]+set}" ]] || return 1
    local deps="${_DAG_DEPS[${_DAG_IDX[$1]}]}" dep
    [[ -z "$deps" ]] && return 0
    while IFS=',' read -r dep; do
        dep="${dep#"${dep%%[![:space:]]*}"}"; dep="${dep%"${dep##*[![:space:]]}"}"
        [[ -z "$dep" ]] && continue
        [[ -n "${_DAG_IDX[$dep]+set}" ]] || { warn "dag_deps_satisfied: dep '$dep' of '$1' not in manifest"; return 1; }
        [[ "${_DAG_STATUSES[${_DAG_IDX[$dep]}]}" == "done" ]] || return 1
    done <<< "${deps//,/$'\n'}"
}

dag_get_frontier() {
    local i
    for ((i=0; i<${#_DAG_IDS[@]}; i++)); do
        [[ "${_DAG_STATUSES[$i]}" == "done" || "${_DAG_STATUSES[$i]}" == "split" ]] && continue
        dag_deps_satisfied "${_DAG_IDS[$i]}" && echo "${_DAG_IDS[$i]}"
    done
    return 0
}

# dag_find_next [CURRENT_ID] — next frontier ID after CURRENT_ID in manifest order.
dag_find_next() {
    local current="${1:-}" frontier id cur_idx
    frontier=$(dag_get_frontier) || true
    [[ -z "$frontier" ]] && return 1
    [[ -z "$current" ]] && { echo "$frontier" | head -1; return 0; }
    cur_idx="${_DAG_IDX[$current]:-}"
    [[ -z "$cur_idx" ]] && { echo "$frontier" | head -1; return 0; }
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        [[ "${_DAG_IDX[$id]}" -gt "$cur_idx" ]] && { echo "$id"; return 0; }
    done <<< "$frontier"
    echo "$frontier" | head -1
}

dag_id_to_number() { echo "${1#m}" | sed 's/^0*\([0-9]\)/\1/; s/\.0*\([0-9]\)/.\1/g'; }

dag_number_to_id() {
    local num="$1" main_num suffix i
    for ((i=0; i<${#_DAG_IDS[@]}; i++)); do
        [[ "$(dag_id_to_number "${_DAG_IDS[$i]}")" == "$num" ]] && { echo "${_DAG_IDS[$i]}"; return 0; }
    done
    main_num="${num%%.*}"; suffix="${num#"$main_num"}"
    printf "m%02d%s" "$main_num" "$suffix"
}

# --- Cross-process shims — defer to `tekhton dag <subcommand>` ---------------

validate_manifest() {
    [[ "$_DAG_LOADED" == true ]] || { warn "validate_manifest: no manifest loaded"; return 1; }
    command -v tekhton >/dev/null 2>&1 \
        || { warn "validate_manifest: tekhton binary not on PATH; install via 'make build'"; return 1; }
    tekhton dag validate --path "$(_dag_manifest_path)" --milestone-dir "$(_dag_milestone_dir)"
}

migrate_inline_milestones() {
    local claude_md="${1:-CLAUDE.md}" milestone_dir="${2:-$(_dag_milestone_dir)}"
    command -v tekhton >/dev/null 2>&1 \
        || { warn "migrate_inline_milestones: tekhton binary not on PATH"; return 1; }
    tekhton dag migrate --inline-claude-md "$claude_md" --milestone-dir "$milestone_dir"
}

_insert_milestone_pointer() {
    [[ -f "${1:-}" ]] || return 0
    command -v tekhton >/dev/null 2>&1 \
        || { warn "_insert_milestone_pointer: tekhton binary not on PATH"; return 0; }
    tekhton dag rewrite-pointer --inline-claude-md "$1"
}
