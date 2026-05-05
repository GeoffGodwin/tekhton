#!/usr/bin/env bash
# scripts/test-sigint-resume.sh — m03 acceptance gate (AC #7).
#
# Drives a real lib/state.sh write, sends SIGTERM mid-update, and verifies
# the file is either fully present (rename completed before signal) or
# fully absent / fully prior (rename hadn't run) — never partial. Atomic
# rename is the contract the resume path depends on.
#
# Also exercises the round-trip: `tekhton state read` (or bash fallback)
# returns the same field values that were written, even after a
# kill -TERM during the write window.
#
# Usage:
#   scripts/test-sigint-resume.sh [--use-fallback]
#
# Exit codes:
#   0 = atomicity holds, resume readback works
#   1 = partial-file detected or resume readback failed
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

_log()  { printf '\033[0;36m[sigint-test]\033[0m %s\n' "$*"; }
_ok()   { printf '\033[0;32m[sigint-test] PASS\033[0m %s\n' "$*"; }
_fail() { printf '\033[0;31m[sigint-test] FAIL\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "$USE_FALLBACK" -eq 0 ]] && command -v go >/dev/null 2>&1; then
    _log "Building Go binary via 'make build'..."
    make build >/dev/null
    export PATH="${REPO_ROOT}/bin:${PATH}"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.claude/session"
export TEKHTON_HOME="$REPO_ROOT"
export PROJECT_DIR="$WORK"
export PIPELINE_STATE_FILE="$WORK/.claude/PIPELINE_STATE.md"
export TEKHTON_SESSION_DIR="$WORK/.claude/session"

# Write a baseline state, then attempt to overwrite it. If a SIGTERM
# arrives mid-overwrite, the prior file should still be intact.
_log "Writing baseline state..."
bash -c '
    # shellcheck source=/dev/null
    source "'"$REPO_ROOT"'/lib/common.sh"
    # shellcheck source=/dev/null
    source "'"$REPO_ROOT"'/lib/state.sh"
    log() { :; }; warn() { :; }
    write_pipeline_state "intake" "test_baseline" "--start-at intake" "Baseline task" ""
'

if [[ ! -s "$PIPELINE_STATE_FILE" ]]; then
    _fail "Baseline state file is empty after write."
fi
BASELINE_BYTES=$(wc -c < "$PIPELINE_STATE_FILE")
_log "Baseline state size: ${BASELINE_BYTES} bytes."

# Run a write loop that we interrupt mid-flight. We launch a backgrounded
# bash that performs N writes; after a short delay we SIGTERM it, then
# inspect the file. This race exercises the os.Rename atomicity guarantee.
_log "Spawning interruptible writer..."
(
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/state.sh"
    log() { :; }; warn() { :; }
    for _ in $(seq 1 50); do
        write_pipeline_state "coder" "loop_test" "--start-at coder" "Looped task" ""
    done
) &
WRITER_PID=$!

# Wait briefly so a few writes land, then SIGTERM. The point is to land
# inside the read-modify-write window for at least one iteration.
sleep 0.1
kill -TERM "$WRITER_PID" 2>/dev/null || true
wait "$WRITER_PID" 2>/dev/null || true

# After SIGTERM the file must exist and be either the baseline shape or a
# fully-completed loop write — never a half-written file.
if [[ ! -f "$PIPELINE_STATE_FILE" ]]; then
    _fail "State file vanished after SIGTERM — atomicity broken."
fi

# Read back the canonical resume fields. With Go binary on PATH this
# exercises `tekhton state read --field`; otherwise the bash fallback.
RESUME_TASK=$(bash -c '
    # shellcheck source=/dev/null
    source "'"$REPO_ROOT"'/lib/common.sh"
    # shellcheck source=/dev/null
    source "'"$REPO_ROOT"'/lib/state.sh"
    log() { :; }; warn() { :; }
    read_pipeline_state_field resume_task
')

if [[ -z "$RESUME_TASK" ]]; then
    _fail "Could not read resume_task after SIGTERM-interrupted writes."
fi

case "$RESUME_TASK" in
    "Baseline task"|"Looped task")
        _ok "Atomicity holds: post-SIGTERM resume_task = '${RESUME_TASK}'"
        exit 0
        ;;
    *)
        _fail "Unexpected resume_task value: '${RESUME_TASK}'"
        ;;
esac
