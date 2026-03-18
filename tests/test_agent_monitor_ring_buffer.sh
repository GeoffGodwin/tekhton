#!/usr/bin/env bash
# =============================================================================
# test_agent_monitor_ring_buffer.sh — Ring buffer dump and API error flag handoff
#
# Tests:
#   1. agent_last_output.txt is written with ring buffer content after FIFO run
#   2. Ring buffer wraps correctly when > 50 lines are produced
#   3. agent_api_error.txt is created and read back when API error is detected
#   4. No agent_api_error.txt when no API error occurs
#   5. _API_ERROR_DETECTED / _API_ERROR_TYPE are set from the flag file
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

SESSION_DIR="${TMPDIR}/session"
mkdir -p "$SESSION_DIR"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

assert_file_exists() {
    local name="$1" file="$2"
    if [ ! -f "$file" ]; then
        echo "FAIL: $name — file '$file' not found"
        FAIL=1
    fi
}

assert_file_contains() {
    local name="$1" needle="$2" file="$3"
    if ! grep -qF "$needle" "$file" 2>/dev/null; then
        echo "FAIL: $name — '$needle' not found in '$file'"
        FAIL=1
    fi
}

assert_not_file_exists() {
    local name="$1" file="$2"
    if [ -f "$file" ]; then
        echo "FAIL: $name — file '$file' should not exist"
        FAIL=1
    fi
}

# =============================================================================
# Helper: Simulate the ring buffer logic from agent_monitor.sh
# This mirrors the subshell logic without requiring a real claude invocation.
# =============================================================================

simulate_ring_buffer() {
    local session_dir="$1"
    local -a lines=("${@:2}")

    declare -a _rb=()
    local _rb_idx=0
    local _rb_size=50
    local _stream_api_error=false
    local _stream_api_type=""

    for line in "${lines[@]}"; do
        _rb[$(( _rb_idx % _rb_size ))]="$line"
        _rb_idx=$(( _rb_idx + 1 ))
        # Real-time API error detection (same case pattern as agent_monitor.sh)
        case "$line" in
            *'"type":"error"'*|*'"status":'*429*|*'"status":'*500*|*'"status":'*502*|*'"status":'*503*|*'"status":'*529*|*server_error*|*rate_limit*|*overloaded*|*authentication_error*)
                if echo "$line" | grep -qE '"type"[[:space:]]*:[[:space:]]*"error"' 2>/dev/null; then
                    _stream_api_error=true
                    if echo "$line" | grep -qi 'rate_limit' 2>/dev/null; then
                        _stream_api_type="api_rate_limit"
                    elif echo "$line" | grep -qi 'overloaded' 2>/dev/null; then
                        _stream_api_type="api_overloaded"
                    elif echo "$line" | grep -qi 'server_error' 2>/dev/null; then
                        _stream_api_type="api_500"
                    elif echo "$line" | grep -qi 'authentication_error' 2>/dev/null; then
                        _stream_api_type="api_auth"
                    fi
                elif echo "$line" | grep -qE '"status"[[:space:]]*:[[:space:]]*(429|500|502|503|529)' 2>/dev/null; then
                    _stream_api_error=true
                    _stream_api_type="api_500"
                fi
                ;;
        esac
    done

    # Dump ring buffer (same logic as agent_monitor.sh lines 232–245)
    {
        local _rb_total=${#_rb[@]}
        if [[ "$_rb_total" -gt 0 ]]; then
            local _rb_start=0
            if [[ "$_rb_idx" -ge "$_rb_size" ]]; then
                _rb_start=$(( _rb_idx % _rb_size ))
            fi
            local _j=0
            while [[ "$_j" -lt "$_rb_total" ]]; do
                echo "${_rb[$(( (_rb_start + _j) % _rb_size ))]}"
                _j=$(( _j + 1 ))
            done
        fi
    } > "${session_dir}/agent_last_output.txt" 2>/dev/null || true

    # Write API error flag (same logic as agent_monitor.sh lines 248–250)
    if [[ "$_stream_api_error" = true ]]; then
        echo "$_stream_api_type" > "${session_dir}/agent_api_error.txt"
    fi
}

# =============================================================================
# Phase 1: Ring buffer produces agent_last_output.txt
# =============================================================================

dir1="${TMPDIR}/p1"
mkdir -p "$dir1"
simulate_ring_buffer "$dir1" "line one" "line two" "line three"

assert_file_exists     "1.1 agent_last_output.txt created" "${dir1}/agent_last_output.txt"
assert_file_contains   "1.2 first line in dump"            "line one"   "${dir1}/agent_last_output.txt"
assert_file_contains   "1.3 last line in dump"             "line three" "${dir1}/agent_last_output.txt"

