#!/usr/bin/env bash
# =============================================================================
# test_m65_prompt_tool_awareness.sh — End-to-end rendering tests for M65
#
# Verifies that all M65-modified prompt templates render correctly with
# SERENA_ACTIVE set (block appears) and unset (block absent), and that
# REPO_MAP_CONTENT conditional blocks include preference language.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== test_m65_prompt_tool_awareness.sh ==="

# --- Setup -------------------------------------------------------------------

export PROJECT_DIR="$TMPDIR_TEST"
export TEKHTON_HOME

# Source required libs
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"

# Set empty values for all template variables used by modified prompts to
# prevent render_prompt from leaving unresolved placeholders in output.
export PROJECT_NAME="TestProject"
export TASK="test task"
export TESTER_ROLE_FILE=".claude/agents/tester.md"
export CODER_ROLE_FILE=".claude/agents/coder.md"
export JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
export ARCHITECT_ROLE_FILE=".claude/agents/architect.md"
export TEST_CMD="bash tests/run_tests.sh"
export ARCHITECTURE_CONTENT=""
export ARCHITECTURE_LOG_CONTENT=""
export DRIFT_LOG_CONTENT=""
export DRIFT_OBSERVATION_COUNT="0"
export CONTINUATION_CONTEXT=""
export SECURITY_FIXES_BLOCK=""
export TEST_BASELINE_SUMMARY=""
export UI_PROJECT_DETECTED=""
export UI_TESTER_PATTERNS=""
export TESTER_UI_GUIDANCE=""
export JR_AFTER_SENIOR=""
export UI_VALIDATION_FAILURES_BLOCK=""
export INTAKE_HISTORY_BLOCK=""

# The complete list of M65-modified prompts that received SERENA_ACTIVE blocks
SERENA_PROMPTS=(
    "tester"
    "tester_resume"
    "coder_rework"
    "build_fix"
    "build_fix_minimal"
    "architect"
    "specialist_security"
    "specialist_performance"
    "specialist_api"
    "jr_coder"
    "architect_sr_rework"
    "architect_jr_rework"
)

# --- Test Group 1: SERENA_ACTIVE=true → block appears ----------------------

echo ""
echo "--- Group 1: SERENA_ACTIVE set → find_symbol appears ---"

export SERENA_ACTIVE="true"
export REPO_MAP_CONTENT=""

for prompt_name in "${SERENA_PROMPTS[@]}"; do
    result=$(render_prompt "$prompt_name" 2>/dev/null)
    if echo "$result" | grep -qF 'find_symbol'; then
        pass "${prompt_name}.prompt.md: SERENA block rendered when SERENA_ACTIVE=true"
    else
        fail "${prompt_name}.prompt.md: expected find_symbol in output with SERENA_ACTIVE=true"
    fi
done

# --- Test Group 2: SERENA_ACTIVE="" → block absent -------------------------

echo ""
echo "--- Group 2: SERENA_ACTIVE unset → find_symbol absent ---"

export SERENA_ACTIVE=""
export REPO_MAP_CONTENT=""

for prompt_name in "${SERENA_PROMPTS[@]}"; do
    result=$(render_prompt "$prompt_name" 2>/dev/null)
    if echo "$result" | grep -qF 'find_symbol'; then
        fail "${prompt_name}.prompt.md: find_symbol should be absent when SERENA_ACTIVE is empty"
    else
        pass "${prompt_name}.prompt.md: SERENA block correctly absent when SERENA_ACTIVE=''"
    fi
done

# --- Test Group 3: REPO_MAP_CONTENT → preference text ---------------------

echo ""
echo "--- Group 3: REPO_MAP_CONTENT populated → preference text appears ---"

export SERENA_ACTIVE=""
export REPO_MAP_CONTENT="## repo map content placeholder"

# tester.prompt.md: M65 added "Do NOT grep for class definitions" preference
result=$(render_prompt "tester" 2>/dev/null)
if echo "$result" | grep -qF 'grep for class definitions'; then
    pass "tester.prompt.md: repo map preference text appears when REPO_MAP_CONTENT is set"
else
    fail "tester.prompt.md: expected 'grep for class definitions' in rendered output"
fi

# tester.prompt.md: preference text for primary source
if echo "$result" | grep -qF 'primary source for identifying test targets'; then
    pass "tester.prompt.md: repo map primary source text appears when REPO_MAP_CONTENT is set"
else
    fail "tester.prompt.md: expected 'primary source for identifying test targets' in rendered output"
fi

