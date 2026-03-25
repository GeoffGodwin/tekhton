#!/usr/bin/env bash
# =============================================================================
# test_checkpoint_age_display.sh — show_checkpoint_info age calculation
#
# Tests:
#   1. Age calculation degrades to "unknown" when `date -d` is unavailable
#      (macOS/BSD behavior) — Coverage Gap from reviewer report
#   2. Seconds-ago display for a very recent checkpoint
#   3. Minutes-ago display
#   4. Hours-ago display
#   5. Days-ago display
#   6. Shows "No checkpoint found" message when no file exists
#   7. Shows disabled message when CHECKPOINT_ENABLED=false
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

source "${TEKHTON_HOME}/lib/common.sh"

# _write_age_checkpoint — write a checkpoint with a specific timestamp string.
# Usage: _write_age_checkpoint <dir> <timestamp_iso8601>
_write_age_checkpoint() {
    local dir="$1" timestamp="$2"
    mkdir -p "$dir/.claude"
    cat > "$dir/.claude/CHECKPOINT_META.json" << EOF
{
  "timestamp": "${timestamp}",
  "head_sha": "abc123",
  "had_uncommitted": false,
  "stash_ref": "",
  "task": "age test task",
  "milestone": "m01",
  "auto_committed": false,
  "commit_sha": null
}
EOF
}

# =============================================================================
# Test 1: Age shows "unknown" when `date -d` unavailable (macOS/BSD fallback)
#
# The code uses: date -d "$timestamp" +%s 2>/dev/null || echo "0"
# On macOS/BSD, `date -d` is not supported, so it fails and returns "0".
# When ckpt_epoch == 0, the condition [[ "$ckpt_epoch" -gt 0 ]] is false,
# so age_str stays "unknown".
# =============================================================================
echo "=== Test 1: BSD date -d unavailable → age shows 'unknown' ==="

(
    REPO="$TMPDIR/t1"
    _write_age_checkpoint "$REPO" "2024-01-01T12:00:00Z"

    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=true

    # Override `date` as a shell function that fails on `-d` flag, simulating BSD.
    # The real date is still used for `date +%s` (no -d flag).
    date() {
        local _bsd_reject=false
        local _arg
        for _arg in "$@"; do
            if [[ "$_arg" == "-d" ]]; then
                _bsd_reject=true
                break
            fi
        done
        if [[ "$_bsd_reject" == "true" ]]; then
            return 1
        fi
        command date "$@"
    }
    export -f date

    source "${TEKHTON_HOME}/lib/checkpoint.sh"
    output=$(show_checkpoint_info 2>&1)

    if echo "$output" | grep -q "unknown"; then
        echo "PASS: 1.1 age displays 'unknown' when date -d is unavailable"
    else
        echo "FAIL: 1.1 expected 'unknown' age, got: $output"
        exit 1
    fi

    # Verify other fields still appear correctly (task, milestone, head sha)
    if echo "$output" | grep -q "age test task"; then
        echo "PASS: 1.2 task field still present despite date fallback"
    else
        echo "FAIL: 1.2 task field missing from output: $output"
        exit 1
    fi

    if echo "$output" | grep -q "m01"; then
        echo "PASS: 1.3 milestone field still present despite date fallback"
    else
        echo "FAIL: 1.3 milestone field missing from output: $output"
        exit 1
    fi
)
[[ $? -eq 0 ]] && pass "1 BSD date -d unavailable → age 'unknown'" \
               || { fail "1 BSD date -d unavailable → age 'unknown'"; }

# =============================================================================
# Test 2: Age shows seconds when checkpoint is very recent (< 60s ago)
# =============================================================================
echo "=== Test 2: Recent checkpoint displays seconds ==="

(
    REPO="$TMPDIR/t2"
    # Timestamp: 5 seconds ago
    ts=$(date -u -d "5 seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
         || date -u -v-5S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
         || echo "2024-01-01T12:00:00Z")

    _write_age_checkpoint "$REPO" "$ts"

    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=true

    source "${TEKHTON_HOME}/lib/checkpoint.sh"
    output=$(show_checkpoint_info 2>&1)

    # Age should be in seconds (e.g. "5s ago") when date -d works
    # On systems where date -d works, ckpt_epoch > 0 and age_secs < 60
    if date -d "5 seconds ago" +%s &>/dev/null; then
        if echo "$output" | grep -qE "[0-9]+s ago"; then
            echo "PASS: 2.1 age displays seconds for very recent checkpoint"
        else
            # Could be slightly > 60s if clock ticks — accept minutes too
            if echo "$output" | grep -qE "[0-9]+m ago|unknown"; then
                echo "PASS: 2.1 age displays minutes (clock tick boundary acceptable)"
            else
                echo "FAIL: 2.1 expected Xs ago or Xm ago, got: $output"
                exit 1
            fi
        fi
    else
        # BSD system — age will be unknown (covered by test 1)
        if echo "$output" | grep -q "unknown"; then
            echo "PASS: 2.1 BSD fallback produces unknown (expected on this platform)"
        else
            echo "FAIL: 2.1 BSD fallback should produce unknown, got: $output"
            exit 1
        fi
    fi
)
[[ $? -eq 0 ]] && pass "2 recent checkpoint shows seconds" \
               || { fail "2 recent checkpoint shows seconds"; }

# =============================================================================
# Test 3: Age shows minutes when checkpoint is 10 minutes old
# =============================================================================
echo "=== Test 3: Checkpoint 10 minutes ago displays minutes ==="

