#!/usr/bin/env bash
# =============================================================================
# test_retry_config_defaults.sh — Verify retry config keys have correct defaults
#
# Tests:
#   1. TRANSIENT_RETRY_ENABLED defaults to true
#   2. MAX_TRANSIENT_RETRIES defaults to 3
#   3. TRANSIENT_RETRY_BASE_DELAY defaults to 30
#   4. TRANSIENT_RETRY_MAX_DELAY defaults to 120
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0

# =============================================================================
# Test 1: Config defaults are applied
# =============================================================================

PROJECT_DIR="$TMPDIR/test1"
mkdir -p "$PROJECT_DIR/.claude"

cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet-4-6
ANALYZE_CMD=true
EOF

bash <<EOF
set -euo pipefail
TEKHTON_HOME="$TEKHTON_HOME"
PROJECT_DIR="$PROJECT_DIR"
source "\${TEKHTON_HOME}/lib/common.sh"
source "\${TEKHTON_HOME}/lib/config.sh"
load_config
[ "\$TRANSIENT_RETRY_ENABLED" = "true" ] || { echo "FAIL: 1.1"; exit 1; }
[ "\$MAX_TRANSIENT_RETRIES" = "3" ] || { echo "FAIL: 1.2"; exit 1; }
[ "\$TRANSIENT_RETRY_BASE_DELAY" = "30" ] || { echo "FAIL: 1.3"; exit 1; }
[ "\$TRANSIENT_RETRY_MAX_DELAY" = "120" ] || { echo "FAIL: 1.4"; exit 1; }
EOF
if [ $? -eq 0 ]; then
    echo "✓ Test 1: Defaults are applied correctly"
else
    FAIL=1
fi

# =============================================================================
# Test 2: Config overrides work
# =============================================================================

PROJECT_DIR="$TMPDIR/test2"
mkdir -p "$PROJECT_DIR/.claude"

cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet-4-6
ANALYZE_CMD=true
TRANSIENT_RETRY_ENABLED=false
MAX_TRANSIENT_RETRIES=5
TRANSIENT_RETRY_BASE_DELAY=60
TRANSIENT_RETRY_MAX_DELAY=240
EOF

bash <<EOF
set -euo pipefail
TEKHTON_HOME="$TEKHTON_HOME"
PROJECT_DIR="$PROJECT_DIR"
source "\${TEKHTON_HOME}/lib/common.sh"
source "\${TEKHTON_HOME}/lib/config.sh"
load_config
[ "\$TRANSIENT_RETRY_ENABLED" = "false" ] || { echo "FAIL: 2.1"; exit 1; }
[ "\$MAX_TRANSIENT_RETRIES" = "5" ] || { echo "FAIL: 2.2"; exit 1; }
[ "\$TRANSIENT_RETRY_BASE_DELAY" = "60" ] || { echo "FAIL: 2.3"; exit 1; }
[ "\$TRANSIENT_RETRY_MAX_DELAY" = "240" ] || { echo "FAIL: 2.4"; exit 1; }
EOF
if [ $? -eq 0 ]; then
    echo "✓ Test 2: Config overrides work correctly"
else
    FAIL=1
fi

# =============================================================================
# Test 3: Clamping happens after defaults
# =============================================================================

PROJECT_DIR="$TMPDIR/test3"
mkdir -p "$PROJECT_DIR/.claude"

cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet-4-6
ANALYZE_CMD=true
MAX_TRANSIENT_RETRIES=20
TRANSIENT_RETRY_BASE_DELAY=500
TRANSIENT_RETRY_MAX_DELAY=1000
EOF

bash <<EOF
set -euo pipefail
TEKHTON_HOME="$TEKHTON_HOME"
PROJECT_DIR="$PROJECT_DIR"
source "\${TEKHTON_HOME}/lib/common.sh"
source "\${TEKHTON_HOME}/lib/config.sh"
load_config 2>/dev/null
[ "\$MAX_TRANSIENT_RETRIES" = "10" ] || { echo "FAIL: 3.1 got \$MAX_TRANSIENT_RETRIES"; exit 1; }
[ "\$TRANSIENT_RETRY_BASE_DELAY" = "300" ] || { echo "FAIL: 3.2 got \$TRANSIENT_RETRY_BASE_DELAY"; exit 1; }
[ "\$TRANSIENT_RETRY_MAX_DELAY" = "600" ] || { echo "FAIL: 3.3 got \$TRANSIENT_RETRY_MAX_DELAY"; exit 1; }
EOF
if [ $? -eq 0 ]; then
    echo "✓ Test 3: Clamping enforces hard upper bounds"
else
    FAIL=1
fi

if [ $FAIL -gt 0 ]; then
    exit 1
fi

echo "PASS"
