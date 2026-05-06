#!/usr/bin/env bash
# =============================================================================
# test_rule_max_turns_consistency.sh — Verify _read_diagnostic_context surfaces
# exit_reason from a tekhton.state.v1 JSON envelope.
#
# m10: pre-cutover this test compared an awk-on-markdown reader against
# _read_diagnostic_context's awk reader to assert the duplicate paths agreed.
# The legacy markdown reader was retired with the bash supervisor; this test
# now verifies the single remaining JSON path emits the correct field.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/state.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/diagnose.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/diagnose_rules.sh"

FAIL=0

PROJECT_DIR="${TMPDIR}"
PIPELINE_STATE_FILE="${TMPDIR}/PIPELINE_STATE.json"
CAUSAL_LOG_FILE=""
export PROJECT_DIR PIPELINE_STATE_FILE CAUSAL_LOG_FILE

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $name — expected '${expected}', got '${actual}'"
        FAIL=1
    else
        echo "ok: $name"
    fi
}

# Test 1: exit_reason populated from JSON state.
cat > "$PIPELINE_STATE_FILE" << 'EOF'
{
  "proto":"tekhton.state.v1",
  "exit_stage":"coder",
  "resume_task":"Test task",
  "exit_reason":"AGENT_SCOPE: max_turns exceeded on attempt 1",
  "notes":"Attempt exhausted."
}
EOF

_read_diagnostic_context
assert_eq "Test 1: exit_reason read from JSON" \
    "AGENT_SCOPE: max_turns exceeded on attempt 1" "$_DIAG_EXIT_REASON"

# Test 2: missing exit_reason returns empty string.
cat > "$PIPELINE_STATE_FILE" << 'EOF'
{
  "proto":"tekhton.state.v1",
  "exit_stage":"coder",
  "resume_task":"Test task",
  "notes":"Some notes here."
}
EOF
_read_diagnostic_context
assert_eq "Test 2: missing exit_reason → empty string" "" "$_DIAG_EXIT_REASON"

# Test 3: exit_reason is a single field; embedded escapes survive a round-trip.
cat > "$PIPELINE_STATE_FILE" << 'EOF'
{
  "proto":"tekhton.state.v1",
  "exit_stage":"coder",
  "exit_reason":"AGENT_SCOPE: max_turns exceeded"
}
EOF
_read_diagnostic_context
assert_eq "Test 3: trimmed scalar value" \
    "AGENT_SCOPE: max_turns exceeded" "$_DIAG_EXIT_REASON"

if [[ "$_DIAG_EXIT_REASON" == *$'\n'* ]]; then
    echo "FAIL: Test 3b: Exit reason contains newline (should not)"
    FAIL=1
else
    echo "ok: Test 3b: Exit reason contains no newlines"
fi

if [[ "$FAIL" -ne 0 ]]; then
    echo "test_rule_max_turns_consistency: FAILED"
    exit 1
fi
echo "test_rule_max_turns_consistency: PASSED"