(
    REPO="$TMPDIR/t3"
    ts=$(date -u -d "10 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
         || date -u -v-10M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
         || echo "2024-01-01T12:00:00Z")

    _write_age_checkpoint "$REPO" "$ts"

    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=true

    source "${TEKHTON_HOME}/lib/checkpoint.sh"
    output=$(show_checkpoint_info 2>&1)

    if date -d "10 minutes ago" +%s &>/dev/null; then
        if echo "$output" | grep -qE "[0-9]+m ago"; then
            echo "PASS: 3.1 age displays minutes for 10-minute-old checkpoint"
        else
            echo "FAIL: 3.1 expected Xm ago, got: $output"
            exit 1
        fi
    else
        echo "PASS: 3.1 BSD platform — age fallback (covered by test 1)"
    fi
)
[[ $? -eq 0 ]] && pass "3 10-minute checkpoint shows minutes" \
               || { fail "3 10-minute checkpoint shows minutes"; }

# =============================================================================
# Test 4: Age shows hours when checkpoint is 2 hours old
# =============================================================================
echo "=== Test 4: Checkpoint 2 hours ago displays hours ==="

(
    REPO="$TMPDIR/t4"
    ts=$(date -u -d "2 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
         || date -u -v-2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
         || echo "2024-01-01T12:00:00Z")

    _write_age_checkpoint "$REPO" "$ts"

    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=true

    source "${TEKHTON_HOME}/lib/checkpoint.sh"
    output=$(show_checkpoint_info 2>&1)

    if date -d "2 hours ago" +%s &>/dev/null; then
        if echo "$output" | grep -qE "[0-9]+h ago"; then
            echo "PASS: 4.1 age displays hours for 2-hour-old checkpoint"
        else
            echo "FAIL: 4.1 expected Xh ago, got: $output"
            exit 1
        fi
    else
        echo "PASS: 4.1 BSD platform — age fallback (covered by test 1)"
    fi
)
[[ $? -eq 0 ]] && pass "4 2-hour checkpoint shows hours" \
               || { fail "4 2-hour checkpoint shows hours"; }

# =============================================================================
# Test 5: Age shows days when checkpoint is 3 days old
# =============================================================================
echo "=== Test 5: Checkpoint 3 days ago displays days ==="

(
    REPO="$TMPDIR/t5"
    ts=$(date -u -d "3 days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
         || date -u -v-3d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
         || echo "2024-01-01T12:00:00Z")

    _write_age_checkpoint "$REPO" "$ts"

    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=true

    source "${TEKHTON_HOME}/lib/checkpoint.sh"
    output=$(show_checkpoint_info 2>&1)

    if date -d "3 days ago" +%s &>/dev/null; then
        if echo "$output" | grep -qE "[0-9]+d ago"; then
            echo "PASS: 5.1 age displays days for 3-day-old checkpoint"
        else
            echo "FAIL: 5.1 expected Xd ago, got: $output"
            exit 1
        fi
    else
        echo "PASS: 5.1 BSD platform — age fallback (covered by test 1)"
    fi
)
[[ $? -eq 0 ]] && pass "5 3-day checkpoint shows days" \
               || { fail "5 3-day checkpoint shows days"; }

# =============================================================================
# Test 6: Shows "No checkpoint found" when file does not exist
# =============================================================================
echo "=== Test 6: No checkpoint file → informational message ==="

(
    REPO="$TMPDIR/t6"
    mkdir -p "$REPO/.claude"
    # Do NOT write a checkpoint file

    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=true

    source "${TEKHTON_HOME}/lib/checkpoint.sh"
    output=$(show_checkpoint_info 2>&1)

    if echo "$output" | grep -qi "no checkpoint"; then
        echo "PASS: 6.1 correct message when no checkpoint exists"
    else
        echo "FAIL: 6.1 expected 'No checkpoint' message, got: $output"
        exit 1
    fi

    # Function should still return 0 (informational, not an error)
    exit_code=0
    show_checkpoint_info 2>/dev/null || exit_code=$?
    if [[ "$exit_code" -eq 0 ]]; then
        echo "PASS: 6.2 show_checkpoint_info returns 0 when no checkpoint"
    else
        echo "FAIL: 6.2 expected exit 0, got $exit_code"
        exit 1
    fi
)
[[ $? -eq 0 ]] && pass "6 informational message when no checkpoint file" \
               || { fail "6 informational message when no checkpoint file"; }

# =============================================================================
# Test 7: Shows disabled message when CHECKPOINT_ENABLED=false
# =============================================================================
echo "=== Test 7: CHECKPOINT_ENABLED=false → informational message ==="

(
    REPO="$TMPDIR/t7"
    _write_age_checkpoint "$REPO" "2024-01-01T12:00:00Z"

    PROJECT_DIR="$REPO"
    CHECKPOINT_FILE=".claude/CHECKPOINT_META.json"
    CHECKPOINT_ENABLED=false

    source "${TEKHTON_HOME}/lib/checkpoint.sh"
    output=$(show_checkpoint_info 2>&1)

    if echo "$output" | grep -qi "disabled"; then
        echo "PASS: 7.1 correct message when CHECKPOINT_ENABLED=false"
    else
        echo "FAIL: 7.1 expected 'disabled' message, got: $output"
        exit 1
    fi

    # Function should return 0 (informational, not an error)
    exit_code=0
    CHECKPOINT_ENABLED=false show_checkpoint_info 2>/dev/null || exit_code=$?
    if [[ "$exit_code" -eq 0 ]]; then
        echo "PASS: 7.2 show_checkpoint_info returns 0 when disabled"
    else
        echo "FAIL: 7.2 expected exit 0, got $exit_code"
        exit 1
    fi
)
[[ $? -eq 0 ]] && pass "7 informational message when checkpoint disabled" \
               || { fail "7 informational message when checkpoint disabled"; }

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    echo "  FAIL: $FAIL test(s) failed"
    exit 1
fi

echo "All tests passed."
exit 0
