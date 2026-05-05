#!/usr/bin/env bash
# =============================================================================
# test_state_error_classification.sh — Error classification block in state.sh
#
# m03 wedge: state file is JSON (tekhton.state.v1). Error classification
# fields land under `extra` keyed as `agent_error_*`; redacted output is in
# `agent_error_last_output`. Assertions look up JSON-shape values.
#
# Tests:
#   1. No agent_error_category when AGENT_ERROR_CATEGORY is unset
#   2. agent_error_category written when AGENT_ERROR_CATEGORY is set
#   3. "no output captured" fallback when agent_last_output.txt missing
#   4. Redaction path: API keys stripped from agent_last_output
#   5. Anthropic request ID preserved through redaction
#   6. Normal state fields still written alongside error classification
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export PROJECT_DIR TEKHTON_HOME

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/errors.sh"
source "${TEKHTON_HOME}/lib/state.sh"

mkdir -p "${TMPDIR}/.claude"
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
export PIPELINE_STATE_FILE

FAIL=0

assert_file_contains() {
    local name="$1" needle="$2" file="$3"
    if ! grep -qF "$needle" "$file" 2>/dev/null; then
        echo "FAIL: $name — '$needle' not found in '$file'"
        FAIL=1
    fi
}

assert_file_not_contains() {
    local name="$1" needle="$2" file="$3"
    if grep -qF "$needle" "$file" 2>/dev/null; then
        echo "FAIL: $name — '$needle' should NOT be in '$file'"
        FAIL=1
    fi
}

# =============================================================================
# Phase 1: No agent_error_category section when AGENT_ERROR_CATEGORY is unset.
# JSON: extras with empty values are omitted by the writer.
# =============================================================================

unset AGENT_ERROR_CATEGORY AGENT_ERROR_SUBCATEGORY AGENT_ERROR_TRANSIENT TEKHTON_SESSION_DIR 2>/dev/null || true

write_pipeline_state "tester" "normal_exit" "--start-at tester" "Phase 1 task" "" 2>/dev/null

# When no error is set, the agent_error_category extra key is empty and
# omitted entirely.
assert_file_not_contains "1.1 no agent_error_category extra in normal exit" \
    '"agent_error_category"' "$PIPELINE_STATE_FILE"

# =============================================================================
# Phase 2: error fields populate extras when AGENT_ERROR_CATEGORY is set.
# =============================================================================

export AGENT_ERROR_CATEGORY="UPSTREAM"
export AGENT_ERROR_SUBCATEGORY="api_500"
export AGENT_ERROR_TRANSIENT="true"

SESSION_DIR="${TMPDIR}/session2"
mkdir -p "$SESSION_DIR"
export TEKHTON_SESSION_DIR="$SESSION_DIR"

write_pipeline_state "coder" "upstream_error" "--start-at coder" "Phase 2 task" "" 2>/dev/null

assert_file_contains "2.1 agent_error_category"    '"agent_error_category":"UPSTREAM"'   "$PIPELINE_STATE_FILE"
assert_file_contains "2.2 agent_error_subcategory" '"agent_error_subcategory":"api_500"' "$PIPELINE_STATE_FILE"
assert_file_contains "2.3 agent_error_transient"   '"agent_error_transient":"true"'      "$PIPELINE_STATE_FILE"
assert_file_contains "2.4 recovery suggestion"     'server error' "$PIPELINE_STATE_FILE"

# =============================================================================
# Phase 3: "(no output captured)" fallback when agent_last_output.txt missing.
# =============================================================================

SESSION_DIR="${TMPDIR}/session3"
mkdir -p "$SESSION_DIR"
export TEKHTON_SESSION_DIR="$SESSION_DIR"

export AGENT_ERROR_CATEGORY="AGENT_SCOPE"
export AGENT_ERROR_SUBCATEGORY="null_run"
export AGENT_ERROR_TRANSIENT="false"

write_pipeline_state "coder" "null_run" "--start-at coder" "Phase 3 task" "" 2>/dev/null

assert_file_contains "3.1 no output captured fallback" "(no output captured)" "$PIPELINE_STATE_FILE"

# =============================================================================
# Phase 4: Redaction — API key stripped from agent_last_output.
# =============================================================================

SESSION_DIR="${TMPDIR}/session4"
mkdir -p "$SESSION_DIR"
export TEKHTON_SESSION_DIR="$SESSION_DIR"

cat > "${SESSION_DIR}/agent_last_output.txt" << 'EOF'
Request to Anthropic API
x-api-key: sk-ant-abc123SENSITIVE456
Response received successfully
EOF

export AGENT_ERROR_CATEGORY="UPSTREAM"
export AGENT_ERROR_SUBCATEGORY="api_auth"
export AGENT_ERROR_TRANSIENT="true"

write_pipeline_state "coder" "api_auth" "--start-at coder" "Phase 4 task" "" 2>/dev/null

assert_file_not_contains "4.1 raw API key is redacted" "sk-ant-abc123SENSITIVE456" "$PIPELINE_STATE_FILE"
assert_file_contains "4.2 REDACTED marker present" "REDACTED" "$PIPELINE_STATE_FILE"

# =============================================================================
# Phase 5: Anthropic request ID preserved through redaction.
# =============================================================================

SESSION_DIR="${TMPDIR}/session5"
mkdir -p "$SESSION_DIR"
export TEKHTON_SESSION_DIR="$SESSION_DIR"

cat > "${SESSION_DIR}/agent_last_output.txt" << 'EOF'
Anthropic-Request-Id: req_011CZ9DVbXYZsensitive
x-api-key: sk-ant-superSecret999
Error: rate limit exceeded
EOF

export AGENT_ERROR_CATEGORY="UPSTREAM"
export AGENT_ERROR_SUBCATEGORY="api_rate_limit"
export AGENT_ERROR_TRANSIENT="true"

write_pipeline_state "coder" "rate_limit" "--start-at coder" "Phase 5 task" "" 2>/dev/null

assert_file_contains "5.1 request ID preserved" "req_011CZ9DVbXYZsensitive" "$PIPELINE_STATE_FILE"
assert_file_not_contains "5.2 API key is redacted" "sk-ant-superSecret999" "$PIPELINE_STATE_FILE"

# =============================================================================
# Phase 6: Normal state fields still alongside error classification.
# =============================================================================

SESSION_DIR="${TMPDIR}/session6"
mkdir -p "$SESSION_DIR"
export TEKHTON_SESSION_DIR="$SESSION_DIR"

export AGENT_ERROR_CATEGORY="ENVIRONMENT"
export AGENT_ERROR_SUBCATEGORY="oom"
export AGENT_ERROR_TRANSIENT="true"

write_pipeline_state "review" "oom_kill" "--start-at review" "Phase 6 task" "oom notes" "7" 2>/dev/null

assert_file_contains "6.1 exit_stage in state"    '"exit_stage":"review"'      "$PIPELINE_STATE_FILE"
assert_file_contains "6.2 exit_reason in state"   '"exit_reason":"oom_kill"'   "$PIPELINE_STATE_FILE"
assert_file_contains "6.3 task in state"          "Phase 6 task"               "$PIPELINE_STATE_FILE"
assert_file_contains "6.4 milestone in state"     '"milestone_id":"7"'         "$PIPELINE_STATE_FILE"
assert_file_contains "6.5 error category in state" '"agent_error_category":"ENVIRONMENT"' "$PIPELINE_STATE_FILE"

# =============================================================================
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "state.sh error classification tests passed"
