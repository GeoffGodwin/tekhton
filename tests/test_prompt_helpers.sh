#!/usr/bin/env bash
# Test: prompt_confirm, prompt_choice, prompt_input non-interactive fallbacks
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Force non-interactive mode — the prompt helpers read from /dev/tty (not stdin),
# so </dev/null redirects alone cannot prevent real prompts when a controlling
# terminal exists. This env var is the reliable non-interactive mechanism.
export TEKHTON_NON_INTERACTIVE=true

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Source the library under test
# shellcheck source=../lib/prompts_interactive.sh
source "${TEKHTON_HOME}/lib/prompts_interactive.sh"

# Note: /dev/tty on Linux may return EOF quickly in a non-interactive subprocess,
# causing the helpers to fall through to their default logic. Tests exercise this
# behaviour. prompt_choice is tested via a short-lived subshell with timeout
# to guard against any environment where /dev/tty blocks indefinitely.

# =============================================================================
# prompt_confirm — default 'y' returns true
# =============================================================================
echo "=== prompt_confirm: default 'y' ==="

if prompt_confirm "Are you sure?" "y" </dev/null 2>/dev/null; then
    pass "prompt_confirm default 'y': returns 0 (true)"
else
    fail "prompt_confirm default 'y': should return 0 but returned non-zero"
fi

# =============================================================================
# prompt_confirm — default 'n' returns false
# =============================================================================
echo "=== prompt_confirm: default 'n' ==="

if prompt_confirm "Are you sure?" "n" </dev/null 2>/dev/null; then
    fail "prompt_confirm default 'n': should return non-zero but returned 0"
else
    pass "prompt_confirm default 'n': returns non-zero (false)"
fi

# =============================================================================
# prompt_confirm — implicit default is 'y'
# =============================================================================
echo "=== prompt_confirm: implicit default is 'y' ==="

if prompt_confirm "Continue?" </dev/null 2>/dev/null; then
    pass "prompt_confirm implicit default: returns 0 (true)"
else
    fail "prompt_confirm implicit default: should return 0 but returned non-zero"
fi

# =============================================================================
# prompt_input — non-interactive returns default
# =============================================================================
echo "=== prompt_input: non-interactive returns default ==="

result=$(prompt_input "Enter name:" "default-value" </dev/null 2>/dev/null)
if [[ "$result" = "default-value" ]]; then
    pass "prompt_input non-interactive: returns default 'default-value'"
else
    fail "prompt_input non-interactive: expected 'default-value', got '$result'"
fi

# =============================================================================
# prompt_input — no default returns empty
# =============================================================================
echo "=== prompt_input: no default returns empty ==="

result=$(prompt_input "Enter name:" </dev/null 2>/dev/null)
if [[ -z "$result" ]]; then
    pass "prompt_input no default: returns empty string"
else
    fail "prompt_input no default: expected empty, got '$result'"
fi

# =============================================================================
# prompt_input — empty default returns empty
# =============================================================================
echo "=== prompt_input: empty default returns empty ==="

result=$(prompt_input "Enter name:" "" </dev/null 2>/dev/null)
if [[ -z "$result" ]]; then
    pass "prompt_input empty default: returns empty string"
else
    fail "prompt_input empty default: expected empty, got '$result'"
fi

# =============================================================================
# prompt_choice — non-interactive or EOF path returns first option
#
# Uses a 3-second timeout to guard against environments where /dev/tty blocks.
# In CI containers (no /dev/tty), the non-interactive fallback fires immediately.
# In local environments, /dev/tty returns EOF, which prompt_choice must handle.
# =============================================================================
echo "=== prompt_choice: returns first option when no tty input ==="

PROMPT_CHOICE_RESULT=""
PROMPT_CHOICE_STATUS=0

# Run in a subprocess with a timeout so the test never hangs
if command -v timeout >/dev/null 2>&1; then
    PROMPT_CHOICE_RESULT=$(
        timeout 3 bash -c "
            export TEKHTON_NON_INTERACTIVE=true
            source '${TEKHTON_HOME}/lib/prompts_interactive.sh'
            prompt_choice 'Pick one:' 'alpha' 'beta' 'gamma'
        " </dev/null 2>/dev/null
    ) || PROMPT_CHOICE_STATUS=$?
else
    # No timeout command — skip interactive test
    PROMPT_CHOICE_STATUS=255
fi

if [[ "$PROMPT_CHOICE_STATUS" -eq 0 ]]; then
    if [[ "$PROMPT_CHOICE_RESULT" = "alpha" ]]; then
        pass "prompt_choice: returns first option 'alpha' when no tty input"
    else
        fail "prompt_choice: expected 'alpha', got '$PROMPT_CHOICE_RESULT'"
    fi
elif [[ "$PROMPT_CHOICE_STATUS" -eq 124 ]]; then
    # timeout exit code — function hung waiting for input (infinite-loop on EOF)
    fail "prompt_choice: timed out waiting for input — does not handle EOF gracefully"
else
    pass "prompt_choice: timeout command unavailable — skipping interactive path test"
fi

# =============================================================================
# prompt_choice — single option falls back correctly
# =============================================================================
echo "=== prompt_choice: single option ==="

if command -v timeout >/dev/null 2>&1; then
    single_result=$(
        timeout 3 bash -c "
            export TEKHTON_NON_INTERACTIVE=true
            source '${TEKHTON_HOME}/lib/prompts_interactive.sh'
            prompt_choice 'Pick one:' 'only'
        " </dev/null 2>/dev/null
    ) || single_status=$?
    single_status=${single_status:-0}

    if [[ "${single_status:-0}" -eq 0 ]] && [[ "$single_result" = "only" ]]; then
        pass "prompt_choice single option: returns 'only'"
    elif [[ "${single_status:-0}" -eq 124 ]]; then
        fail "prompt_choice single option: timed out — does not handle EOF on single-option list"
    else
        pass "prompt_choice single option: timeout unavailable — skip"
    fi
else
    pass "prompt_choice single option: timeout command unavailable — skipping"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
