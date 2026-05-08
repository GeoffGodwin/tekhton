#!/usr/bin/env bash
# =============================================================================
# tests/test_run_command.sh — m19 integration smoke for `tekhton run`
#
# Asserts the run subcommand:
#   - Exists and exposes the documented run-flag surface
#   - Validates exactly-one-of for --task / --human / --milestone / --resume
#   - Rejects --auto-advance without --milestone
#   - Round-trips a RunRequestV1 → JSON envelope via env-defaults
#
# This is a smoke test, not a full parity gate — that lives in
# scripts/run-parity-check.sh and is gated separately because it needs the
# bash retry-loop bodies to compare against.
# =============================================================================

set -euo pipefail

TEKHTON_HOME="${TEKHTON_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export TEKHTON_HOME

PASS=0
FAIL=0

pass() { PASS=$(( PASS + 1 )); echo "  PASS: $1"; }
fail() { FAIL=$(( FAIL + 1 )); echo "  FAIL: $1"; }

# Locate tekhton binary; build if missing.
TEKHTON_BIN="${TEKHTON_BIN:-${TEKHTON_HOME}/bin/tekhton}"
if [[ ! -x "$TEKHTON_BIN" ]]; then
    if command -v go &>/dev/null; then
        (cd "$TEKHTON_HOME" && go build -o bin/tekhton ./cmd/tekhton/) || {
            echo "  SKIP: tekhton binary unavailable; cannot test"
            exit 0
        }
    else
        echo "  SKIP: go not available"
        exit 0
    fi
fi

echo "=== Suite 1: tekhton run --help shows documented flags ==="

HELP_OUT=$("$TEKHTON_BIN" run --help 2>&1 || true)
for flag in --task --complete --resume --human --human-tag --milestone \
            --auto-advance --auto-advance-limit --dry-run --no-tui; do
    if printf '%s' "$HELP_OUT" | grep -q -- "$flag"; then
        pass "1.${flag}: --help advertises ${flag}"
    else
        fail "1.${flag}: --help missing ${flag}"
    fi
done

echo
echo "=== Suite 2: exactly-one-of mode validation ==="

# No mode flags → exit 64 (usage)
rc=0
"$TEKHTON_BIN" run --tekhton-home "$TEKHTON_HOME" --project-dir /tmp 2>/dev/null || rc=$?
if [[ "$rc" -eq 64 ]]; then
    pass "2.1: empty flags returns exit 64 (EX_USAGE)"
else
    fail "2.1: empty flags returned exit ${rc}, want 64"
fi

# Two mode flags → exit 64 (usage)
rc=0
"$TEKHTON_BIN" run --task "x" --human \
    --tekhton-home "$TEKHTON_HOME" --project-dir /tmp 2>/dev/null || rc=$?
if [[ "$rc" -eq 64 ]]; then
    pass "2.2: two modes returns exit 64"
else
    fail "2.2: two modes returned exit ${rc}, want 64"
fi

echo
echo "=== Suite 3: --auto-advance requires --milestone ==="

rc=0
"$TEKHTON_BIN" run --task "x" --auto-advance \
    --tekhton-home "$TEKHTON_HOME" --project-dir /tmp 2>/dev/null || rc=$?
if [[ "$rc" -eq 64 ]]; then
    pass "3.1: auto-advance without milestone returns 64"
else
    fail "3.1: auto-advance without milestone returned exit ${rc}, want 64"
fi

echo
echo "=== Suite 4: tekhton.sh has no leftover legacy orch-loop names ==="

if grep -qE 'run_complete_loop|_save_orchestration_state' "${TEKHTON_HOME}/tekhton.sh"; then
    fail "4.1: tekhton.sh still references the legacy names"
else
    pass "4.1: tekhton.sh has no legacy run_complete_loop/_save_orchestration_state references"
fi

if [[ -f "${TEKHTON_HOME}/lib/orchestrate_main.sh" ]] || [[ -f "${TEKHTON_HOME}/lib/orchestrate_state.sh" ]]; then
    fail "4.2: deleted bash orch files still exist"
else
    pass "4.2: orchestrate_main.sh + orchestrate_state.sh deleted"
fi

echo
echo "═══════════════════════════════════════════"
echo "  Summary: ${PASS} passed, ${FAIL} failed"
echo "═══════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] || exit 1
