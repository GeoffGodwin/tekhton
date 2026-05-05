#!/usr/bin/env bash
# =============================================================================
# test_state_cli_exit_codes.sh — Bash-layer test for `tekhton state read`
# exit-code contract.
#
# Coverage gap (m03 Reviewer Report §Coverage Gaps):
#   "Exit-code distinction (1 = missing, 2 = corrupt) from `tekhton state read`
#    is only exercised via the Go unit test; no bash-layer test drives the CLI
#    and asserts the process exit code."
#
# Tests:
#   1. `tekhton state read` exits 1 when the state file is absent
#   2. `tekhton state read` exits 2 when the state file is corrupt JSON
#   3. `tekhton state read --field K` exits 1 when the field is empty/absent
#   4. `tekhton state read` exits 0 and prints JSON for a valid snapshot
#   5. `tekhton state read --field K` exits 0 and prints the value when present
#
# Skips gracefully when the tekhton binary is not available (no Go toolchain,
# no pre-built bin/).  CI runs after `make build` so the binary is present.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
# Locate or build the tekhton binary
# ---------------------------------------------------------------------------

_TEKHTON_BIN=""
if [[ -x "${TEKHTON_HOME}/bin/tekhton" ]]; then
    _TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"
elif command -v go >/dev/null 2>&1; then
    echo "tekhton binary not found; attempting 'make build'..."
    if (cd "$TEKHTON_HOME" && make build 2>&1); then
        _TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"
    else
        echo "make build failed — skipping CLI exit-code tests."
    fi
fi

if [[ -z "$_TEKHTON_BIN" ]]; then
    echo "SKIP: tekhton binary not available (run 'make build' first)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

FAIL=0

_pass() { echo "PASS: $*"; }
_fail() { echo "FAIL: $*"; FAIL=1; }

# _exit_code CMD... — runs the command and captures its exit code without
# triggering set -e; returns the code via stdout for assertion.
_exit_code() {
    local code=0
    "$@" >/dev/null 2>&1 || code=$?
    echo "$code"
}

# ---------------------------------------------------------------------------
# Test 1: missing file → exit 1
# ---------------------------------------------------------------------------

_code=$(_exit_code "$_TEKHTON_BIN" state read --path "${TMPDIR}/nonexistent.json")
if [[ "$_code" -eq 1 ]]; then
    _pass "missing file exits 1"
else
    _fail "missing file: expected exit 1, got $_code"
fi

# ---------------------------------------------------------------------------
# Test 2: corrupt file → exit 2
# ---------------------------------------------------------------------------

_CORRUPT="${TMPDIR}/corrupt.json"
printf '{not valid json}' > "$_CORRUPT"

_code=$(_exit_code "$_TEKHTON_BIN" state read --path "$_CORRUPT")
if [[ "$_code" -eq 2 ]]; then
    _pass "corrupt file exits 2"
else
    _fail "corrupt file: expected exit 2, got $_code"
fi

# ---------------------------------------------------------------------------
# Test 3: valid file, absent field → exit 1
# ---------------------------------------------------------------------------

_VALID="${TMPDIR}/valid_nofield.json"
# Write a minimal snapshot with no exit_stage.
"$_TEKHTON_BIN" state update --path "$_VALID" \
    --field "resume_task=test task" >/dev/null

_code=$(_exit_code "$_TEKHTON_BIN" state read --path "$_VALID" --field exit_stage)
if [[ "$_code" -eq 1 ]]; then
    _pass "absent field exits 1"
else
    _fail "absent field: expected exit 1, got $_code"
fi

# ---------------------------------------------------------------------------
# Test 4: valid file, full JSON read → exit 0
# ---------------------------------------------------------------------------

_FULL="${TMPDIR}/full.json"
"$_TEKHTON_BIN" state update --path "$_FULL" \
    --field "exit_stage=coder" \
    --field "exit_reason=blockers_remain" \
    --field "milestone_id=m03" >/dev/null

_output=$("$_TEKHTON_BIN" state read --path "$_FULL" 2>/dev/null)
_code=$?
if [[ "$_code" -ne 0 ]]; then
    _fail "valid JSON read: expected exit 0, got $_code"
else
    if printf '%s' "$_output" | grep -q '"exit_stage"'; then
        _pass "valid JSON read exits 0 with JSON output"
    else
        _fail "valid JSON read: JSON output missing exit_stage field: $_output"
    fi
fi

# ---------------------------------------------------------------------------
# Test 5: valid file, populated field → exit 0, correct value
# ---------------------------------------------------------------------------

_val=$("$_TEKHTON_BIN" state read --path "$_FULL" --field exit_stage 2>/dev/null)
_code=$?
if [[ "$_code" -ne 0 ]]; then
    _fail "populated field read: expected exit 0, got $_code"
elif [[ "$_val" != "coder" ]]; then
    _fail "populated field read: expected 'coder', got '$_val'"
else
    _pass "populated field read exits 0 with correct value"
fi

# Also verify an Extra-map field (milestone_id IS a first-class field here, use a true extra)
"$_TEKHTON_BIN" state update --path "$_FULL" \
    --field "human_mode=true" >/dev/null

_val=$("$_TEKHTON_BIN" state read --path "$_FULL" --field human_mode 2>/dev/null)
_code=$?
if [[ "$_code" -ne 0 ]]; then
    _fail "extra field read: expected exit 0, got $_code"
elif [[ "$_val" != "true" ]]; then
    _fail "extra field read: expected 'true', got '$_val'"
else
    _pass "extra field read exits 0 with correct value"
fi

# ---------------------------------------------------------------------------
# Test 6: clear → subsequent read exits 1
# ---------------------------------------------------------------------------

"$_TEKHTON_BIN" state clear --path "$_FULL" >/dev/null
_code=$(_exit_code "$_TEKHTON_BIN" state read --path "$_FULL")
if [[ "$_code" -eq 1 ]]; then
    _pass "post-clear read exits 1"
else
    _fail "post-clear read: expected exit 1, got $_code"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "state CLI exit-code tests passed"
