#!/usr/bin/env bash
# tests/output_format_fixtures.sh — shared fixtures for the
# tests/test_output_format*.sh suite.
#
# Sourced by test_output_format.sh and test_output_format_json.sh. Not
# auto-discovered by run_tests.sh (no `test_` prefix).
#
# Provides:
#   pass / fail / assert_eq / assert_contains / assert_not_contains
#   contains_ansi / strip_ansi
#   PASS / FAIL / FAILURES counters
#   summary_and_exit — prints results and exits with 0/1
#   sets _TUI_ACTIVE=false, COLUMNS=60, ANSI color globals
#   sources lib/output.sh and lib/output_format.sh

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Stubs for TUI dependencies (must be defined before sourcing output.sh) ───
_tui_notify()     { :; }
_tui_strip_ansi() { printf '%s' "${1:-}"; }

export _TUI_ACTIVE=false

export BOLD='\033[1m'
export NC='\033[0m'
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export CYAN='\033[0;36m'

export COLUMNS=60

# shellcheck source=../lib/output.sh
source "${TEKHTON_HOME}/lib/output.sh"
# shellcheck source=../lib/output_format.sh
source "${TEKHTON_HOME}/lib/output_format.sh"

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() {
    FAIL=$((FAIL + 1))
    FAILURES+=("$1")
    echo "  FAIL: $1"
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label (expected='${expected}' actual='${actual}')"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label (expected '${needle}' in: '${haystack}')"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label (unexpected '${needle}' found in: '${haystack}')"
    fi
}

contains_ansi() { [[ "$1" == *$'\033'* ]]; }
strip_ansi() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }

summary_and_exit() {
    echo
    echo "Results: Passed=${PASS} Failed=${FAIL}"
    if [[ "${#FAILURES[@]}" -gt 0 ]]; then
        echo "Failed tests:"
        local f
        for f in "${FAILURES[@]}"; do
            echo "  - $f"
        done
    fi
    [[ "$FAIL" -eq 0 ]]
}
