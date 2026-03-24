#!/usr/bin/env bash
# Test: check_for_updates() respects TEKHTON_UPDATE_CHECK=false
# — must produce zero network calls and return 1
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

source "${TEKHTON_HOME}/lib/update_check.sh"

# Mock curl: if called, record it and fail so the test can detect the call
CURL_CALL_COUNT=0
curl() {
    CURL_CALL_COUNT=$(( CURL_CALL_COUNT + 1 ))
    echo "ERROR: curl was called when TEKHTON_UPDATE_CHECK=false" >&2
    return 1
}
export -f curl

# --- Test 1: check_for_updates returns 1 when disabled ---
TEKHTON_UPDATE_CHECK=false
TEKHTON_VERSION="1.0.0"
result=0
check_for_updates || result=$?

if [ "$result" -eq 1 ]; then
    echo "PASS: check_for_updates returns 1 when TEKHTON_UPDATE_CHECK=false"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
else
    echo "FAIL: check_for_updates returned $result, expected 1"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
fi

# --- Test 2: no network calls made ---
if [ "$CURL_CALL_COUNT" -eq 0 ]; then
    echo "PASS: no curl calls made when TEKHTON_UPDATE_CHECK=false"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
else
    echo "FAIL: curl was called $CURL_CALL_COUNT time(s) — expected 0"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
fi

# --- Test 3: --force flag is also blocked by the disable flag ---
CURL_CALL_COUNT=0
result=0
check_for_updates --force || result=$?

if [ "$result" -eq 1 ]; then
    echo "PASS: check_for_updates --force also returns 1 when disabled"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
else
    echo "FAIL: check_for_updates --force returned $result, expected 1"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
fi

if [ "$CURL_CALL_COUNT" -eq 0 ]; then
    echo "PASS: no curl calls on --force when TEKHTON_UPDATE_CHECK=false"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
else
    echo "FAIL: curl called $CURL_CALL_COUNT time(s) on --force despite being disabled"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
fi

# --- Test 4: produces no output when disabled ---
output=$(check_for_updates 2>&1 || true)
if [ -z "$output" ]; then
    echo "PASS: no output when check is disabled"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
else
    echo "FAIL: unexpected output: $output"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
fi

# --- Summary ---
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "All update_check disabled tests passed ($PASS_COUNT)"
    exit 0
else
    echo "FAIL: $FAIL_COUNT tests failed ($PASS_COUNT passed)"
    exit 1
fi
