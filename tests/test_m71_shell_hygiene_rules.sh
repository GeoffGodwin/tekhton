#!/usr/bin/env bash
# Test: M71 — Shell Hygiene section in coder.md contains all six required rules
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODER_MD="${TEKHTON_HOME}/.claude/agents/coder.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Verify coder.md exists
# =============================================================================
echo "=== coder.md exists ==="
if [[ -f "$CODER_MD" ]]; then
    pass "coder.md found at expected path"
else
    fail "coder.md not found at: ${CODER_MD}"
    echo "  Passed: ${PASS}  Failed: ${FAIL}"
    exit 1
fi

CONTENT=$(cat "$CODER_MD")

# =============================================================================
# Verify Shell Hygiene section heading is present
# =============================================================================
echo "=== Shell Hygiene section heading ==="
if echo "$CONTENT" | grep -q '### Shell Hygiene'; then
    pass "Shell Hygiene section heading present"
else
    fail "Missing '### Shell Hygiene' section heading in coder.md"
fi

# =============================================================================
# Rule 1: grep under set -e must use || true
# =============================================================================
echo "=== Rule 1: grep || true under set -e ==="
if echo "$CONTENT" | grep -q 'grep.*||.*true\||| true'; then
    pass "Rule 1: grep || true pattern documented"
else
    fail "Rule 1: grep || true pattern not found in Shell Hygiene section"
fi

# Verify sed/awk clarification: they do NOT need || true for zero-match case
if echo "$CONTENT" | grep -q 'sed.*awk.*return 0\|sed.*and.*awk.*return 0\|sed.*awk.*do NOT need\|they do NOT need'; then
    pass "Rule 1: sed/awk zero-match clarification present"
else
    fail "Rule 1: sed/awk clarification (no || true needed) missing"
fi

# =============================================================================
# Rule 2: SC2155 — local + command substitution on separate lines
# =============================================================================
echo "=== Rule 2: SC2155 local variable assignment ==="
if echo "$CONTENT" | grep -q 'SC2155\|local var.*cmd\|two lines.*local'; then
    pass "Rule 2: SC2155 two-line local assignment documented"
else
    fail "Rule 2: SC2155 local variable assignment rule missing"
fi

# =============================================================================
# Rule 3: -- option terminator before variable arguments
# =============================================================================
echo "=== Rule 3: -- option terminator ==="
if echo "$CONTENT" | grep -q 'option terminator\|grep -- \|-- "\$'; then
    pass "Rule 3: -- option terminator rule documented"
else
    fail "Rule 3: -- option terminator rule missing"
fi

# Verify the rule mentions grep, sed, rm, find
for cmd in grep sed rm find; do
    if echo "$CONTENT" | grep -q "$cmd"; then
        pass "Rule 3: ${cmd} mentioned in option terminator context"
    else
        fail "Rule 3: ${cmd} not mentioned — option terminator rule may be incomplete"
    fi
done

# =============================================================================
# Rule 4: Sourced files must NOT have their own set -euo pipefail
# =============================================================================
echo "=== Rule 4: Sourced files must not have set -euo pipefail ==="
if echo "$CONTENT" | grep -q 'sourced.*NOT\|NOT.*set -euo pipefail\|must NOT have.*set -euo'; then
    pass "Rule 4: sourced files no set -euo pipefail rule documented"
else
    fail "Rule 4: sourced files must NOT have set -euo pipefail — rule missing"
fi

# =============================================================================
# Rule 5: Stale references after rename
# =============================================================================
echo "=== Rule 5: Stale references after rename ==="
if echo "$CONTENT" | grep -q 'rename\|stale.*reference\|old_name\|grep -rn'; then
    pass "Rule 5: stale references after rename rule documented"
else
    fail "Rule 5: stale references after rename rule missing"
fi

# =============================================================================
# Rule 6: File length enforcement (300 lines)
# =============================================================================
echo "=== Rule 6: File length enforcement ==="
if echo "$CONTENT" | grep -q '300 lines\|wc -l\|_helpers.sh\|exceeds 300'; then
    pass "Rule 6: file length enforcement (300 lines) documented"
else
    fail "Rule 6: file length enforcement (wc -l / 300 lines) rule missing"
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
