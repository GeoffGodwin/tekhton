#!/usr/bin/env bash
# tests/test_self_host_dry_run_gate.sh — validates the TEKHTON_SELF_HOST_DRY_RUN
# gating logic in scripts/self-host-check.sh (m20 coverage gap).
#
# The live smoke path requires a working claude CLI session and cannot run in
# unattended CI.  This test covers the two automatable branches:
#   1. Skip when TEKHTON_SELF_HOST_DRY_RUN is unset (default CI behavior).
#   2. Fail with a clear message when TEKHTON_SELF_HOST_DRY_RUN=1 but claude
#      is absent from PATH.
#
# MANUAL VERIFICATION REQUIRED: the live path
#   TEKHTON_SELF_HOST_DRY_RUN=1 + working `claude` CLI
# must be validated by hand before treating Phase 4 as fully closed. Run:
#   TEKHTON_SELF_HOST_DRY_RUN=1 bash scripts/self-host-check.sh

set -euo pipefail

# m22 Goal 6 un-guarded this test. The m21-closeout skip-guard block was
# removed alongside the gate fix in scripts/self-host-check.sh that moves
# the dry-run-skip check above the Go-toolchain pre-check. If this test
# regresses, the gate fix did — do not re-add the skip-guard; fix the
# gate.

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SELF_HOST_SCRIPT="${REPO_ROOT}/scripts/self-host-check.sh"

PASS=0
FAIL=0
fail_messages=""

_pass() { PASS=$(( PASS + 1 )); printf '\033[0;32mPASS\033[0m %s\n' "$1"; }
_fail() {
    FAIL=$(( FAIL + 1 ))
    printf '\033[0;31mFAIL\033[0m %s\n' "$1" >&2
    fail_messages+="$1"$'\n'
}

# --- Prerequisites -----------------------------------------------------------

if ! command -v go >/dev/null 2>&1; then
    printf 'SKIP test_self_host_dry_run_gate: go not found\n'
    exit 0
fi

if ! command -v make >/dev/null 2>&1; then
    printf 'SKIP test_self_host_dry_run_gate: make not found\n'
    exit 0
fi

# Ensure the Go binary is available (build it if not yet present).
if ! [[ -x "${REPO_ROOT}/bin/tekhton" ]]; then
    if ! (cd "$REPO_ROOT" && make build >/dev/null 2>&1); then
        printf 'SKIP test_self_host_dry_run_gate: make build failed\n'
        exit 0
    fi
fi

# Minimal PATH: includes go toolchain, system tools, and the tekhton binary
# but deliberately excludes user-local directories (e.g. ~/.local/bin) where
# the claude CLI typically lives. This reproduces the "CI runner without claude"
# environment described in the m20 reviewer coverage gap.
SAFE_PATH="${REPO_ROOT}/bin:/usr/local/go/bin:/usr/bin:/bin"

# Guard: if claude somehow lives in one of the safe system dirs, the
# "no claude" test below would fail for the wrong reason — skip it.
CLAUDE_IN_SAFE_PATH=false
if PATH="$SAFE_PATH" command -v claude >/dev/null 2>&1; then
    CLAUDE_IN_SAFE_PATH=true
fi

# ---------------------------------------------------------------------------
# Test 1: TEKHTON_SELF_HOST_DRY_RUN NOT set (default CI behavior).
# Expected: scripts/self-host-check.sh exits 0 AND logs the skip message.
# ---------------------------------------------------------------------------

# Explicitly unset so the test is isolated from any value inherited from the
# caller's environment (e.g. a developer running with TEKHTON_SELF_HOST_DRY_RUN=1).
unset TEKHTON_SELF_HOST_DRY_RUN

out1=""
rc1=0
out1=$(PATH="$SAFE_PATH" bash "$SELF_HOST_SCRIPT" 2>&1) || rc1=$?

if (( rc1 == 0 )); then
    _pass "gate-skip-exit-0: exits 0 when TEKHTON_SELF_HOST_DRY_RUN unset"
else
    _fail "gate-skip-exit-0: expected exit 0, got ${rc1}. output=${out1}"
fi

if echo "$out1" | grep -q "Skipping live --dry-run"; then
    _pass "gate-skip-message: 'Skipping live --dry-run' logged when env var unset"
else
    _fail "gate-skip-message: expected skip message absent. output=${out1}"
fi

# ---------------------------------------------------------------------------
# Test 2: TEKHTON_SELF_HOST_DRY_RUN=1, claude absent from PATH.
# Expected: scripts/self-host-check.sh exits non-zero AND prints the
# "claude CLI not found" message to stderr.
# ---------------------------------------------------------------------------

if [[ "$CLAUDE_IN_SAFE_PATH" == "true" ]]; then
    printf 'SKIP gate-no-claude-*: claude found in system PATH — cannot construct claude-absent env\n'
else
    out2=""
    rc2=0
    out2=$(PATH="$SAFE_PATH" TEKHTON_SELF_HOST_DRY_RUN=1 bash "$SELF_HOST_SCRIPT" 2>&1) || rc2=$?

    if (( rc2 != 0 )); then
        _pass "gate-no-claude-exit: exits non-zero when TEKHTON_SELF_HOST_DRY_RUN=1 but claude absent"
    else
        _fail "gate-no-claude-exit: expected non-zero exit when claude absent, got exit 0"
    fi

    if echo "$out2" | grep -q "claude CLI not found"; then
        _pass "gate-no-claude-message: 'claude CLI not found' message present"
    else
        _fail "gate-no-claude-message: expected 'claude CLI not found' absent. output=${out2}"
    fi
fi

# --- Note on the untestable live path ----------------------------------------
printf '\nNOTE: The live smoke path (TEKHTON_SELF_HOST_DRY_RUN=1 + working claude CLI)\n'
printf '      cannot be automated in CI. Validate manually with:\n'
printf '        TEKHTON_SELF_HOST_DRY_RUN=1 bash scripts/self-host-check.sh\n\n'

# --- Summary -----------------------------------------------------------------

printf '=== test_self_host_dry_run_gate: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf '\nFailures:\n%s' "$fail_messages" >&2
    exit 1
fi
exit 0
