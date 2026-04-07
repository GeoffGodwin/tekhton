#!/usr/bin/env bash
# =============================================================================
# test_platform_web_fragments.sh — Fragment validation and syntax tests
#                                    for platforms/web/ (Milestone 58)
#
# Split from test_platform_web.sh. Tests 28-29: fragment file validation
# and bash -n syntax check on detect.sh.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== test_platform_web_fragments.sh ==="

# --- Fragment file validation -------------------------------------------------

# Test 28: Fragment files exist and are non-empty
local_fail=0
for frag in coder_guidance.prompt.md specialist_checklist.prompt.md tester_patterns.prompt.md; do
    fpath="${TEKHTON_HOME}/platforms/web/${frag}"
    if [[ ! -f "$fpath" ]]; then
        fail "28: Missing fragment: ${frag}"
        local_fail=1
    elif [[ ! -s "$fpath" ]]; then
        fail "28: Empty fragment: ${frag}"
        local_fail=1
    fi
done
[[ "$local_fail" -eq 0 ]] && pass "28: All fragment files exist and are non-empty"

# Test 29: detect.sh passes bash -n
if bash -n "${TEKHTON_HOME}/platforms/web/detect.sh" 2>/dev/null; then
    pass "29: detect.sh passes bash -n"
else
    fail "29: detect.sh fails bash -n"
fi

# --- Summary ------------------------------------------------------------------

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
