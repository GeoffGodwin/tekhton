# shellcheck shell=bash
# errors.sh — m17 wedge shim. Bash names callers depend on; logic lives in
# `tekhton diagnose …` (internal/errors). See ARCHITECTURE.md for the full list.

_resolve_tekhton_bin_errors() {
    [[ -n "${TEKHTON_BIN:-}" ]] && { echo "${TEKHTON_BIN}"; return 0; }
    [[ -x "${TEKHTON_HOME}/bin/tekhton" ]] && { echo "${TEKHTON_HOME}/bin/tekhton"; return 0; }
    command -v tekhton >/dev/null 2>&1 && { echo "tekhton"; return 0; }
    return 1
}

classify_error() {
    local _bin _e="${1:-0}" _f="${4:-0}" _t="${5:-0}" _hs="${6:-0}"
    [[ "$_e" =~ ^-?[0-9]+$ ]] || _e=0
    [[ "$_f" =~ ^[0-9]+$ ]]   || _f=0
    [[ "$_t" =~ ^[0-9]+$ ]]   || _t=0
    [[ "$_hs" =~ ^[01]$ ]]    || _hs=0
    _bin=$(_resolve_tekhton_bin_errors) || { echo "PIPELINE|internal|false|tekhton binary not found"; return 0; }
    local _flags=() _se=() _so=()
    [[ "$_hs" -eq 1 ]] && _flags=(--has-summary)
    [[ -n "${2:-}" ]] && _se=(--stderr-file "$2")
    [[ -n "${3:-}" ]] && _so=(--output-file "$3")
    "$_bin" diagnose classify-agent --exit "$_e" --turns "$_t" --files "$_f" "${_se[@]}" "${_so[@]}" "${_flags[@]}"
}

is_transient() {
    local _bin; _bin=$(_resolve_tekhton_bin_errors) || return 1
    "$_bin" diagnose is-transient "${1:-}" "${2:-}" >/dev/null 2>&1
}

suggest_recovery() {
    local _bin
    _bin=$(_resolve_tekhton_bin_errors) || { echo "Check the run log for details."; return 0; }
    "$_bin" diagnose recovery "${1:-}" "${2:-}" "${3:-}"
}

redact_sensitive() {
    local _bin
    if ! _bin=$(_resolve_tekhton_bin_errors); then
        if [[ $# -gt 0 ]]; then printf '%s' "$1"; else cat; fi
        return 0
    fi
    if [[ $# -gt 0 ]]; then "$_bin" diagnose redact "$1"; else "$_bin" diagnose redact -; fi
}

classify_routing_decision() {
    local _bin token
    if ! _bin=$(_resolve_tekhton_bin_errors); then
        export LAST_BUILD_CLASSIFICATION="unknown_only"; echo "unknown_only"; return 0
    fi
    token=$(printf '%s' "${1:-}" | "$_bin" diagnose classify --mode routing -)
    export LAST_BUILD_CLASSIFICATION="$token"; printf '%s\n' "$token"
}

_ec_pipe()  { local _b; [[ -z "${2:-}" ]] && return 0; _b=$(_resolve_tekhton_bin_errors) || return 0; printf '%s' "$2" | "$_b" diagnose classify --mode "$1" -; }
_ec_probe() { local _b; [[ -z "${2:-}" ]] && return 1; _b=$(_resolve_tekhton_bin_errors) || return 1; printf '%s' "$2" | "$_b" diagnose classify "$1" - >/dev/null 2>&1; }

classify_build_errors_with_stats() { _ec_pipe stats "${1:-}"; }
classify_build_errors_all()        { _ec_pipe all   "${1:-}"; }
filter_code_errors()               { _ec_pipe filter-code "${1:-}"; }
has_explicit_code_errors()         { _ec_probe --has-code         "${1:-}"; }
has_only_noncode_errors()          { _ec_probe --has-only-noncode "${1:-}"; }
load_error_patterns() { :; }
get_pattern_count()   { echo 56; }
classify_build_error() {
    local rec
    [[ -z "${1:-}" ]] && { echo "code|code||Empty error input"; return 0; }
    rec=$(_ec_pipe all "$1")
    [[ -z "$rec" ]] && { echo "code|code||Unclassified build error"; return 0; }
    printf '%s\n' "$rec" | head -n1
}

annotate_build_errors() {
    local _bin; _bin=$(_resolve_tekhton_bin_errors) || return 0
    printf '%s' "${1:-}" | "$_bin" diagnose classify --mode annotate --stage "${2:-unknown}" -
}

# Pure-bash per-line filter — retained inline so per-line tests don't fork.
_FAILURE_TERM_PATTERN='error|failed|timeout|ECONNREFUSED|TS[0-9]+'
_NOISE_LINE_PATTERN='^[[:space:]]*(npm|pnpm|yarn)[[:space:]]+(warn|notice)|serving html report at|press[[:space:]]+ctrl[+-]?c[[:space:]]+to[[:space:]]+quit|audit[[:space:]]+hint|reporter:[[:space:]]+|progress:[[:space:]]*[0-9]+%'
_NOISE_LINE_NUMERIC='^[[:space:]]*\[[0-9]+/[0-9]+\]|^[[:space:]]*\([0-9]+/[0-9]+\)|^[[:space:]]*[0-9]+%[[:space:]]'
_is_non_diagnostic_line() {
    local line="$1" stripped _esc=$'\033'
    [[ -z "${line//[[:space:]]/}" ]] && return 0
    printf '%s' "$line" | grep -qiE "$_FAILURE_TERM_PATTERN" 2>/dev/null && return 1
    stripped=$(printf '%s' "$line" | sed -E "s/${_esc}\[[0-9;]*[a-zA-Z]//g")
    [[ -z "${stripped//[[:space:]]/}" ]] && return 0
    printf '%s' "$line" | grep -qiE -- "$_NOISE_LINE_PATTERN" 2>/dev/null && return 0
    printf '%s' "$line" | grep -qE "$_NOISE_LINE_NUMERIC" 2>/dev/null && return 0
    return 1
}
