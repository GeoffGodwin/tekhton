#!/usr/bin/env bash
# =============================================================================
# test_orchestrate_m12_acceptance.sh — M12 structural acceptance criteria
#
# Verifies the mechanical deliverables that M12 committed to:
#   AC#2  — orchestrate.sh is ≤ 60 lines and contains no recovery logic
#   AC#3  — six prohibited helper filenames are absent from the repo
#   AC#4  — _RWR_* globals are absent from lib/ and stages/
#   (bonus) orchestrate_main.sh global defaults initialize correctly on source
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc — expected '$expected', got '$actual'"
    fi
}

# =============================================================================
# Suite 1: AC#3 — Prohibited filenames absent from the repo
# =============================================================================
echo "=== Suite 1: Prohibited filenames (AC#3) ==="

PROHIBITED=(
    lib/orchestrate_helpers.sh
    lib/orchestrate_loop.sh
    lib/orchestrate_state_save.sh
    lib/orchestrate_recovery.sh
    lib/orchestrate_recovery_causal.sh
    lib/orchestrate_recovery_print.sh
)

for f in "${PROHIBITED[@]}"; do
    full="${TEKHTON_HOME}/${f}"
    if [ ! -f "$full" ]; then
        pass "1: ${f} absent"
    else
        fail "1: ${f} still exists (should have been deleted in M12)"
    fi
done

# Verify the renamed counterparts exist
EXPECTED_RENAMES=(
    lib/orchestrate_aux.sh
    lib/orchestrate_iteration.sh
    lib/orchestrate_state.sh
    lib/orchestrate_classify.sh
    lib/orchestrate_cause.sh
    lib/orchestrate_diagnose.sh
    lib/orchestrate_main.sh
)

for f in "${EXPECTED_RENAMES[@]}"; do
    full="${TEKHTON_HOME}/${f}"
    if [ -f "$full" ]; then
        pass "1: ${f} exists (rename target present)"
    else
        fail "1: ${f} missing (expected rename target)"
    fi
done

# =============================================================================
# Suite 2: AC#2 — orchestrate.sh ≤ 60 lines and no recovery logic
# =============================================================================
echo "=== Suite 2: orchestrate.sh shape (AC#2) ==="

ORCH_FILE="${TEKHTON_HOME}/lib/orchestrate.sh"
line_count=$(wc -l < "$ORCH_FILE")

if [ "$line_count" -le 60 ]; then
    pass "2.1: orchestrate.sh is ${line_count} lines (≤60)"
else
    fail "2.1: orchestrate.sh is ${line_count} lines (must be ≤60)"
fi

# No recovery dispatch logic: _classify_failure must not appear in non-comment lines
if grep -v '^\s*#' "$ORCH_FILE" | grep -q '_classify_failure'; then
    fail "2.2: orchestrate.sh contains _classify_failure outside comments (recovery logic leaked)"
else
    pass "2.2: orchestrate.sh has no _classify_failure in executable code"
fi

# No _dispatch_recovery_class in the shim either (outside comments)
if grep -v '^\s*#' "$ORCH_FILE" | grep -q '_dispatch_recovery_class'; then
    fail "2.3: orchestrate.sh contains _dispatch_recovery_class outside comments (recovery logic leaked)"
else
    pass "2.3: orchestrate.sh has no _dispatch_recovery_class in executable code"
fi

# The shim must source orchestrate_main.sh (the loop body must live there)
if grep -q 'orchestrate_main\.sh' "$ORCH_FILE"; then
    pass "2.4: orchestrate.sh sources orchestrate_main.sh"
else
    fail "2.4: orchestrate.sh does not source orchestrate_main.sh"
fi

# =============================================================================
# Suite 3: AC#4 — _RWR_* globals absent from lib/ and stages/
# =============================================================================
echo "=== Suite 3: _RWR_* globals absent (AC#4) ==="

