#!/usr/bin/env bash
# TIMEOUT_SECS=120
# =============================================================================
# test_wedge_audit_rules.sh — m32.2 regression test for the no-regexp-in-rules
# companion check in scripts/wedge-audit-companions.sh.
#
# Plants a temporary `import "regexp"` violation inside
# internal/diagnose/rules/ and asserts the audit exits non-zero. Cleans up
# on exit so a failed test does not poison the working tree.
#
# Tests:
#   1. Clean HEAD exits 0 (companion check passes without a planted file)
#   2. Planted violation → audit exits 1 and reports the file path
#   3. After cleanup → audit returns to exit 0
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_SCRIPT="${TEKHTON_HOME}/scripts/wedge-audit.sh"
VIOLATION="${TEKHTON_HOME}/internal/diagnose/rules/__test_planted_regex_violation.go"

PASS=0
FAIL=0

pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

cleanup() {
    rm -f -- "$VIOLATION"
}
trap cleanup EXIT INT TERM

# -- Test 1: clean baseline --------------------------------------------------

if bash "$AUDIT_SCRIPT" >/dev/null 2>&1; then
    pass "clean HEAD exits 0 (companion check inactive without violation)"
else
    fail "clean HEAD: expected exit 0 from wedge-audit"
fi

# -- Test 2: plant a violation, expect failure -------------------------------

cat > "$VIOLATION" <<'EOF'
//go:build ignore

package rules

// Deliberate planted violation — exercised by tests/test_wedge_audit_rules.sh
// to verify scripts/wedge-audit-companions.sh catches a regex import inside
// internal/diagnose/rules/. The //go:build ignore tag prevents the test file
// from interfering with `go build`.
import "regexp"

var _ = regexp.MustCompile(`.`)
EOF

if bash "$AUDIT_SCRIPT" >/tmp/wedge_audit_rules.out 2>&1; then
    fail "planted regex violation: expected non-zero exit, got 0"
else
    if grep -qF "internal/diagnose/rules" /tmp/wedge_audit_rules.out; then
        pass "planted violation: audit reports the offending file"
    else
        fail "planted violation: audit failed but did not name the path:"
        cat /tmp/wedge_audit_rules.out
    fi
fi

# -- Test 3: remove the violation, audit goes green again --------------------

rm -f -- "$VIOLATION"
if bash "$AUDIT_SCRIPT" >/dev/null 2>&1; then
    pass "post-cleanup: audit exits 0 again"
else
    fail "post-cleanup: audit still failing after violation removed"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
