#!/usr/bin/env bash
# =============================================================================
# no_state_leak.sh — Guard against tests that pollute project state.
#
# Filename intentionally does NOT start with `test_` so it is NOT picked up
# by tests/run_tests.sh's `test_*.sh` glob — this script is a gate that
# wraps the test suite, not a peer test of it. Invoked by the Makefile
# `dogfood` target and by operators investigating a suspected leak.
#
# Tests must not leave traces in the real project's persistent state files.
# Past leaks: test_m127_buildfix_routing.sh appended to
# .tekhton/HUMAN_ACTION_REQUIRED.md every test-suite run because the test
# stubbed the bash `append_human_action` function but the production code
# at stages/coder_buildfix.sh:132 used `tekhton drift human-action append`
# (the Go subcommand) — bypassing the stub. Five stale entries
# accumulated before an operator noticed.
#
# Gate: snapshot the hashes of every project-state file BEFORE running
# `bash tests/run_tests.sh`, snapshot again AFTER, fail loudly when any
# hash changed. The set of guarded files is small (HUMAN_ACTION_REQUIRED,
# DRIFT_LOG, NON_BLOCKING_LOG, ARCHITECTURE_LOG, MANIFEST.cfg) and
# matches what the production drift / human-action subsystems persist.
#
# Self-test note: this script is invoked by run_tests.sh itself, so it
# cannot recursively invoke run_tests.sh — instead it expects a
# pre-computed "before" snapshot file at $1 and produces an "after"
# snapshot to compare. The Makefile `dogfood` target wires this up.
# Standalone invocation (one-off operator use) self-runs the diff.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$TEKHTON_HOME}"

# Files the test suite must not mutate. Extend this list if a new
# persistent state file is added under .tekhton/ or .claude/.
GUARDED_FILES=(
    ".tekhton/HUMAN_ACTION_REQUIRED.md"
    ".tekhton/DRIFT_LOG.md"
    ".tekhton/NON_BLOCKING_LOG.md"
    ".tekhton/ARCHITECTURE_LOG.md"
    ".tekhton/SECURITY_NOTES.md"
    ".claude/milestones/MANIFEST.cfg"
)

# Compute a SHA256 over each file. Missing files hash to a literal
# "(absent)" sentinel — distinguishes "wasn't there to begin with" from
# "got deleted and recreated."
_snapshot() {
    local f hash
    for f in "${GUARDED_FILES[@]}"; do
        if [[ -f "${PROJECT_DIR}/${f}" ]]; then
            hash=$(sha256sum "${PROJECT_DIR}/${f}" | awk '{print $1}')
        else
            hash="(absent)"
        fi
        printf '%s %s\n' "$hash" "$f"
    done
}

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Mode 1 — invoked with --snapshot-only: just emit the snapshot to stdout.
# Used by the Makefile to capture the pre-test state.
if [[ "${1:-}" == "--snapshot-only" ]]; then
    _snapshot
    exit 0
fi

# Mode 2 — invoked with a path to a "before" snapshot: compare against
# the current state. Used as the post-test gate.
if [[ -f "${1:-}" ]]; then
    echo "=== Comparing post-test state to pre-test snapshot ==="
    BEFORE="$1"
    AFTER=$(mktemp)
    trap 'rm -f "$AFTER"' EXIT
    _snapshot > "$AFTER"
    if diff -u "$BEFORE" "$AFTER" >/dev/null 2>&1; then
        pass "no guarded project state file was mutated by the test suite"
    else
        fail "test suite mutated guarded project state — diff below"
        diff -u "$BEFORE" "$AFTER" >&2 || true
        echo
        echo "  Likely cause: a test invoked a production code path that"
        echo "  calls the real tekhton binary without overriding TEKHTON_BIN"
        echo "  or PROJECT_DIR. Look for 'tekhton drift', 'tekhton manifest'," >&2
        echo "  or 'tekhton finalize' invocations in the failing test." >&2
    fi
    echo
    echo "Results: ${PASS} passed, ${FAIL} failed"
    [[ "$FAIL" -gt 0 ]] && exit 1
    exit 0
fi

# Mode 3 — no args: self-runs the full diff cycle. Useful for operators
# investigating a suspected leak without going through the Makefile.
echo "=== Self-test: snapshot → run_tests.sh → compare ==="
BEFORE=$(mktemp)
AFTER=$(mktemp)
trap 'rm -f "$BEFORE" "$AFTER"' EXIT
_snapshot > "$BEFORE"
echo "  Pre-test snapshot captured ($(wc -l < "$BEFORE") files)"
bash "${TEKHTON_HOME}/tests/run_tests.sh" >/dev/null 2>&1 || true
_snapshot > "$AFTER"
if diff -u "$BEFORE" "$AFTER" >/dev/null 2>&1; then
    pass "no guarded project state file mutated"
else
    fail "test suite mutated guarded project state — diff below"
    diff -u "$BEFORE" "$AFTER" >&2
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -gt 0 ]] && exit 1
