#!/usr/bin/env bash
# Test: lib/context.sh — measure_context_size, check_context_budget, log_context_report
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Source the library under test (needs log/warn from common.sh)
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/context.sh"

# =============================================================================
# measure_context_size
# =============================================================================

echo "=== measure_context_size ==="

# Basic char count and token estimation for "hello world"
output=$(measure_context_size "hello world")
chars_line=$(echo "$output" | grep "^chars:")
tokens_line=$(echo "$output" | grep "^tokens:")

if [ -n "$chars_line" ]; then
    pass "measure_context_size returns a 'chars:' line"
else
    fail "measure_context_size missing 'chars:' line — output: ${output}"
fi

if [ -n "$tokens_line" ]; then
    pass "measure_context_size returns a 'tokens:' line"
else
    fail "measure_context_size missing 'tokens:' line — output: ${output}"
fi

# "hello world" is 11 characters
chars_val=$(echo "$chars_line" | awk '{print $2}')
if [ "$chars_val" -eq 11 ]; then
    pass "measure_context_size 'hello world' → 11 chars"
else
    fail "expected 11 chars, got '${chars_val}'"
fi

# 11 chars / 4 = 2.75 → rounds up to 3 tokens (ceiling division)
tokens_val=$(echo "$tokens_line" | awk '{print $2}')
if [ "$tokens_val" -eq 3 ]; then
    pass "measure_context_size 'hello world' → 3 tokens (ceiling of 11/4)"
else
    fail "expected 3 tokens, got '${tokens_val}'"
fi

# Empty string → 0 chars, 0 tokens
empty_output=$(measure_context_size "")
empty_chars=$(echo "$empty_output" | grep "^chars:" | awk '{print $2}')
empty_tokens=$(echo "$empty_output" | grep "^tokens:" | awk '{print $2}')
if [ "$empty_chars" -eq 0 ] && [ "$empty_tokens" -eq 0 ]; then
    pass "measure_context_size '' → 0 chars, 0 tokens"
else
    fail "empty string: expected 0/0, got chars=${empty_chars} tokens=${empty_tokens}"
fi

# Exact multiple: 8 chars / 4 = 2 tokens (no rounding needed)
exact_output=$(measure_context_size "12345678")
exact_chars=$(echo "$exact_output" | grep "^chars:" | awk '{print $2}')
exact_tokens=$(echo "$exact_output" | grep "^tokens:" | awk '{print $2}')
if [ "$exact_chars" -eq 8 ] && [ "$exact_tokens" -eq 2 ]; then
    pass "measure_context_size '12345678' → 8 chars, 2 tokens (exact multiple)"
else
    fail "exact multiple: expected 8 chars/2 tokens, got ${exact_chars}/${exact_tokens}"
fi

# CHARS_PER_TOKEN override: 1 char per token → 11 tokens for "hello world"
cpt_output=$(CHARS_PER_TOKEN=1 measure_context_size "hello world")
cpt_tokens=$(echo "$cpt_output" | grep "^tokens:" | awk '{print $2}')
if [ "$cpt_tokens" -eq 11 ]; then
    pass "CHARS_PER_TOKEN=1 override: 11 tokens for 'hello world'"
else
    fail "CHARS_PER_TOKEN=1 override: expected 11 tokens, got '${cpt_tokens}'"
fi

# CHARS_PER_TOKEN override: 2 → 11 chars → ceil(11/2) = 6 tokens
cpt2_output=$(CHARS_PER_TOKEN=2 measure_context_size "hello world")
cpt2_tokens=$(echo "$cpt2_output" | grep "^tokens:" | awk '{print $2}')
if [ "$cpt2_tokens" -eq 6 ]; then
    pass "CHARS_PER_TOKEN=2 override: 6 tokens for 'hello world'"
else
    fail "CHARS_PER_TOKEN=2 override: expected 6 tokens, got '${cpt2_tokens}'"
fi

# =============================================================================
# check_context_budget
# =============================================================================

echo
echo "=== check_context_budget ==="

# Under budget: 1000 tokens, sonnet (200k window), 50% budget = 100k budget
if (CONTEXT_BUDGET_PCT=50 check_context_budget 1000 "claude-sonnet"); then
    pass "1000 tokens is under 50% budget of 200k window"
else
    fail "1000 tokens should be under budget but returned non-zero"
fi

