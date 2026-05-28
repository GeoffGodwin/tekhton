#!/usr/bin/env bash
# =============================================================================
# test_drift_compat.sh — Regression for the m25 drift-port orphan.
#
# m25 deleted lib/drift_cleanup.sh which owned count_open_nonblocking_notes
# but left six bash callers unrewritten. The M28.1 dogfood run surfaced
# the gap as `count_open_nonblocking_notes: command not found` inside the
# eval'd run_stage_coder wrapper. lib/drift_compat.sh restores the
# function as a shim over `tekhton drift nonblocking count`.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stub bash logging so test output isn't polluted by TUI machinery.
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# shellcheck source=lib/drift_compat.sh
source "${TEKHTON_HOME}/lib/drift_compat.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then pass "$name"
    else fail "$name — want '${want}', got '${got}'"
    fi
}

# Stub tekhton binary that records its argv and returns canned output.
_make_stub() {
    local outcome="$1" payload="$2"
    cat > "$TMP/tekhton-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls.log"
case "$outcome" in
    success)  printf '%s\n' "$payload" ; exit 0 ;;
    fail)     exit 1 ;;
    garbage)  printf 'oh no not a number\n'; exit 0 ;;
esac
STUB
    chmod +x "$TMP/tekhton-stub"
}

echo "=== Suite 1: happy path — stub returns 38 ==="
_make_stub success 38
: > "$TMP/calls.log"
export TEKHTON_BIN="$TMP/tekhton-stub"
export PROJECT_DIR="$TMP"
result=$(count_open_nonblocking_notes)
assert_eq "1.1 count_open_nonblocking_notes returns 38" "38" "$result"
# Verify it invoked the correct subcommand + threaded --project-dir.
calls=$(cat "$TMP/calls.log")
if [[ "$calls" == *"drift nonblocking count"* ]]; then
    pass "1.2 invoked the drift nonblocking count subcommand"
else
    fail "1.2 wrong subcommand: $calls"
fi
if [[ "$calls" == *"--project-dir $TMP"* ]]; then
    pass "1.3 threaded --project-dir from PROJECT_DIR"
else
    fail "1.3 missing --project-dir: $calls"
fi

echo "=== Suite 2: degraded — TEKHTON_BIN missing returns 0 ==="
unset TEKHTON_BIN
PATH_BAK="$PATH"
export PATH="/nonexistent-dir"
result=$(count_open_nonblocking_notes)
assert_eq "2.1 missing binary returns 0" "0" "$result"
export PATH="$PATH_BAK"

echo "=== Suite 3: degraded — subcommand exits non-zero returns 0 ==="
_make_stub fail ""
export TEKHTON_BIN="$TMP/tekhton-stub"
result=$(count_open_nonblocking_notes)
assert_eq "3.1 failing subcommand returns 0 (no crash)" "0" "$result"

echo "=== Suite 4: degraded — non-numeric output returns 0 ==="
_make_stub garbage ""
export TEKHTON_BIN="$TMP/tekhton-stub"
result=$(count_open_nonblocking_notes)
assert_eq "4.1 non-numeric output returns 0" "0" "$result"

echo "=== Suite 5: real binary integration ==="
# Build the real binary if available; assert the count matches what
# `tekhton drift nonblocking count` returns directly.
REAL_BIN="${TEKHTON_HOME}/bin/tekhton"
if [[ -x "$REAL_BIN" ]]; then
    export TEKHTON_BIN="$REAL_BIN"
    export PROJECT_DIR="$TEKHTON_HOME"
    shim_count=$(count_open_nonblocking_notes)
    bin_count=$("$REAL_BIN" drift nonblocking count --project-dir "$TEKHTON_HOME")
    assert_eq "5.1 shim count matches real binary count" "$bin_count" "$shim_count"
else
    pass "5.1 skipped — bin/tekhton not built (run make build to enable)"
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
