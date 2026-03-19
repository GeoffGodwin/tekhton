#!/usr/bin/env bash
# =============================================================================
# test_agent_retry_config_defaults.sh — Retry config defaults (13.2.1)
#
# Tests:
#   1. TRANSIENT_RETRY_ENABLED defaults to true
#   2. MAX_TRANSIENT_RETRIES defaults to 3
#   3. TRANSIENT_RETRY_BASE_DELAY defaults to 30 seconds
#   4. TRANSIENT_RETRY_MAX_DELAY defaults to 120 seconds
#   5. Config values can be overridden in pipeline.conf
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
PROJECT_NAME="test-project"

# Create minimal pipeline.conf (required for load_config)
mkdir -p "$PROJECT_DIR/.claude"
cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet
CODER_MAX_TURNS=50
REVIEWER_MAX_TURNS=10
TESTER_MAX_TURNS=20
JR_CODER_MAX_TURNS=15
ANALYZE_CMD=echo "mock"
TEST_CMD=echo "mock"
EOF

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/config.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    else
        echo "PASS: $name"
    fi
}

# =============================================================================
# Phase 1: Load config and check defaults
# =============================================================================

load_config

assert_eq "1.1 TRANSIENT_RETRY_ENABLED default" "true" "${TRANSIENT_RETRY_ENABLED:-}"
assert_eq "1.2 MAX_TRANSIENT_RETRIES default" "3" "${MAX_TRANSIENT_RETRIES:-}"
assert_eq "1.3 TRANSIENT_RETRY_BASE_DELAY default" "30" "${TRANSIENT_RETRY_BASE_DELAY:-}"
assert_eq "1.4 TRANSIENT_RETRY_MAX_DELAY default" "120" "${TRANSIENT_RETRY_MAX_DELAY:-}"

# =============================================================================
# Phase 2: Override config values
# =============================================================================

# Create a pipeline.conf with custom retry settings
cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet
CODER_MAX_TURNS=50
REVIEWER_MAX_TURNS=10
TESTER_MAX_TURNS=20
JR_CODER_MAX_TURNS=15
ANALYZE_CMD=echo "mock"
TEST_CMD=echo "mock"
TRANSIENT_RETRY_ENABLED=false
MAX_TRANSIENT_RETRIES=5
TRANSIENT_RETRY_BASE_DELAY=60
TRANSIENT_RETRY_MAX_DELAY=300
EOF

# Reload config with custom values
load_config

assert_eq "2.1 TRANSIENT_RETRY_ENABLED override" "false" "${TRANSIENT_RETRY_ENABLED:-}"
assert_eq "2.2 MAX_TRANSIENT_RETRIES override" "5" "${MAX_TRANSIENT_RETRIES:-}"
assert_eq "2.3 TRANSIENT_RETRY_BASE_DELAY override" "60" "${TRANSIENT_RETRY_BASE_DELAY:-}"
assert_eq "2.4 TRANSIENT_RETRY_MAX_DELAY override" "300" "${TRANSIENT_RETRY_MAX_DELAY:-}"

# =============================================================================
# Phase 3: Verify clamping (hard upper bounds)
# =============================================================================

# Create config with out-of-bounds values
cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet
CODER_MAX_TURNS=50
REVIEWER_MAX_TURNS=10
TESTER_MAX_TURNS=20
JR_CODER_MAX_TURNS=15
ANALYZE_CMD=echo "mock"
TEST_CMD=echo "mock"
MAX_TRANSIENT_RETRIES=100
TRANSIENT_RETRY_BASE_DELAY=1000
TRANSIENT_RETRY_MAX_DELAY=2000
EOF

load_config

# Check that values are clamped to hard upper bounds
# MAX_TRANSIENT_RETRIES capped at 10, BASE_DELAY at 300, MAX_DELAY at 600
assert_eq "3.1 MAX_TRANSIENT_RETRIES clamped to 10" "10" "${MAX_TRANSIENT_RETRIES:-}"
assert_eq "3.2 TRANSIENT_RETRY_BASE_DELAY clamped to 300" "300" "${TRANSIENT_RETRY_BASE_DELAY:-}"
assert_eq "3.3 TRANSIENT_RETRY_MAX_DELAY clamped to 600" "600" "${TRANSIENT_RETRY_MAX_DELAY:-}"

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    echo "FAILED: $FAIL tests"
    exit 1
fi
echo "All tests passed!"
exit 0
