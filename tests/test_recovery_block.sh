#!/usr/bin/env bash
# =============================================================================
# test_recovery_block.sh — Inline recovery block (M94)
#
# Tests _print_recovery_block() renders a WHAT HAPPENED / WHAT TO DO NEXT
# block with at least one complete, runnable tekhton command.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/orchestrate_classify.sh
source "${TEKHTON_HOME}/lib/orchestrate_classify.sh"

PASS=0
FAIL=0

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — missing '$needle'"
        echo "  ----- captured output -----"
        printf '%s\n' "$haystack" | sed 's/^/    /'
        echo "  ----- end -----"
        FAIL=$((FAIL + 1))
    fi
}

# =============================================================================
# Test 1: max_attempts block format + runnable resume command
# =============================================================================
echo "=== Test 1: max_attempts block format ==="

MAX_PIPELINE_ATTEMPTS=5
EFFECTIVE_CODER_MAX_TURNS=80
MILESTONE_MODE=true
output=$(_print_recovery_block \
    "max_attempts" \
    "Pipeline hit 5 consecutive failing attempts." \
    'tekhton --complete --milestone --start-at test "M94"' \
    "M94" 2>&1)

assert_contains "1.1 WHAT HAPPENED header present" "WHAT HAPPENED" "$output"
assert_contains "1.2 WHAT TO DO NEXT header present" "WHAT TO DO NEXT" "$output"
assert_contains "1.3 RESUME entry present" "RESUME" "$output"
assert_contains "1.4 runnable resume command present" \
    'tekhton --complete --milestone --start-at test "M94"' "$output"
assert_contains "1.5 MORE TURNS option surfaced for max_attempts" \
    "MORE TURNS" "$output"
assert_contains "1.6 bumped CODER_MAX_TURNS shown (80+40=120)" \
    "CODER_MAX_TURNS=120" "$output"
assert_contains "1.7 DIAGNOSE hint shown" "tekhton --diagnose" "$output"
assert_contains "1.8 outcome detail about 5 attempts rendered" \
    "5 consecutive failing attempts" "$output"

# =============================================================================
# Test 2: timeout outcome still emits runnable resume command
# =============================================================================
echo "=== Test 2: timeout block ==="

AUTONOMOUS_TIMEOUT=7200
output=$(_print_recovery_block \
    "timeout" \
    "" \
    'tekhton --complete --milestone "M94"' \
    "M94" 2>&1)

assert_contains "2.1 WHAT HAPPENED header present" "WHAT HAPPENED" "$output"
assert_contains "2.2 autonomous timeout detail rendered" \
    "autonomous timeout" "$output"
assert_contains "2.3 runnable resume command present" \
    'tekhton --complete --milestone "M94"' "$output"
assert_contains "2.4 DIAGNOSE hint shown" "tekhton --diagnose" "$output"

# =============================================================================
# Test 3: pre_existing_failure outcome surfaces DISABLE guidance
# =============================================================================
echo "=== Test 3: pre_existing_failure block ==="

output=$(_print_recovery_block \
    "pre_existing_failure" \
    "" \
    'tekhton --complete --milestone "M94"' \
    "M94" 2>&1)

assert_contains "3.1 detail mentions pre-existing test failures" \
    "Pre-existing test failures" "$output"
assert_contains "3.2 DISABLE guidance surfaced" "DISABLE" "$output"
assert_contains "3.3 PRE_RUN_CLEAN_ENABLED hint present" \
    "PRE_RUN_CLEAN_ENABLED=false" "$output"
assert_contains "3.4 runnable resume command present" \
    'tekhton --complete --milestone "M94"' "$output"

# =============================================================================
# Test 4: agent_cap outcome includes cap value and standard block structure
# =============================================================================
echo "=== Test 4: agent_cap block ==="

MAX_AUTONOMOUS_AGENT_CALLS=20
output=$(_print_recovery_block \
    "agent_cap" \
    "" \
    'tekhton --complete --milestone "M94"' \
    "M94" 2>&1)

assert_contains "4.1 WHAT HAPPENED header present" "WHAT HAPPENED" "$output"
assert_contains "4.2 WHAT TO DO NEXT header present" "WHAT TO DO NEXT" "$output"
assert_contains "4.3 agent-call cap detail rendered" \
    "max agent-call cap" "$output"
assert_contains "4.4 configured cap value shown" \
    "20" "$output"
assert_contains "4.5 RESUME entry present" "RESUME" "$output"
assert_contains "4.6 runnable resume command present" \
    'tekhton --complete --milestone "M94"' "$output"
assert_contains "4.7 DIAGNOSE hint shown" "tekhton --diagnose" "$output"

# agent_cap should NOT emit MORE TURNS or DISABLE guidance
if printf '%s' "$output" | grep -qF "MORE TURNS"; then
    echo "  FAIL: 4.8 agent_cap must not emit MORE TURNS"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: 4.8 agent_cap does not emit MORE TURNS"
    PASS=$((PASS + 1))
fi
if printf '%s' "$output" | grep -qF "DISABLE"; then
    echo "  FAIL: 4.9 agent_cap must not emit DISABLE"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: 4.9 agent_cap does not emit DISABLE"
    PASS=$((PASS + 1))
fi

# =============================================================================
# Test 5: unknown outcome falls back to provided detail
# =============================================================================
echo "=== Test 5: unknown outcome uses detail ==="

output=$(_print_recovery_block \
    "mystery_reason" \
    "Something unexpected happened in the pipeline." \
    'tekhton --complete "M94"' \
    "M94" 2>&1)

assert_contains "5.1 falls back to provided detail string" \
    "Something unexpected happened" "$output"
assert_contains "5.2 runnable resume command present" \
    'tekhton --complete "M94"' "$output"

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  recovery block tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All recovery block tests passed"