# =============================================================================
# Phase 2: Ring buffer wraps — only last 50 lines preserved
# =============================================================================

dir2="${TMPDIR}/p2"
mkdir -p "$dir2"

# Build 60 lines: line001 … line060
lines=()
for i in $(seq -w 1 60); do
    lines+=("line${i}")
done

simulate_ring_buffer "$dir2" "${lines[@]}"

assert_file_exists "2.1 dump created for 60-line run" "${dir2}/agent_last_output.txt"

# Lines 1–10 should be gone (overwritten by wrap).
# seq -w 1 60 pads to 2 digits: line01..line60
if grep -qF "line01" "${dir2}/agent_last_output.txt" 2>/dev/null; then
    echo "FAIL: 2.2 line01 should not appear after 50-line wrap (60 lines total)"
    FAIL=1
fi

# Lines 11–60 should be present
assert_file_contains "2.3 line11 present (first in wrapped window)" "line11" "${dir2}/agent_last_output.txt"
assert_file_contains "2.4 line60 present (last line)"               "line60" "${dir2}/agent_last_output.txt"

# Dump should have exactly 50 lines
line_count=$(wc -l < "${dir2}/agent_last_output.txt" | tr -d '[:space:]')
assert_eq "2.5 dump has exactly 50 lines" "50" "$line_count"

# =============================================================================
# Phase 3: API error flag file written for rate limit
# =============================================================================

dir3="${TMPDIR}/p3"
mkdir -p "$dir3"
simulate_ring_buffer "$dir3" '{"type":"error","error":{"type":"rate_limit_error"}}'

assert_file_exists "3.1 agent_api_error.txt created for rate limit" "${dir3}/agent_api_error.txt"
api_type=$(cat "${dir3}/agent_api_error.txt")
assert_eq "3.2 api type is api_rate_limit" "api_rate_limit" "$api_type"

# =============================================================================
# Phase 4: API error flag for server_error
# =============================================================================

dir4="${TMPDIR}/p4"
mkdir -p "$dir4"
simulate_ring_buffer "$dir4" '{"type":"error","error":{"type":"server_error"}}'

assert_file_exists "4.1 agent_api_error.txt created for server_error" "${dir4}/agent_api_error.txt"
api_type=$(cat "${dir4}/agent_api_error.txt")
assert_eq "4.2 api type is api_500" "api_500" "$api_type"

# =============================================================================
# Phase 5: No API error flag when no error in stream
# =============================================================================

dir5="${TMPDIR}/p5"
mkdir -p "$dir5"
simulate_ring_buffer "$dir5" '{"type":"text","text":"All good"}' '{"num_turns":5}'

assert_not_file_exists "5.1 no agent_api_error.txt for clean run" "${dir5}/agent_api_error.txt"

# =============================================================================
# Phase 6: Parent reads flag file, sets _API_ERROR_DETECTED / _API_ERROR_TYPE
# Simulates the parent-side read logic from agent_monitor.sh lines 260–264
# =============================================================================

dir6="${TMPDIR}/p6"
mkdir -p "$dir6"
echo "api_overloaded" > "${dir6}/agent_api_error.txt"

_API_ERROR_DETECTED=false
_API_ERROR_TYPE=""

if [[ -f "${dir6}/agent_api_error.txt" ]]; then
    _API_ERROR_DETECTED=true
    _API_ERROR_TYPE=$(cat "${dir6}/agent_api_error.txt" 2>/dev/null || echo "api_unknown")
    rm -f "${dir6}/agent_api_error.txt"
fi

assert_eq "6.1 _API_ERROR_DETECTED set to true"        "true"          "$_API_ERROR_DETECTED"
assert_eq "6.2 _API_ERROR_TYPE set to api_overloaded"  "api_overloaded" "$_API_ERROR_TYPE"
assert_not_file_exists "6.3 flag file removed after read" "${dir6}/agent_api_error.txt"

# =============================================================================
# Phase 7: HTTP status-code-based detection (429)
# =============================================================================

dir7="${TMPDIR}/p7"
mkdir -p "$dir7"
simulate_ring_buffer "$dir7" '{"status": 429, "error": "rate limit"}'

assert_file_exists "7.1 agent_api_error.txt created for 429 status" "${dir7}/agent_api_error.txt"
api_type=$(cat "${dir7}/agent_api_error.txt")
assert_eq "7.2 api type is api_500 for HTTP status codes" "api_500" "$api_type"

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "agent_monitor ring buffer tests passed"
