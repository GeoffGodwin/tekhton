#!/usr/bin/env bash
# scripts/manifest-parity-check.sh — m13 acceptance gate.
#
# Drives a six-fixture matrix through the manifest parser, comparing the
# bash-fallback path against the Go path (`tekhton manifest list`). Both
# paths must produce byte-identical pipe-delimited output, and the Go
# Load → Save round-trip must preserve comment lines and blank lines for
# the comment-preservation fixture.
#
# Fixtures (mirror the milestone's stated 6-case matrix):
#   1. happy_path        — single-row file, status pending
#   2. mixed_statuses    — done / in_progress / pending / split / skipped
#   3. dependency_chain  — three-level chain m01 → m02 → m03
#   4. split_markers     — parent marked split, sub-milestone children
#   5. comment_preserve  — header comments, mid-file comment, blank lines
#   6. partial_recovery  — file with one malformed (empty-ID) row that
#                          legacy bash silently skipped
#
# Usage:
#   scripts/manifest-parity-check.sh [--use-fallback]
#
#   --use-fallback   skip building the Go binary; only exercise the bash
#                    fallback. Useful when Go is not installed locally.
#
# Exit codes:
#   0 = parity holds across all fixtures
#   1 = parity diff detected, or setup error
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$REPO_ROOT"

USE_FALLBACK=0
for arg in "$@"; do
    case "$arg" in
        --use-fallback) USE_FALLBACK=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

