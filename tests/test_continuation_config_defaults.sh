#!/usr/bin/env bash
# =============================================================================
# test_continuation_config_defaults.sh — Verify continuation config defaults
#
# Tests:
#   1. CONTINUATION_ENABLED defaults to true
#   2. MAX_CONTINUATION_ATTEMPTS defaults to 3
#   3. MAX_CONTINUATION_ATTEMPTS clamped at 10 when set above the limit
#   4. CONTINUATION_ENABLED=false is preserved from config
#   5. MAX_CONTINUATION_ATTEMPTS project override is respected (within clamp)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

# Helper: create a minimal pipeline.conf and load config in a subshell
_load_config_with() {
    local project_dir="$1"
    local extra_conf="$2"

    mkdir -p "$project_dir/.claude"
    cat > "$project_dir/.claude/pipeline.conf" << EOF
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet-4-6
ANALYZE_CMD=true
${extra_conf}
EOF

    bash << SUBSHELL
set -euo pipefail
TEKHTON_HOME="${TEKHTON_HOME}"
PROJECT_DIR="${project_dir}"
source "\${TEKHTON_HOME}/lib/common.sh"
source "\${TEKHTON_HOME}/lib/config.sh"
load_config 2>/dev/null
printf "CONTINUATION_ENABLED=%s\n" "\${CONTINUATION_ENABLED}"
printf "MAX_CONTINUATION_ATTEMPTS=%s\n" "\${MAX_CONTINUATION_ATTEMPTS}"
SUBSHELL
}

# =============================================================================
# Test 1: Default values applied when not in pipeline.conf
# =============================================================================
echo "=== Test 1: Defaults applied ==="

PROJECT_DIR="$TMPDIR/test_defaults"
output=$(_load_config_with "$PROJECT_DIR" "")

if echo "$output" | grep -q "CONTINUATION_ENABLED=true"; then
    pass "1.1: CONTINUATION_ENABLED defaults to true"
else
    fail "1.1: CONTINUATION_ENABLED should default to true, got: $(echo "$output" | grep CONTINUATION_ENABLED)"
fi

if echo "$output" | grep -q "MAX_CONTINUATION_ATTEMPTS=3"; then
    pass "1.2: MAX_CONTINUATION_ATTEMPTS defaults to 3"
else
    fail "1.2: MAX_CONTINUATION_ATTEMPTS should default to 3, got: $(echo "$output" | grep MAX_CONTINUATION_ATTEMPTS)"
fi

# =============================================================================
# Test 2: CONTINUATION_ENABLED=false preserved from config
# =============================================================================
echo "=== Test 2: CONTINUATION_ENABLED=false override ==="

PROJECT_DIR="$TMPDIR/test_disabled"
output=$(_load_config_with "$PROJECT_DIR" "CONTINUATION_ENABLED=false")

if echo "$output" | grep -q "CONTINUATION_ENABLED=false"; then
    pass "2.1: CONTINUATION_ENABLED=false preserved from pipeline.conf"
else
    fail "2.1: CONTINUATION_ENABLED=false should be preserved, got: $(echo "$output" | grep CONTINUATION_ENABLED)"
fi

# =============================================================================
# Test 3: MAX_CONTINUATION_ATTEMPTS project override preserved (within clamp)
# =============================================================================
echo "=== Test 3: Project override (within clamp) ==="

PROJECT_DIR="$TMPDIR/test_override"
output=$(_load_config_with "$PROJECT_DIR" "MAX_CONTINUATION_ATTEMPTS=5")

if echo "$output" | grep -q "MAX_CONTINUATION_ATTEMPTS=5"; then
    pass "3.1: MAX_CONTINUATION_ATTEMPTS=5 preserved from pipeline.conf"
else
    fail "3.1: Project override should be preserved, got: $(echo "$output" | grep MAX_CONTINUATION_ATTEMPTS)"
fi

# =============================================================================
# Test 4: MAX_CONTINUATION_ATTEMPTS clamped at 10 when set above limit
# =============================================================================
echo "=== Test 4: Clamping at upper bound ==="

PROJECT_DIR="$TMPDIR/test_clamp"
output=$(_load_config_with "$PROJECT_DIR" "MAX_CONTINUATION_ATTEMPTS=20")

if echo "$output" | grep -q "MAX_CONTINUATION_ATTEMPTS=10"; then
    pass "4.1: MAX_CONTINUATION_ATTEMPTS=20 clamped to 10"
else
    fail "4.1: Should clamp to 10, got: $(echo "$output" | grep MAX_CONTINUATION_ATTEMPTS)"
fi

# =============================================================================
# Test 5: MAX_CONTINUATION_ATTEMPTS=1 (minimum meaningful value) preserved
# =============================================================================
echo "=== Test 5: Minimum value preserved ==="

PROJECT_DIR="$TMPDIR/test_min"
output=$(_load_config_with "$PROJECT_DIR" "MAX_CONTINUATION_ATTEMPTS=1")

if echo "$output" | grep -q "MAX_CONTINUATION_ATTEMPTS=1"; then
    pass "5.1: MAX_CONTINUATION_ATTEMPTS=1 preserved (not clamped upward)"
else
    fail "5.1: Minimum value 1 should be preserved, got: $(echo "$output" | grep MAX_CONTINUATION_ATTEMPTS)"
fi

# =============================================================================
# Test 6: MAX_CONTINUATION_ATTEMPTS exactly at clamp boundary (=10) preserved
# =============================================================================
echo "=== Test 6: Value at clamp boundary preserved ==="

PROJECT_DIR="$TMPDIR/test_boundary"
output=$(_load_config_with "$PROJECT_DIR" "MAX_CONTINUATION_ATTEMPTS=10")

if echo "$output" | grep -q "MAX_CONTINUATION_ATTEMPTS=10"; then
    pass "6.1: MAX_CONTINUATION_ATTEMPTS=10 preserved (at boundary)"
else
    fail "6.1: Value at boundary (10) should be preserved, got: $(echo "$output" | grep MAX_CONTINUATION_ATTEMPTS)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"

if [ $FAIL -gt 0 ]; then
    echo "  FAIL: $FAIL test(s) failed"
    exit 1
fi

echo "PASS"
