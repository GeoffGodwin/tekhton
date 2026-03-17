#!/usr/bin/env bash
# Test: CLAUDE_REVIEWER_MODEL default and override behavior in load_config()
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Helper: run load_config in a subshell and print requested variable value
# Usage: _get_var <var_name> <pipeline_conf_content>
_get_var() {
    local var_name="$1"
    local conf_content="$2"
    local proj_dir
    proj_dir=$(mktemp -d)
    mkdir -p "${proj_dir}/.claude/agents" "${proj_dir}/.claude/logs"
    for role in coder reviewer tester jr-coder; do
        echo "# ${role}" > "${proj_dir}/.claude/agents/${role}.md"
    done
    echo "# Rules" > "${proj_dir}/CLAUDE.md"
    printf '%s\n' "$conf_content" > "${proj_dir}/.claude/pipeline.conf"

    (
        # Unset model/config variables so env doesn't bleed in from the outer shell
        unset CLAUDE_STANDARD_MODEL CLAUDE_CODER_MODEL CLAUDE_JR_CODER_MODEL \
              CLAUDE_REVIEWER_MODEL CLAUDE_TESTER_MODEL CLAUDE_SCOUT_MODEL \
              CLAUDE_ARCHITECT_MODEL PIPELINE_STATE_FILE LOG_DIR
        export PROJECT_DIR="$proj_dir"
        export TEKHTON_HOME
        NOTES_FILTER=""
        MILESTONE_MODE=false
        source "${TEKHTON_HOME}/lib/common.sh"
        source "${TEKHTON_HOME}/lib/config.sh"
        cd "$proj_dir"
        load_config
        echo "${!var_name}"
    )

    rm -rf "$proj_dir"
}

# ============================================================
# Test 1: CLAUDE_REVIEWER_MODEL defaults to CLAUDE_STANDARD_MODEL when not set in conf
# ============================================================
echo "=== CLAUDE_REVIEWER_MODEL — defaults to CLAUDE_STANDARD_MODEL ==="

CONF='
PROJECT_NAME="Test Project"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo ok"
'

result=$(_get_var "CLAUDE_REVIEWER_MODEL" "$CONF")
if [[ "$result" == "claude-sonnet-4-6" ]]; then
    pass "CLAUDE_REVIEWER_MODEL defaults to CLAUDE_STANDARD_MODEL value"
else
    fail "Expected claude-sonnet-4-6, got: ${result:-<empty>}"
fi

# ============================================================
# Test 2: CLAUDE_REVIEWER_MODEL can be overridden in pipeline.conf
# ============================================================
echo "=== CLAUDE_REVIEWER_MODEL — explicit override in conf ==="

CONF='
PROJECT_NAME="Test Project"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
CLAUDE_REVIEWER_MODEL="claude-opus-4-6"
ANALYZE_CMD="echo ok"
'

result=$(_get_var "CLAUDE_REVIEWER_MODEL" "$CONF")
if [[ "$result" == "claude-opus-4-6" ]]; then
    pass "CLAUDE_REVIEWER_MODEL uses explicit pipeline.conf value when set"
else
    fail "Expected claude-opus-4-6, got: ${result:-<empty>}"
fi

# ============================================================
# Test 3: CLAUDE_REVIEWER_MODEL is non-empty after load_config
# ============================================================
echo "=== CLAUDE_REVIEWER_MODEL — always non-empty after load_config ==="

CONF='
PROJECT_NAME="Test Project"
CLAUDE_STANDARD_MODEL="claude-custom-model"
ANALYZE_CMD="echo ok"
'

result=$(_get_var "CLAUDE_REVIEWER_MODEL" "$CONF")
if [[ -n "$result" ]]; then
    pass "CLAUDE_REVIEWER_MODEL is non-empty after load_config"
else
    fail "CLAUDE_REVIEWER_MODEL should not be empty after load_config"
fi

# ============================================================
# Test 4: CLAUDE_REVIEWER_MODEL is consistent with CLAUDE_CODER_MODEL default
# ============================================================
echo "=== CLAUDE_REVIEWER_MODEL — consistent default with CLAUDE_CODER_MODEL ==="

CONF='
PROJECT_NAME="Test Project"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo ok"
'

reviewer_val=$(_get_var "CLAUDE_REVIEWER_MODEL" "$CONF")
coder_val=$(_get_var "CLAUDE_CODER_MODEL" "$CONF")

if [[ "$reviewer_val" == "$coder_val" ]]; then
    pass "CLAUDE_REVIEWER_MODEL and CLAUDE_CODER_MODEL both default to CLAUDE_STANDARD_MODEL (${reviewer_val})"
else
    fail "Inconsistent defaults: CLAUDE_REVIEWER_MODEL=${reviewer_val} CLAUDE_CODER_MODEL=${coder_val}"
fi

# ============================================================
# Test 5: CLAUDE_REVIEWER_MODEL different from CLAUDE_CODER_MODEL when individually set
# ============================================================
echo "=== CLAUDE_REVIEWER_MODEL — independent override from CLAUDE_CODER_MODEL ==="

CONF='
PROJECT_NAME="Test Project"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
CLAUDE_CODER_MODEL="claude-opus-4-6"
CLAUDE_REVIEWER_MODEL="claude-haiku-4-5"
ANALYZE_CMD="echo ok"
'

reviewer_val=$(_get_var "CLAUDE_REVIEWER_MODEL" "$CONF")
coder_val=$(_get_var "CLAUDE_CODER_MODEL" "$CONF")

if [[ "$reviewer_val" == "claude-haiku-4-5" && "$coder_val" == "claude-opus-4-6" ]]; then
    pass "CLAUDE_REVIEWER_MODEL (${reviewer_val}) and CLAUDE_CODER_MODEL (${coder_val}) can be set independently"
else
    fail "Expected reviewer=claude-haiku-4-5 coder=claude-opus-4-6, got reviewer=${reviewer_val} coder=${coder_val}"
fi

# ============================================================
# Summary
# ============================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
