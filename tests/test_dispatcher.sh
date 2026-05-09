#!/usr/bin/env bash
# tests/test_dispatcher.sh — m20 dispatcher routing test.
#
# Verifies that tekhton.sh dispatches every documented run-flag to
# `tekhton run` and every legacy flag to tekhton-legacy.sh. Run-flag
# detection must catch flags at any argv position, not just $1, so the
# tests cover both leading and trailing positions.
#
# This test exercises the dispatcher's decision tree only. The Go binary's
# argv is not actually executed — TEKHTON_DEBUG_DISPATCHER=1 prints the
# routing trace before the exec call, and the harness scrapes that trace.

set -u

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCHER="${REPO_ROOT}/tekhton.sh"

PASS=0
FAIL=0
fail_messages=""

_pass() { PASS=$(( PASS + 1 )); printf '\033[0;32mPASS\033[0m %s\n' "$1"; }
_fail() {
    FAIL=$(( FAIL + 1 ))
    printf '\033[0;31mFAIL\033[0m %s\n' "$1" >&2
    fail_messages+="$1"$'\n'
}

# Use a fake binary so the dispatcher's exec path doesn't trigger a real
# pipeline run (which would invoke checkpoint creation via the bash bridge
# and stash the working tree). The dispatcher only checks `-x` and prints
# its trace line BEFORE exec; the fake just echoes "FAKE_OK" so we know it
# was reached. Lives in a temp dir so the real bin/tekhton is untouched.
FAKE_BIN_DIR=$(mktemp -d)
trap 'rm -rf "$FAKE_BIN_DIR"' EXIT
printf '#!/bin/sh\necho FAKE_OK "$@"\nexit 0\n' > "$FAKE_BIN_DIR/tekhton"
chmod +x "$FAKE_BIN_DIR/tekhton"
export TEKHTON_BIN="$FAKE_BIN_DIR/tekhton"

# Stub tekhton-legacy.sh as well. Without this, _assert_legacy assertions
# `exec bash tekhton-legacy.sh "$@"` in the dispatcher and start REAL pipeline
# runs for bogus task strings ("implement feature x", --draft-milestones,
# --init, ...). Those orphaned pipelines linger in the background, write to
# .claude/logs/, and can stall the test suite for hours.
printf '#!/bin/sh\necho FAKE_LEGACY "$@"\nexit 0\n' > "$FAKE_BIN_DIR/tekhton-legacy.sh"
chmod +x "$FAKE_BIN_DIR/tekhton-legacy.sh"
export TEKHTON_LEGACY_BIN="$FAKE_BIN_DIR/tekhton-legacy.sh"

# Capture the dispatcher's routing trace line. The dispatcher prints
# `[tekhton-dispatcher] exec ...` to stderr immediately before exec.
_trace() {
    TEKHTON_DEBUG_DISPATCHER=1 \
        bash "$DISPATCHER" "$@" 2>&1 1>/dev/null \
        | grep -m1 '^\[tekhton-dispatcher\]' || true
}

_assert_run() {
    local label="$1"; shift
    local trace; trace="$(_trace "$@")"
    case "$trace" in
        *"$TEKHTON_BIN run "*) _pass "$label: routed to tekhton run" ;;
        *) _fail "$label: expected 'tekhton run', got: ${trace}" ;;
    esac
}

_assert_legacy() {
    local label="$1"; shift
    local trace; trace="$(_trace "$@")"
    case "$trace" in
        *"tekhton-legacy.sh"*) _pass "$label: routed to tekhton-legacy.sh" ;;
        *) _fail "$label: expected 'tekhton-legacy.sh', got: ${trace}" ;;
    esac
}

_assert_run_help() {
    local label="$1"; shift
    local trace; trace="$(_trace "$@")"
    case "$trace" in
        *"$TEKHTON_BIN run --help"*) _pass "$label: --help routed to tekhton run --help" ;;
        *) _fail "$label: expected 'tekhton run --help', got: ${trace}" ;;
    esac
}

# --- Run-flags route to tekhton run ----------------------------------------

_assert_run "run-task"          --task "demo"
_assert_run "run-complete"      --complete --task "demo"
_assert_run "run-resume"        --resume
_assert_run "run-human"         --human --human-tag BUG
_assert_run "run-milestone"     --milestone m21
_assert_run "run-auto-advance"  --auto-advance --milestone m21
_assert_run "run-dry-run"       --dry-run --task "demo"
_assert_run "run-no-tui"        --no-tui --task "demo"

# --- Run-flags appearing later in argv (regression guard) ------------------

_assert_run "trailing-task"     --no-tui "demo" --task "demo"
_assert_run "trailing-complete" --milestone m21 --complete
_assert_run "milestone-then-complete" --milestone m21 --complete --auto-advance

# --- --help routes to tekhton run --help -----------------------------------

_assert_run_help "help-flag"  --help
_assert_run_help "help-short" -h

# --- --version is handled in-dispatcher (does not route anywhere) ----------

_assert_version() {
    local label="$1"; shift
    local out
    out="$(bash "$DISPATCHER" "$@" 2>&1)"
    case "$out" in
        Tekhton*4.*) _pass "$label: --version prints in-dispatcher" ;;
        *) _fail "$label: expected 'Tekhton 4.x.y', got: ${out}" ;;
    esac
}
_assert_version "version-long"  --version
_assert_version "version-short" -v

# --- Legacy flags route to tekhton-legacy.sh -------------------------------

_assert_legacy "legacy-init"      --init
_assert_legacy "legacy-rescan"    --rescan
_assert_legacy "legacy-draft-ms"  --draft-milestones
_assert_legacy "legacy-report"    --report
_assert_legacy "legacy-status"    --status
_assert_legacy "legacy-metrics"   --metrics
_assert_legacy "legacy-migrate"   --migrate
_assert_legacy "legacy-health"    --health
_assert_legacy "legacy-rollback"  --rollback --check
_assert_legacy "legacy-note"      note --list
_assert_legacy "legacy-plan"      --plan
_assert_legacy "legacy-diagnose"  --diagnose
_assert_legacy "legacy-validate"  --validate
_assert_legacy "legacy-progress"  --progress
_assert_legacy "legacy-help-all"  --help --all

# --- Bare positional task strings stay legacy (Phase 5 ports the wrapper) --

_assert_legacy "legacy-bare-task" "implement feature x"

# --- Summary --------------------------------------------------------------

printf '\n=== test_dispatcher: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf '\nFailures:\n%s' "$fail_messages" >&2
    exit 1
fi
exit 0
