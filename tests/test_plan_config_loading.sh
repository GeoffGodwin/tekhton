#!/usr/bin/env bash
# Test: Planning config loading from pipeline.conf
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Test 1: Load defaults when no pipeline.conf exists
mkdir -p "${PROJECT_DIR}/.claude"
# Unset any pre-existing config vars
unset PLAN_INTERVIEW_MODEL PLAN_INTERVIEW_MAX_TURNS PLAN_GENERATION_MODEL PLAN_GENERATION_MAX_TURNS CLAUDE_PLAN_MODEL 2>/dev/null || true
source "${TEKHTON_HOME}/lib/plan.sh"

[ "$PLAN_INTERVIEW_MODEL" = "sonnet" ] || { echo "FAIL: PLAN_INTERVIEW_MODEL default should be 'sonnet', got '$PLAN_INTERVIEW_MODEL'"; exit 1; }
[ "$PLAN_INTERVIEW_MAX_TURNS" = "50" ] || { echo "FAIL: PLAN_INTERVIEW_MAX_TURNS default should be '50', got '$PLAN_INTERVIEW_MAX_TURNS'"; exit 1; }
[ "$PLAN_GENERATION_MODEL" = "sonnet" ] || { echo "FAIL: PLAN_GENERATION_MODEL default should be 'sonnet', got '$PLAN_GENERATION_MODEL'"; exit 1; }
[ "$PLAN_GENERATION_MAX_TURNS" = "30" ] || { echo "FAIL: PLAN_GENERATION_MAX_TURNS default should be '30', got '$PLAN_GENERATION_MAX_TURNS'"; exit 1; }

# Test 2: Load config from pipeline.conf
# Create a new temp dir to avoid polluting previous test
TMPDIR2=$(mktemp -d)
trap 'rm -rf "$TMPDIR2"' EXIT
PROJECT_DIR="$TMPDIR2"

mkdir -p "${PROJECT_DIR}/.claude"

# Create pipeline.conf with planning config
cat > "${PROJECT_DIR}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="Test Project"
PLAN_INTERVIEW_MODEL="opus"
PLAN_INTERVIEW_MAX_TURNS="75"
PLAN_GENERATION_MODEL="haiku"
PLAN_GENERATION_MAX_TURNS="15"
EOF

# Unset any pre-existing config vars
unset PLAN_INTERVIEW_MODEL PLAN_INTERVIEW_MAX_TURNS PLAN_GENERATION_MODEL PLAN_GENERATION_MAX_TURNS CLAUDE_PLAN_MODEL 2>/dev/null || true

# Source plan.sh again with the new config
source "${TEKHTON_HOME}/lib/plan.sh"

[ "$PLAN_INTERVIEW_MODEL" = "opus" ] || { echo "FAIL: PLAN_INTERVIEW_MODEL should be 'opus' from config, got '$PLAN_INTERVIEW_MODEL'"; exit 1; }
[ "$PLAN_INTERVIEW_MAX_TURNS" = "75" ] || { echo "FAIL: PLAN_INTERVIEW_MAX_TURNS should be '75' from config, got '$PLAN_INTERVIEW_MAX_TURNS'"; exit 1; }
[ "$PLAN_GENERATION_MODEL" = "haiku" ] || { echo "FAIL: PLAN_GENERATION_MODEL should be 'haiku' from config, got '$PLAN_GENERATION_MODEL'"; exit 1; }
[ "$PLAN_GENERATION_MAX_TURNS" = "15" ] || { echo "FAIL: PLAN_GENERATION_MAX_TURNS should be '15' from config, got '$PLAN_GENERATION_MAX_TURNS'"; exit 1; }

# Test 3: CLAUDE_PLAN_MODEL overrides both interview and generation models
TMPDIR3=$(mktemp -d)
trap 'rm -rf "$TMPDIR3"' EXIT
PROJECT_DIR="$TMPDIR3"

mkdir -p "${PROJECT_DIR}/.claude"

cat > "${PROJECT_DIR}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="Test Project"
CLAUDE_PLAN_MODEL="sonnet"
EOF

unset PLAN_INTERVIEW_MODEL PLAN_INTERVIEW_MAX_TURNS PLAN_GENERATION_MODEL PLAN_GENERATION_MAX_TURNS CLAUDE_PLAN_MODEL 2>/dev/null || true

source "${TEKHTON_HOME}/lib/plan.sh"

[ "$PLAN_INTERVIEW_MODEL" = "sonnet" ] || { echo "FAIL: PLAN_INTERVIEW_MODEL should use CLAUDE_PLAN_MODEL 'sonnet', got '$PLAN_INTERVIEW_MODEL'"; exit 1; }
[ "$PLAN_GENERATION_MODEL" = "sonnet" ] || { echo "FAIL: PLAN_GENERATION_MODEL should use CLAUDE_PLAN_MODEL 'sonnet', got '$PLAN_GENERATION_MODEL'"; exit 1; }

# Test 4: Partial config (only some keys set) uses defaults for others
TMPDIR4=$(mktemp -d)
trap 'rm -rf "$TMPDIR4"' EXIT
PROJECT_DIR="$TMPDIR4"

mkdir -p "${PROJECT_DIR}/.claude"

cat > "${PROJECT_DIR}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="Test Project"
PLAN_INTERVIEW_MODEL="opus"
EOF

unset PLAN_INTERVIEW_MODEL PLAN_INTERVIEW_MAX_TURNS PLAN_GENERATION_MODEL PLAN_GENERATION_MAX_TURNS CLAUDE_PLAN_MODEL 2>/dev/null || true

source "${TEKHTON_HOME}/lib/plan.sh"

[ "$PLAN_INTERVIEW_MODEL" = "opus" ] || { echo "FAIL: PLAN_INTERVIEW_MODEL should be 'opus' from config, got '$PLAN_INTERVIEW_MODEL'"; exit 1; }
[ "$PLAN_INTERVIEW_MAX_TURNS" = "50" ] || { echo "FAIL: PLAN_INTERVIEW_MAX_TURNS should default to '50', got '$PLAN_INTERVIEW_MAX_TURNS'"; exit 1; }
[ "$PLAN_GENERATION_MODEL" = "sonnet" ] || { echo "FAIL: PLAN_GENERATION_MODEL should default to 'sonnet', got '$PLAN_GENERATION_MODEL'"; exit 1; }
[ "$PLAN_GENERATION_MAX_TURNS" = "30" ] || { echo "FAIL: PLAN_GENERATION_MAX_TURNS should default to '30', got '$PLAN_GENERATION_MAX_TURNS'"; exit 1; }

echo "PASS: Planning config loading tests passed"