# Over budget: 150000 tokens, 50% of 200k = 100k budget
if ! (CONTEXT_BUDGET_PCT=50 check_context_budget 150000 "claude-sonnet"); then
    pass "150000 tokens is over 50% budget of 200k window"
else
    fail "150000 tokens should be over budget but returned zero"
fi

# Exactly at budget: 100000 tokens == 50% of 200k → not over
if (CONTEXT_BUDGET_PCT=50 check_context_budget 100000 "claude-sonnet"); then
    pass "100000 tokens at exactly 50% budget boundary → at-budget (not over)"
else
    fail "100000 tokens at 50% of 200k should be at-budget (not over)"
fi

# One over budget
if ! (CONTEXT_BUDGET_PCT=50 check_context_budget 100001 "claude-sonnet"); then
    pass "100001 tokens is 1 over 50% budget of 200k window"
else
    fail "100001 tokens should be over budget but returned zero"
fi

# Opus model also has 200k window
if (CONTEXT_BUDGET_PCT=50 check_context_budget 1000 "claude-opus"); then
    pass "1000 tokens is under budget for opus model"
else
    fail "1000 tokens should be under budget for opus"
fi

# CONTEXT_BUDGET_ENABLED=false always returns 0 (under budget)
if (CONTEXT_BUDGET_ENABLED=false check_context_budget 999999 "claude-sonnet"); then
    pass "CONTEXT_BUDGET_ENABLED=false always returns 0 regardless of tokens"
else
    fail "CONTEXT_BUDGET_ENABLED=false should return 0 but returned non-zero"
fi

# Budget percentage change: 10% of 200k = 20k; 25000 should be over
if ! (CONTEXT_BUDGET_PCT=10 check_context_budget 25000 "claude-sonnet"); then
    pass "25000 tokens is over 10% budget of 200k window"
else
    fail "25000 tokens should be over 10% budget"
fi

# Unknown model falls back to 200k default
if (CONTEXT_BUDGET_PCT=50 check_context_budget 1000 "claude-unknown-model"); then
    pass "unknown model defaults to 200k window for budget check"
else
    fail "unknown model should default to 200k and return under-budget"
fi

# =============================================================================
# _get_model_window
# =============================================================================

echo
echo "=== _get_model_window ==="

opus_window=$(_get_model_window "claude-opus-4")
if [ "$opus_window" -eq 200000 ]; then
    pass "_get_model_window opus → 200000"
else
    fail "expected 200000 for opus, got '${opus_window}'"
fi

sonnet_window=$(_get_model_window "claude-sonnet-4")
if [ "$sonnet_window" -eq 200000 ]; then
    pass "_get_model_window sonnet → 200000"
else
    fail "expected 200000 for sonnet, got '${sonnet_window}'"
fi

haiku_window=$(_get_model_window "claude-haiku-4")
if [ "$haiku_window" -eq 200000 ]; then
    pass "_get_model_window haiku → 200000"
else
    fail "expected 200000 for haiku, got '${haiku_window}'"
fi

unknown_window=$(_get_model_window "some-unknown-model")
if [ "$unknown_window" -eq 200000 ]; then
    pass "_get_model_window unknown → 200000 (conservative default)"
else
    fail "expected 200000 for unknown model, got '${unknown_window}'"
fi

# =============================================================================
# _add_context_component accumulator
# =============================================================================

echo
echo "=== _add_context_component accumulator ==="

# Empty component is skipped (chars stays 0)
_CONTEXT_TOTAL_CHARS=0
_CONTEXT_TOTAL_TOKENS=0
_CONTEXT_REPORT=""
_add_context_component "Empty Block" ""
if [ "$_CONTEXT_TOTAL_CHARS" -eq 0 ]; then
    pass "_add_context_component skips empty content (chars stays 0)"
else
    fail "_add_context_component should skip empty; chars=${_CONTEXT_TOTAL_CHARS}"
fi

# Non-empty content is counted
_CONTEXT_TOTAL_CHARS=0
_CONTEXT_TOTAL_TOKENS=0
_CONTEXT_REPORT=""
_add_context_component "Arch" "hello world"
if [ "$_CONTEXT_TOTAL_CHARS" -eq 11 ]; then
    pass "_add_context_component accumulates 11 chars for 'hello world'"
else
    fail "expected 11 chars after _add_context_component, got ${_CONTEXT_TOTAL_CHARS}"
fi
if [ "$_CONTEXT_TOTAL_TOKENS" -eq 3 ]; then
    pass "_add_context_component accumulates 3 tokens for 'hello world'"
