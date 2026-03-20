#!/usr/bin/env bash
# Test: Milestone 17 — format_detection_report function
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source detection libraries
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=../lib/detect_commands.sh
source "${TEKHTON_HOME}/lib/detect_commands.sh"
# shellcheck source=../lib/detect_report.sh
source "${TEKHTON_HOME}/lib/detect_report.sh"

# =============================================================================
# Helper: make a fresh project dir
# =============================================================================
make_proj() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    echo "$dir"
}

# =============================================================================
# format_detection_report — produces expected sections
# =============================================================================
echo "=== format_detection_report ==="

RPT_DIR=$(make_proj "rpt_project")
cat > "$RPT_DIR/package.json" << 'EOF'
{
  "name": "rpt-app",
  "scripts": {
    "test": "jest",
    "lint": "eslint ."
  },
  "dependencies": {
    "express": "^4.18.0"
  }
}
EOF
touch "$RPT_DIR/index.js"

report=$(format_detection_report "$RPT_DIR")

if echo "$report" | grep -q "## Tech Stack Detection Report"; then
    pass "format_detection_report produces Tech Stack Detection Report heading"
else
    fail "Missing Tech Stack Detection Report heading"
fi

if echo "$report" | grep -q "### Languages"; then
    pass "format_detection_report produces Languages section"
else
    fail "Missing Languages section in report"
fi

if echo "$report" | grep -q "### Detected Commands"; then
    pass "format_detection_report produces Detected Commands section"
else
    fail "Missing Detected Commands section in report"
fi

if echo "$report" | grep -q "### Entry Points"; then
    pass "format_detection_report produces Entry Points section"
else
    fail "Missing Entry Points section in report"
fi

if echo "$report" | grep -q "### Project Type"; then
    pass "format_detection_report produces Project Type section"
else
    fail "Missing Project Type section in report"
fi

# =============================================================================
# format_detection_report — empty project produces none-detected rows
# =============================================================================
echo "=== format_detection_report: empty project ==="

EMPTY_RPT_DIR=$(make_proj "empty_rpt")
empty_report=$(format_detection_report "$EMPTY_RPT_DIR")

if echo "$empty_report" | grep -q "(none detected)"; then
    pass "format_detection_report shows (none detected) for empty project"
else
    fail "Expected (none detected) in empty project report"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