rwr_hits=$(grep -r '_RWR_' \
    "${TEKHTON_HOME}/lib/" \
    "${TEKHTON_HOME}/stages/" 2>/dev/null \
    | grep -v '^\s*#' \
    | wc -l | tr -d '[:space:]' || echo "0")

if [ "$rwr_hits" -eq 0 ]; then
    pass "3.1: No _RWR_ references in lib/ or stages/"
else
    fail "3.1: Found ${rwr_hits} _RWR_ reference(s) in lib/ or stages/ (should be 0)"
    grep -r '_RWR_' \
        "${TEKHTON_HOME}/lib/" \
        "${TEKHTON_HOME}/stages/" 2>/dev/null \
        | grep -v '^\s*#' \
        | head -5 | sed 's/^/    /'
fi

# =============================================================================
# Suite 4: orchestrate_main.sh global defaults on source
# =============================================================================
echo "=== Suite 4: orchestrate_main.sh global initialization ==="

# Source just orchestrate_main.sh — it has no top-level source statements
# and guards all function calls with declare -f, so this is safe in isolation.
# Provide a minimal log() stub because it's exported (though not called at
# source time; guard is belt-and-suspenders).
log() { :; }
warn() { :; }
error() { :; }

source "${TEKHTON_HOME}/lib/orchestrate_main.sh"

assert_eq "4.1: _ORCH_ATTEMPT default is 0"                   "0"     "$_ORCH_ATTEMPT"
assert_eq "4.2: _ORCH_AGENT_CALLS default is 0"               "0"     "$_ORCH_AGENT_CALLS"
assert_eq "4.3: _ORCH_START_TIME default is 0"                "0"     "$_ORCH_START_TIME"
assert_eq "4.4: _ORCH_ELAPSED default is 0"                   "0"     "$_ORCH_ELAPSED"
assert_eq "4.5: _ORCH_ATTEMPT_LOG default is empty"           ""      "$_ORCH_ATTEMPT_LOG"
assert_eq "4.6: _ORCH_REVIEW_BUMPED default is false"         "false" "$_ORCH_REVIEW_BUMPED"
assert_eq "4.7: _ORCH_BUILD_RETRIED default is false"         "false" "$_ORCH_BUILD_RETRIED"
assert_eq "4.8: _ORCH_LAST_DIFF_HASH default is empty"        ""      "$_ORCH_LAST_DIFF_HASH"
assert_eq "4.9: _ORCH_NO_PROGRESS_COUNT default is 0"         "0"     "$_ORCH_NO_PROGRESS_COUNT"
assert_eq "4.10: _ORCH_AGENT_100_WARNED default is false"     "false" "$_ORCH_AGENT_100_WARNED"
assert_eq "4.11: _ORCH_CAUSAL_LOG_BASELINE default is 0"      "0"     "$_ORCH_CAUSAL_LOG_BASELINE"
assert_eq "4.12: _ORCH_LAST_ACCEPTANCE_HASH default is empty" ""      "$_ORCH_LAST_ACCEPTANCE_HASH"
assert_eq "4.13: _ORCH_IDENTICAL_ACCEPTANCE_COUNT default 0"  "0"     "$_ORCH_IDENTICAL_ACCEPTANCE_COUNT"
assert_eq "4.14: _ORCH_CONSECUTIVE_MAX_TURNS default is 0"    "0"     "$_ORCH_CONSECUTIVE_MAX_TURNS"
assert_eq "4.15: _ORCH_MAX_TURNS_STAGE default is empty"      ""      "$_ORCH_MAX_TURNS_STAGE"

# run_complete_loop must be defined after sourcing
if declare -f run_complete_loop &>/dev/null; then
    pass "4.16: run_complete_loop is defined after source"
else
    fail "4.16: run_complete_loop not defined after sourcing orchestrate_main.sh"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: $PASS  Failed: $FAIL"
echo "────────────────────────────────────────"

[ "$FAIL" -eq 0 ]