else
    fail "expected 3 tokens after _add_context_component, got ${_CONTEXT_TOTAL_TOKENS}"
fi

# Multiple components accumulate
_CONTEXT_TOTAL_CHARS=0
_CONTEXT_TOTAL_TOKENS=0
_CONTEXT_REPORT=""
_add_context_component "Block A" "abcd"   # 4 chars, 1 token
_add_context_component "Block B" "efgh"   # 4 chars, 1 token
if [ "$_CONTEXT_TOTAL_CHARS" -eq 8 ]; then
    pass "_add_context_component accumulates across multiple calls (8 chars)"
else
    fail "expected 8 chars total, got ${_CONTEXT_TOTAL_CHARS}"
fi
if [ "$_CONTEXT_TOTAL_TOKENS" -eq 2 ]; then
    pass "_add_context_component accumulates tokens across multiple calls (2 tokens)"
else
    fail "expected 2 tokens total, got ${_CONTEXT_TOTAL_TOKENS}"
fi

# =============================================================================
# log_context_report — tested in a subshell to isolate from global state
# =============================================================================

echo
echo "=== log_context_report ==="

# log_context_report writes a context breakdown to the log (stdout)
report_output=$(
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/context.sh"
    _CONTEXT_TOTAL_CHARS=0
    _CONTEXT_TOTAL_TOKENS=0
    _CONTEXT_REPORT=""
    _add_context_component "Architecture" "hello world"
    CONTEXT_BUDGET_PCT=50
    CONTEXT_BUDGET_ENABLED=true
    log_context_report "coder" "claude-sonnet" 2>&1 || true
)

if echo "$report_output" | grep -q "coder context breakdown"; then
    pass "log_context_report writes stage context breakdown header"
else
    fail "log_context_report missing 'coder context breakdown' in output"
fi

if echo "$report_output" | grep -q "Architecture"; then
    pass "log_context_report includes component name 'Architecture' in breakdown"
else
    fail "log_context_report missing component name in output"
fi

if echo "$report_output" | grep -q "chars"; then
    pass "log_context_report includes char count in breakdown"
else
    fail "log_context_report missing char count in output"
fi

if echo "$report_output" | grep -q "tokens"; then
    pass "log_context_report includes token count in breakdown"
else
    fail "log_context_report missing token count in output"
fi

if echo "$report_output" | grep -q "Total:"; then
    pass "log_context_report includes Total summary line"
else
    fail "log_context_report missing 'Total:' line"
fi

# log_context_report resets accumulators after reporting
after_state=$(
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/context.sh"
    _CONTEXT_TOTAL_CHARS=0
    _CONTEXT_TOTAL_TOKENS=0
    _CONTEXT_REPORT=""
    _add_context_component "Test Block" "hello world"
    CONTEXT_BUDGET_PCT=50
    CONTEXT_BUDGET_ENABLED=true
    log_context_report "coder" "claude-sonnet" > /dev/null 2>&1 || true
    echo "chars=${_CONTEXT_TOTAL_CHARS} tokens=${_CONTEXT_TOTAL_TOKENS}"
)
if [ "$after_state" = "chars=0 tokens=0" ]; then
    pass "log_context_report resets _CONTEXT_TOTAL_CHARS and _CONTEXT_TOTAL_TOKENS to 0"
else
    fail "expected reset to 0/0 after log_context_report, got '${after_state}'"
fi

# log_context_report exports LAST_CONTEXT_TOKENS
last_tokens=$(
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/context.sh"
    _CONTEXT_TOTAL_CHARS=0
    _CONTEXT_TOTAL_TOKENS=0
    _CONTEXT_REPORT=""
    _add_context_component "Test Block" "hello world"  # 11 chars → 3 tokens
    CONTEXT_BUDGET_PCT=50
    CONTEXT_BUDGET_ENABLED=true
    log_context_report "coder" "claude-sonnet" > /dev/null 2>&1 || true
    echo "${LAST_CONTEXT_TOKENS:-unset}"
)
if [ "$last_tokens" = "3" ]; then
    pass "log_context_report exports LAST_CONTEXT_TOKENS=3"
else
    fail "expected LAST_CONTEXT_TOKENS=3, got '${last_tokens}'"
fi

