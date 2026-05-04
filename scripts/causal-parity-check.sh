#!/usr/bin/env bash
# scripts/causal-parity-check.sh — m02 acceptance gate.
#
# Drives a small fixture sequence of emit_event calls against two writers:
#   1. The pre-m02 bash writer, retrieved via `git show HEAD~1:lib/causality.sh`
#   2. The current m02 writer (Go via `tekhton causal …`, or the bash fallback
#      when the Go binary is not on PATH)
#
# Both runs produce CAUSAL_LOG.jsonl in isolated tmp dirs. The two files are
# diffed after stripping the per-event `ts` and the new `proto` field — both
# of which are expected to differ. Any other byte-level difference fails the
# parity check.
#
# Usage:
#   scripts/causal-parity-check.sh [--use-fallback]
#
#   --use-fallback   skip `make build`; rely on the bash fallback path of the
#                    HEAD shim. Useful when Go is not installed locally.
#
# Exit codes:
#   0 = parity holds
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

if [[ "$USE_FALLBACK" -eq 0 ]]; then
    if command -v go >/dev/null 2>&1; then
        _log "Building Go binary via 'make build'..."
        make build >/dev/null
        export PATH="${REPO_ROOT}/bin:${PATH}"
    else
        _log "Go not installed — using bash fallback for HEAD writer."
    fi
fi

# --- retrieve pre-m02 bash writer -------------------------------------------

PREV_LIB="$(mktemp)"
trap 'rm -f "$PREV_LIB"; rm -rf "$PREV_RUN" "$HEAD_RUN"' EXIT

if ! git show HEAD~1:lib/causality.sh > "$PREV_LIB" 2>/dev/null; then
    _fail "Cannot read HEAD~1:lib/causality.sh; ensure m02 is committed."
fi
_log "Loaded pre-m02 writer from HEAD~1:lib/causality.sh"

# --- fixture script ---------------------------------------------------------

PREV_RUN="$(mktemp -d)"
HEAD_RUN="$(mktemp -d)"

_run_fixture() {
    local out_dir="$1" causality_file="$2"
    local log_file="${out_dir}/CAUSAL_LOG.jsonl"
    bash -c '
        set -euo pipefail
        TEKHTON_HOME="'"$REPO_ROOT"'"
        export PATH="'"$PATH"'"
        # Use a deterministic timestamp so run_id is stable across the two passes.
        TIMESTAMP="20260101_000000"
        PROJECT_DIR="'"$out_dir"'"
        mkdir -p "$PROJECT_DIR/.claude/logs"
        CAUSAL_LOG_ENABLED=true
        CAUSAL_LOG_FILE="'"$log_file"'"
        CAUSAL_LOG_MAX_EVENTS=2000
        log() { :; }; warn() { :; }; error() { :; }; success() { :; }
        # common.sh provides _json_escape used by the bash fallback path.
        # shellcheck source=/dev/null
        source "$TEKHTON_HOME/lib/common.sh"
        # shellcheck source=/dev/null
        source "'"$causality_file"'"
        init_causal_log
        emit_event "pipeline_start" "pipeline" "fixture"      ""             ""                       "" >/dev/null
        emit_event "stage_start"    "coder"    "begin"        "pipeline.001" ""                       "" >/dev/null
        emit_event "stage_end"      "coder"    "done"         "coder.001"    ""                       "{\"files\":3}" >/dev/null
        emit_event "verdict"        "review"   "APPROVED"     "coder.002"    "{\"result\":\"APPROVED\"}" "" >/dev/null
    '
}

_log "Running fixture against pre-m02 writer..."
_run_fixture "$PREV_RUN" "$PREV_LIB"

_log "Running fixture against HEAD writer..."
_run_fixture "$HEAD_RUN" "${REPO_ROOT}/lib/causality.sh"

# --- normalize and diff -----------------------------------------------------

# Strip ts and proto fields. ts will always differ (RFC3339 second-precision
# clock); proto is the new envelope tag added in m02 and is expected to differ
# between writers (the pre-m02 writer never wrote it).
_normalize() {
    sed -E '
        s/"ts":"[^"]*"//g
        s/"proto":"[^"]*",//g
        s/,,/,/g
    ' "$1"
}

prev_norm="$(_normalize "${PREV_RUN}/CAUSAL_LOG.jsonl")"
head_norm="$(_normalize "${HEAD_RUN}/CAUSAL_LOG.jsonl")"

if [[ "$prev_norm" == "$head_norm" ]]; then
    _ok "Parity holds: writer output is byte-identical (modulo ts and proto)."
    exit 0
fi

_log "Parity diff detected — showing context:"
diff <(printf '%s' "$prev_norm") <(printf '%s' "$head_norm") | sed 's/^/    /' >&2 || true
_fail "Writer output differs — see above."
