#!/usr/bin/env bash
# =============================================================================
# test_usage_threshold_missing_arg.sh
#
# Tests that --usage-threshold with no value argument causes tekhton.sh to
# exit non-zero. Under set -u, the second shift in the --usage-threshold case
# leaves $1 unbound, which is a crash scenario.
#
# Verifies:
#   1. --usage-threshold with no value exits non-zero
#   2. The exit is non-zero (unbound variable under set -u or shift failure)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0

# Set up a minimal project dir with a valid pipeline.conf
PROJECT_DIR="$TMPDIR/project"
mkdir -p "$PROJECT_DIR/.claude"

cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=TestProject
CLAUDE_STANDARD_MODEL=claude-sonnet-4-6
ANALYZE_CMD=true
TEST_CMD=true
EOF

# =============================================================================
# Test 1: --usage-threshold with no value argument exits non-zero
#
# In tekhton.sh the --usage-threshold case does:
#   shift
#   USAGE_THRESHOLD_PCT="$1"   ← $1 is unbound here when no value was given
#   shift
# Under set -u this causes an unbound variable error.
# =============================================================================

exit_code=0
(cd "$PROJECT_DIR" && bash "$TEKHTON_HOME/tekhton.sh" --usage-threshold 2>/dev/null) \
    || exit_code=$?

if [ "$exit_code" -ne 0 ]; then
    echo "✓ Test 1: --usage-threshold with no value exits non-zero (exit code: $exit_code)"
else
    echo "FAIL: Test 1 — --usage-threshold with no value should exit non-zero, got 0"
    FAIL=1
fi

# =============================================================================
# Test 2: --usage-threshold with a valid numeric value does NOT crash at parsing
#
# With a valid value, parsing completes without error. The script may still exit
# non-zero later (no task given, missing CLAUDE.md, etc.) but it should NOT
# crash with an unbound-variable error at the argument parsing stage.
# We check that the exit is NOT due to the unbound variable crash by
# confirming a different error message is present.
# =============================================================================

exit_output=""
exit_code2=0
exit_output=$(cd "$PROJECT_DIR" && bash "$TEKHTON_HOME/tekhton.sh" --usage-threshold 90 2>&1) \
    || exit_code2=$?

# The crash at $1 unbound prints "unbound variable" or similar to stderr.
# With a valid value, we should NOT see this pattern.
if echo "$exit_output" | grep -qi "unbound variable"; then
    echo "FAIL: Test 2 — --usage-threshold 90 triggered an unbound variable crash"
    FAIL=1
else
    echo "✓ Test 2: --usage-threshold with value 90 does not crash with unbound variable"
fi

# =============================================================================
# Summary
# =============================================================================
if [ "$FAIL" -eq 0 ]; then
    echo "PASS"
else
    exit 1
fi