# log_context_report with CONTEXT_BUDGET_ENABLED=false: skips logging, resets
disabled_state=$(
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/context.sh"
    _CONTEXT_TOTAL_CHARS=0
    _CONTEXT_TOTAL_TOKENS=0
    _CONTEXT_REPORT=""
    _add_context_component "Test Block" "hello world"
    CONTEXT_BUDGET_PCT=50
    CONTEXT_BUDGET_ENABLED=false
    log_context_report "coder" "claude-sonnet" > /dev/null 2>&1 || true
    echo "chars=${_CONTEXT_TOTAL_CHARS} tokens=${_CONTEXT_TOTAL_TOKENS}"
)
if [ "$disabled_state" = "chars=0 tokens=0" ]; then
    pass "log_context_report with CONTEXT_BUDGET_ENABLED=false resets accumulators"
else
    fail "expected reset when disabled, got '${disabled_state}'"
fi

# Over-budget triggers a warning in the output
over_budget_output=$(
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/context.sh"
    _CONTEXT_TOTAL_CHARS=0
    _CONTEXT_TOTAL_TOKENS=0
    _CONTEXT_REPORT=""
    # Add enough content to exceed 10% budget of 200k = 20k tokens
    # 100000 chars / 4 = 25000 tokens > 20000 budget
    big_content=$(printf '%0.s#' {1..100000})
    _add_context_component "Big Block" "$big_content"
    CONTEXT_BUDGET_PCT=10
    CONTEXT_BUDGET_ENABLED=true
    log_context_report "coder" "claude-sonnet" 2>&1 || true
)
if echo "$over_budget_output" | grep -q "Over budget"; then
    pass "log_context_report emits 'Over budget' warning when over budget threshold"
else
    fail "expected 'Over budget' warning in output, got: ${over_budget_output}"
fi

# =============================================================================
# Context config defaults (via lib/config.sh load_config)
# =============================================================================

echo
echo "=== Context config defaults ==="

budget_pct=$(
    unset CONTEXT_BUDGET_PCT 2>/dev/null || true
    unset CHARS_PER_TOKEN 2>/dev/null || true
    unset CONTEXT_BUDGET_ENABLED 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    PROJECT_DIR="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${PROJECT_DIR}'" EXIT
    mkdir -p "${PROJECT_DIR}/.claude"
    printf 'PROJECT_NAME=test\nCLAUDE_STANDARD_MODEL=claude-sonnet\nANALYZE_CMD=true\n' \
        > "${PROJECT_DIR}/.claude/pipeline.conf"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/config.sh"
    load_config
    echo "$CONTEXT_BUDGET_PCT"
)
if [ "$budget_pct" = "50" ]; then
    pass "default CONTEXT_BUDGET_PCT is 50"
else
    fail "expected CONTEXT_BUDGET_PCT=50, got '${budget_pct}'"
fi

chars_per_token=$(
    unset CONTEXT_BUDGET_PCT 2>/dev/null || true
    unset CHARS_PER_TOKEN 2>/dev/null || true
    unset CONTEXT_BUDGET_ENABLED 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    PROJECT_DIR="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${PROJECT_DIR}'" EXIT
    mkdir -p "${PROJECT_DIR}/.claude"
    printf 'PROJECT_NAME=test\nCLAUDE_STANDARD_MODEL=claude-sonnet\nANALYZE_CMD=true\n' \
        > "${PROJECT_DIR}/.claude/pipeline.conf"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/config.sh"
    load_config
    echo "$CHARS_PER_TOKEN"
)
if [ "$chars_per_token" = "4" ]; then
    pass "default CHARS_PER_TOKEN is 4"
else
    fail "expected CHARS_PER_TOKEN=4, got '${chars_per_token}'"
fi

budget_enabled=$(
    unset CONTEXT_BUDGET_PCT 2>/dev/null || true
    unset CHARS_PER_TOKEN 2>/dev/null || true
    unset CONTEXT_BUDGET_ENABLED 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    PROJECT_DIR="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${PROJECT_DIR}'" EXIT
    mkdir -p "${PROJECT_DIR}/.claude"
    printf 'PROJECT_NAME=test\nCLAUDE_STANDARD_MODEL=claude-sonnet\nANALYZE_CMD=true\n' \
        > "${PROJECT_DIR}/.claude/pipeline.conf"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/config.sh"
    load_config
    echo "$CONTEXT_BUDGET_ENABLED"
)
if [ "$budget_enabled" = "true" ]; then
    pass "default CONTEXT_BUDGET_ENABLED is true"
else
    fail "expected CONTEXT_BUDGET_ENABLED=true, got '${budget_enabled}'"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
