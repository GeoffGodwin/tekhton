#!/usr/bin/env bash
# Test: Config loading from pipeline.conf
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Create a minimal project with pipeline.conf
PROJECT_DIR="$TMPDIR"
mkdir -p "${PROJECT_DIR}/.claude/agents"
mkdir -p "${PROJECT_DIR}/.claude/logs"

cat > "${PROJECT_DIR}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="Test Project"
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
SCOUT_MAX_TURNS=3
SEED_CONTRACTS_MAX_TURNS=5
MAX_REVIEW_CYCLES=2
ANALYZE_CMD="echo ok"
TEST_CMD="echo ok"
BUILD_CHECK_CMD=""
ANALYZE_ERROR_PATTERN="error"
BUILD_ERROR_PATTERN="ERROR"
PIPELINE_STATE_FILE=".claude/PIPELINE_STATE.md"
LOG_DIR=".claude/logs"
CODER_ROLE_FILE=".claude/agents/coder.md"
REVIEWER_ROLE_FILE=".claude/agents/reviewer.md"
TESTER_ROLE_FILE=".claude/agents/tester.md"
JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
ARCHITECTURE_FILE="ARCHITECTURE.md"
GLOSSARY_FILE=""
PROJECT_RULES_FILE="CLAUDE.md"
NOTES_FILTER_CATEGORIES="BUG|FEAT|POLISH"
EOF

# Create dummy agent files so validation passes
for role in coder reviewer tester jr-coder; do
    echo "# ${role}" > "${PROJECT_DIR}/.claude/agents/${role}.md"
done
echo "# Rules" > "${PROJECT_DIR}/CLAUDE.md"

export TEKHTON_HOME PROJECT_DIR

# Source common first (needed for log functions)
source "${TEKHTON_HOME}/lib/common.sh"

# Initialize globals that config.sh expects
NOTES_FILTER=""
MILESTONE_MODE=false

source "${TEKHTON_HOME}/lib/config.sh"

# Change to project dir (config validates files relative to CWD)
cd "$PROJECT_DIR"
load_config

# Verify values loaded
[ "$PROJECT_NAME" = "Test Project" ] || { echo "PROJECT_NAME mismatch: $PROJECT_NAME"; exit 1; }
[ "$CODER_MAX_TURNS" = "10" ] || { echo "CODER_MAX_TURNS mismatch: $CODER_MAX_TURNS"; exit 1; }
[ "$MAX_REVIEW_CYCLES" = "2" ] || { echo "MAX_REVIEW_CYCLES mismatch"; exit 1; }
[ "$ANALYZE_CMD" = "echo ok" ] || { echo "ANALYZE_CMD mismatch"; exit 1; }

echo "Config loading test passed"