# tester.prompt.md: the repo map content placeholder itself must appear
if echo "$result" | grep -qF 'repo map content placeholder'; then
    pass "tester.prompt.md: REPO_MAP_CONTENT variable is substituted into output"
else
    fail "tester.prompt.md: REPO_MAP_CONTENT variable was not substituted"
fi

# coder_rework.prompt.md: M65 added REPO_MAP_CONTENT block
result=$(render_prompt "coder_rework" 2>/dev/null)
if echo "$result" | grep -qF 'primary file discovery source'; then
    pass "coder_rework.prompt.md: repo map preference text appears when REPO_MAP_CONTENT is set"
else
    fail "coder_rework.prompt.md: expected 'primary file discovery source' in rendered output"
fi

# architect.prompt.md: had existing REPO_MAP_CONTENT block, M65 added preference language
result=$(render_prompt "architect" 2>/dev/null)
if echo "$result" | grep -qF 'primary file discovery source'; then
    pass "architect.prompt.md: repo map preference text appears when REPO_MAP_CONTENT is set"
else
    fail "architect.prompt.md: expected 'primary file discovery source' in rendered output"
fi

# --- Test Group 4: REPO_MAP_CONTENT absent → preference blocks stripped ---

echo ""
echo "--- Group 4: REPO_MAP_CONTENT empty → repo map blocks stripped ---"

export SERENA_ACTIVE=""
export REPO_MAP_CONTENT=""

result=$(render_prompt "tester" 2>/dev/null)
if echo "$result" | grep -qF 'grep for class definitions'; then
    fail "tester.prompt.md: repo map preference text should be absent when REPO_MAP_CONTENT is empty"
else
    pass "tester.prompt.md: repo map block correctly stripped when REPO_MAP_CONTENT=''"
fi

result=$(render_prompt "coder_rework" 2>/dev/null)
if echo "$result" | grep -qF 'primary file discovery source'; then
    fail "coder_rework.prompt.md: repo map preference text should be absent when REPO_MAP_CONTENT is empty"
else
    pass "coder_rework.prompt.md: repo map block correctly stripped when REPO_MAP_CONTENT=''"
fi

# --- Test Group 5: Balanced IF/ENDIF pairs in modified templates -----------

echo ""
echo "--- Group 5: Balanced {{IF:*}} / {{ENDIF:*}} pairs ---"

for prompt_name in "${SERENA_PROMPTS[@]}"; do
    template_file="${TEKHTON_HOME}/prompts/${prompt_name}.prompt.md"
    if_count=$(grep -c '{{IF:' "$template_file" 2>/dev/null || echo "0")
    endif_count=$(grep -c '{{ENDIF:' "$template_file" 2>/dev/null || echo "0")
    if [[ "$if_count" -eq "$endif_count" ]]; then
        pass "${prompt_name}.prompt.md: balanced IF/ENDIF pairs (${if_count})"
    else
        fail "${prompt_name}.prompt.md: unbalanced IF/ENDIF pairs (IF=${if_count} ENDIF=${endif_count})"
    fi
done

# Check tester_resume separately (not in SERENA_PROMPTS loop above for IF/ENDIF)
# Already covered since tester_resume is in SERENA_PROMPTS

# --- Test Group 6: Role-specific guidance in Tier 1 prompts ---------------

echo ""
echo "--- Group 6: Tier 1 role-specific Serena guidance ---"

export SERENA_ACTIVE="true"
export REPO_MAP_CONTENT=""

# tester.prompt.md should have tester-specific guidance about test assertions
result=$(render_prompt "tester" 2>/dev/null)
if echo "$result" | grep -qF 'verify constructor parameters'; then
    pass "tester.prompt.md: tester-specific Serena guidance present"
else
    fail "tester.prompt.md: expected tester-specific guidance 'verify constructor parameters'"
fi

# coder_rework.prompt.md should mention review blockers specifically
result=$(render_prompt "coder_rework" 2>/dev/null)
if echo "$result" | grep -qF 'review blockers'; then
    pass "coder_rework.prompt.md: role-specific guidance mentions review blockers"
else
    fail "coder_rework.prompt.md: expected 'review blockers' in Serena guidance"
fi

# build_fix.prompt.md should mention import paths
result=$(render_prompt "build_fix" 2>/dev/null)
if echo "$result" | grep -qF 'import paths'; then
    pass "build_fix.prompt.md: role-specific guidance mentions import paths"
else
    fail "build_fix.prompt.md: expected 'import paths' in Serena guidance"
fi

# --- Summary ----------------------------------------------------------------

echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
