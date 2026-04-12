#!/usr/bin/env bash
# Test: Drift detection config keys load with sensible defaults
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Create a minimal project with pipeline.conf (no drift keys set)
PROJECT_DIR="$TMPDIR"
mkdir -p "${PROJECT_DIR}/.claude/agents"
mkdir -p "${PROJECT_DIR}/.claude/logs"

cat > "${PROJECT_DIR}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="Drift Test Project"
PROJECT_DESCRIPTION="test"
REQUIRED_TOOLS="git"
CLAUDE_CODER_MODEL="claude-opus-4-6"
CLAUDE_JR_CODER_MODEL="claude-haiku-4-5"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
CLAUDE_TESTER_MODEL="claude-haiku-4-5"
CODER_MAX_TURNS=10
JR_CODER_MAX_TURNS=5
REVIEWER_MAX_TURNS=5
TESTER_MAX_TURNS=10
MAX_REVIEW_CYCLES=2
ANALYZE_CMD="echo ok"
TEST_CMD="echo ok"
PIPELINE_STATE_FILE=".claude/PIPELINE_STATE.md"
LOG_DIR=".claude/logs"
CODER_ROLE_FILE=".claude/agents/coder.md"
REVIEWER_ROLE_FILE=".claude/agents/reviewer.md"
TESTER_ROLE_FILE=".claude/agents/tester.md"
JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
PROJECT_RULES_FILE="CLAUDE.md"
EOF

for role in coder reviewer tester jr-coder; do
    echo "# ${role}" > "${PROJECT_DIR}/.claude/agents/${role}.md"
done
echo "# Rules" > "${PROJECT_DIR}/CLAUDE.md"

# Clear any environment variables that might leak from a prior pipeline run
# (declare -gx in _parse_config_file exports config values into the environment)
unset ARCHITECTURE_LOG_FILE DRIFT_LOG_FILE HUMAN_ACTION_FILE
unset DRIFT_OBSERVATION_THRESHOLD DRIFT_RUNS_SINCE_AUDIT_THRESHOLD DESIGN_FILE

# Source common + config
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/config.sh"

load_config

# --- Test 1: Defaults are set when not specified in pipeline.conf ---
FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

assert_eq "ARCHITECTURE_LOG_FILE default" ".tekhton/ARCHITECTURE_LOG.md" "$ARCHITECTURE_LOG_FILE"
assert_eq "DRIFT_LOG_FILE default" ".tekhton/DRIFT_LOG.md" "$DRIFT_LOG_FILE"
assert_eq "HUMAN_ACTION_FILE default" ".tekhton/HUMAN_ACTION_REQUIRED.md" "$HUMAN_ACTION_FILE"
assert_eq "DRIFT_OBSERVATION_THRESHOLD default" "8" "$DRIFT_OBSERVATION_THRESHOLD"
assert_eq "DRIFT_RUNS_SINCE_AUDIT_THRESHOLD default" "5" "$DRIFT_RUNS_SINCE_AUDIT_THRESHOLD"
assert_eq "DESIGN_FILE default" ".tekhton/DESIGN.md" "$DESIGN_FILE"

# --- Test 2: Custom values override defaults ---
cat >> "${PROJECT_DIR}/.claude/pipeline.conf" << 'EOF'
ARCHITECTURE_LOG_FILE="ADL.md"
DRIFT_LOG_FILE="MY_DRIFT.md"
HUMAN_ACTION_FILE="ACTIONS.md"
DRIFT_OBSERVATION_THRESHOLD=15
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=10
DESIGN_FILE="docs/design.md"
EOF

# Clear variables before reloading so each test starts from a clean slate.
# Without this, a future Test 3 re-verifying defaults would see stale values
# from Test 2's pipeline.conf (same class of bug as the original unset fix).
unset ARCHITECTURE_LOG_FILE DRIFT_LOG_FILE HUMAN_ACTION_FILE
unset DRIFT_OBSERVATION_THRESHOLD DRIFT_RUNS_SINCE_AUDIT_THRESHOLD DESIGN_FILE

# Reload config with custom values
load_config

assert_eq "ARCHITECTURE_LOG_FILE custom" "ADL.md" "$ARCHITECTURE_LOG_FILE"
assert_eq "DRIFT_LOG_FILE custom" "MY_DRIFT.md" "$DRIFT_LOG_FILE"
assert_eq "HUMAN_ACTION_FILE custom" "ACTIONS.md" "$HUMAN_ACTION_FILE"
assert_eq "DRIFT_OBSERVATION_THRESHOLD custom" "15" "$DRIFT_OBSERVATION_THRESHOLD"
assert_eq "DRIFT_RUNS_SINCE_AUDIT_THRESHOLD custom" "10" "$DRIFT_RUNS_SINCE_AUDIT_THRESHOLD"
assert_eq "DESIGN_FILE custom" "docs/design.md" "$DESIGN_FILE"

if [ "$FAIL" -eq 0 ]; then
    echo "All drift config tests passed."
else
    exit 1
fi