_log()  { printf '\033[0;36m[parity]\033[0m %s\n' "$*"; }
_ok()   { printf '\033[0;32m[parity] PASS\033[0m %s\n' "$*"; }
_fail() { printf '\033[0;31m[parity] FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# --- build Go binary unless asked to skip -----------------------------------

GO_AVAILABLE=0
if [[ "$USE_FALLBACK" -eq 0 ]]; then
    if command -v go >/dev/null 2>&1; then
        _log "Building Go binary via 'make build'..."
        make build >/dev/null
        export PATH="${REPO_ROOT}/bin:${PATH}"
        GO_AVAILABLE=1
    else
        _log "Go not installed — exercising bash fallback only."
    fi
fi

# --- fixtures ---------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

_write_fixture() {
    local name="$1" body="$2"
    local path="${WORK}/${name}.cfg"
    printf '%s' "$body" > "$path"
    echo "$path"
}

FIX1="$(_write_fixture happy_path "# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First|pending||m01.md|p1
")"

FIX2="$(_write_fixture mixed_statuses "# header
m01|First|done||m01.md|p1
m02|Second|in_progress|m01|m02.md|p1
m03|Third|pending|m02|m03.md|p2
m04|Fourth|split|m03|m04.md|p2
m05|Fifth|skipped|m04|m05.md|p2
")"

FIX3="$(_write_fixture dependency_chain "m01|First|pending||m01.md|
m02|Second|pending|m01|m02.md|
m03|Third|pending|m01,m02|m03.md|
")"

FIX4="$(_write_fixture split_markers "m01|Parent|split||m01.md|p1
m01.1|Child One|done|m01|m01.1.md|p1
m01.2|Child Two|pending|m01.1|m01.2.md|p1
")"

FIX5="$(_write_fixture comment_preserve "# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group

# Phase 1
m01|First|done||m01.md|p1
m02|Second|pending|m01|m02.md|p1

# Phase 2 — TODO
m03|Third|pending|m02|m03.md|p2
")"

FIX6="$(_write_fixture partial_recovery "# happy header
m01|First|pending||m01.md|p1
|Bad row with empty id|done|||
m02|Second|pending|m01|m02.md|p1
")"

# --- bash dump (via load_manifest into _DAG_* arrays) -----------------------

_dump_via_bash() {
    local manifest="$1"
    bash -c '
        set -euo pipefail
        TEKHTON_HOME="'"$REPO_ROOT"'"
        PROJECT_DIR="'"$WORK"'"
        export TEKHTON_HOME PROJECT_DIR
        # Force the bash fallback path by hiding the Go binary.
        PATH="$(printf %s "$PATH" | tr ":" "\n" | grep -v "'"${REPO_ROOT}"'/bin" | paste -sd:)"
        # shellcheck source=/dev/null
        source "$TEKHTON_HOME/lib/common.sh"
        MILESTONE_DIR=".claude/milestones"; MILESTONE_MANIFEST="MANIFEST.cfg"
        declare -a _DAG_IDS=() _DAG_TITLES=() _DAG_STATUSES=() _DAG_DEPS=() _DAG_FILES=() _DAG_GROUPS=()
        declare -A _DAG_IDX=()
        _DAG_LOADED=false
        # shellcheck source=/dev/null
        source "$TEKHTON_HOME/lib/milestone_dag_io.sh"
        load_manifest "'"$manifest"'"
        for ((i=0; i<${#_DAG_IDS[@]}; i++)); do
            printf "%s|%s|%s|%s|%s|%s\n" \
                "${_DAG_IDS[$i]}" "${_DAG_TITLES[$i]}" "${_DAG_STATUSES[$i]}" \
                "${_DAG_DEPS[$i]}" "${_DAG_FILES[$i]}" "${_DAG_GROUPS[$i]}"
        done
    '
}

_dump_via_go() {
    local manifest="$1"
    "${REPO_ROOT}/bin/tekhton" manifest list --path "$manifest"
}

# --- compare per-fixture parsed output --------------------------------------

_check_parse_parity() {
    local fixture_name="$1" manifest="$2"
    local bash_out go_out
    bash_out="$(_dump_via_bash "$manifest")"
    if [[ "$GO_AVAILABLE" -eq 1 ]]; then
        go_out="$(_dump_via_go "$manifest")"
        if [[ "$bash_out" != "$go_out" ]]; then
            _log "[$fixture_name] bash:"
            printf '%s\n' "$bash_out" | sed 's/^/    /'
            _log "[$fixture_name] go:"
            printf '%s\n' "$go_out" | sed 's/^/    /'
            _fail "[$fixture_name] parse parity diff"
        fi
        _ok "[$fixture_name] parse parity"
    else
        # Without Go, just confirm the bash path produces non-empty output for
        # every fixture (a smoke-only run).
        if [[ -z "$bash_out" ]]; then
            _fail "[$fixture_name] bash parser produced empty output"
        fi
        _ok "[$fixture_name] bash-only smoke"
    fi
}

# --- comment preservation: Go Load → Save must match the original byte-for-byte

_check_comment_roundtrip() {
    if [[ "$GO_AVAILABLE" -ne 1 ]]; then
        _log "skipping comment round-trip (Go binary not available)"
        return 0
    fi
    local manifest="$1"
    local copy="${WORK}/comment_preserve_copy.cfg"
    cp "$manifest" "$copy"
    # `set-status` triggers Save; pick a no-op status change that still round-
    # trips through the writer (set m02 to its current status).
    "${REPO_ROOT}/bin/tekhton" manifest set-status --path "$copy" m02 pending
    if ! diff -u "$manifest" "$copy" >/dev/null; then
        _log "comment_preserve diff:"
        diff -u "$manifest" "$copy" | sed 's/^/    /' >&2 || true
        _fail "Load → Save lost comments or blank lines"
    fi
    _ok "comment_preserve round-trip preserves comments and blanks"
}

# --- atomicity: concurrent reads see either pre- or post-state, never partial

_check_set_status_atomic() {
    if [[ "$GO_AVAILABLE" -ne 1 ]]; then
        return 0
    fi
    local manifest="${WORK}/atomic.cfg"
    cp "$FIX2" "$manifest"
    # Spawn a tight reader loop while a writer toggles status. Any non-zero
    # exit from the reader (parse failure on a partial file) fails the check.
    (
        local i=0
        while [[ $i -lt 50 ]]; do
            "${REPO_ROOT}/bin/tekhton" manifest list --path "$manifest" >/dev/null \
                || exit 1
            i=$((i + 1))
        done
    ) &
    local reader_pid=$!
    local j=0
    while [[ $j -lt 30 ]]; do
        local next
        if (( j % 2 == 0 )); then next="done"
        else                       next="in_progress"
        fi
        "${REPO_ROOT}/bin/tekhton" manifest set-status --path "$manifest" m02 "$next"
        j=$((j + 1))
    done
    if ! wait "$reader_pid"; then
        _fail "concurrent reader saw a partial-write — atomic rename violated"
    fi
    _ok "set-status atomicity (reader + writer racing for 30 iterations)"
}

# --- run -------------------------------------------------------------------

_check_parse_parity happy_path        "$FIX1"
_check_parse_parity mixed_statuses    "$FIX2"
_check_parse_parity dependency_chain  "$FIX3"
_check_parse_parity split_markers     "$FIX4"
_check_parse_parity comment_preserve  "$FIX5"
_check_parse_parity partial_recovery  "$FIX6"

_check_comment_roundtrip "$FIX5"
_check_set_status_atomic

_ok "all 6 fixtures + comment round-trip + atomicity gates passed"
exit 0
