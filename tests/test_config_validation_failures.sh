#!/usr/bin/env bash
# Test: Config validation — required keys must be present
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

# Helper function to test missing required key
test_missing_key() {
    local key_to_omit="$1"
    local description="$2"

    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' RETURN

    PROJECT_DIR="$TMPDIR"
    mkdir -p "${PROJECT_DIR}/.claude/agents"
    mkdir -p "${PROJECT_DIR}/.claude/logs"

    # Create a minimal pipeline.conf with only the 3 required keys, minus the one we're testing
    cat > "${PROJECT_DIR}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="Test Project"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo ok"
EOF

    # Remove the key we're testing for
    sed -i "/^${key_to_omit}=/d" "${PROJECT_DIR}/.claude/pipeline.conf"

    # Create dummy agent files
    for role in coder reviewer tester jr-coder; do
        echo "# ${role}" > "${PROJECT_DIR}/.claude/agents/${role}.md"
    done
    echo "# Rules" > "${PROJECT_DIR}/CLAUDE.md"

    export TEKHTON_HOME PROJECT_DIR

    # Source the libraries in a subshell and capture exit code
    (
        set -euo pipefail
        source "${TEKHTON_HOME}/lib/common.sh"
        NOTES_FILTER=""
        MILESTONE_MODE=false
        source "${TEKHTON_HOME}/lib/config.sh"
        cd "$PROJECT_DIR"
        load_config
    ) 2>/dev/null

    local exit_code=$?

    if [ "$exit_code" -eq 1 ]; then
        echo "✓ Missing $key_to_omit: load_config() correctly exited with status 1 ($description)"
        ((PASS_COUNT++))
        return 0
    else
        echo "✗ Missing $key_to_omit: load_config() exited with status $exit_code, expected 1 ($description)"
        ((FAIL_COUNT++))
        return 1
    fi
}

# Test each required key, allowing each to fail
test_missing_key "PROJECT_NAME" "project name required" || true
test_missing_key "CLAUDE_STANDARD_MODEL" "standard model required" || true
test_missing_key "ANALYZE_CMD" "analyze command required" || true

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "All config validation tests passed ($PASS_COUNT/$((PASS_COUNT + FAIL_COUNT)))"
    exit 0
else
    echo "Some tests failed ($PASS_COUNT passed, $FAIL_COUNT failed)"
    exit 1
fi
