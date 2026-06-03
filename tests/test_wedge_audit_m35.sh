#!/usr/bin/env bash
# TIMEOUT_SECS=120
# =============================================================================
# test_wedge_audit_m35.sh — m35.3 regression test for the security ban block
# in scripts/wedge-audit-companions.sh.
#
# Plants three classes of violation in turn and asserts the audit exits
# non-zero each time. Cleans up on every exit path so a failed test does not
# poison the working tree.
#
# Tests:
#   1. Clean HEAD exits 0 (no plants).
#   2. Plant stages/security.sh → audit exits 1 and names the path.
#   3. Plant lib/security_helpers.sh → audit exits 1 and names the path.
#   4. Plant a lib/ file containing `_parse_security_findings` (no allowlist
#      marker) → audit exits 1.
#   5. Plant the same lib/ file WITH the `--m35-allowlist` marker → audit
#      exits 0 (escape hatch honored).
#   6. After cleanup → audit returns to exit 0.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_SCRIPT="${TEKHTON_HOME}/scripts/wedge-audit.sh"

PLANT_STAGE="${TEKHTON_HOME}/stages/security.sh"
PLANT_HELPERS="${TEKHTON_HOME}/lib/security_helpers.sh"
PLANT_FN="${TEKHTON_HOME}/lib/_m35_test_planted_security_fn.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

cleanup() {
    rm -f -- "$PLANT_STAGE" "$PLANT_HELPERS" "$PLANT_FN"
}
trap cleanup EXIT INT TERM

# -- Test 1: clean baseline --------------------------------------------------

if bash "$AUDIT_SCRIPT" >/dev/null 2>&1; then
    pass "clean HEAD exits 0 (m35.3 ban inactive without violations)"
else
    fail "clean HEAD: expected exit 0 from wedge-audit"
fi

# -- Test 2: plant stages/security.sh ----------------------------------------

printf '#!/usr/bin/env bash\n:\n' > "$PLANT_STAGE"
if bash "$AUDIT_SCRIPT" >/tmp/wedge_audit_m35.out 2>&1; then
    fail "planted stages/security.sh: expected non-zero exit, got 0"
else
    if grep -qF 'stages/security.sh re-introduced' /tmp/wedge_audit_m35.out; then
        pass "planted stages/security.sh: audit names the path"
    else
        fail "planted stages/security.sh: audit failed but did not name the path:"
        cat /tmp/wedge_audit_m35.out
    fi
fi
rm -f -- "$PLANT_STAGE"

# -- Test 3: plant lib/security_helpers.sh -----------------------------------

printf '#!/usr/bin/env bash\n:\n' > "$PLANT_HELPERS"
if bash "$AUDIT_SCRIPT" >/tmp/wedge_audit_m35.out 2>&1; then
    fail "planted lib/security_helpers.sh: expected non-zero exit, got 0"
else
    if grep -qF 'lib/security_helpers.sh re-introduced' /tmp/wedge_audit_m35.out; then
        pass "planted lib/security_helpers.sh: audit names the path"
    else
        fail "planted lib/security_helpers.sh: audit failed but did not name the path:"
        cat /tmp/wedge_audit_m35.out
    fi
fi
rm -f -- "$PLANT_HELPERS"

# -- Test 4: plant a deleted function name (no allowlist marker) -------------

cat > "$PLANT_FN" <<'EOF'
#!/usr/bin/env bash
# Deliberate planted violation — exercised by tests/test_wedge_audit_m35.sh
# to verify the deleted-name ban catches a resurrected security helper.
_parse_security_findings() { :; }
EOF
if bash "$AUDIT_SCRIPT" >/tmp/wedge_audit_m35.out 2>&1; then
    fail "planted _parse_security_findings: expected non-zero exit, got 0"
else
    if grep -qF '_m35_test_planted_security_fn.sh' /tmp/wedge_audit_m35.out; then
        pass "planted _parse_security_findings: audit names the path"
    else
        fail "planted _parse_security_findings: audit failed but did not name the path:"
        cat /tmp/wedge_audit_m35.out
    fi
fi

# -- Test 5: add the --m35-allowlist escape hatch marker ---------------------

cat > "$PLANT_FN" <<'EOF'
#!/usr/bin/env bash
# Deliberate planted violation with the m35 allowlist escape hatch.
# --m35-allowlist
# This file documents the deleted _parse_security_findings helper for
# historical context. The marker above opts this file out of the ban.
_legitimate_doc_reference() {
    # _parse_security_findings was deleted in m35.1; see internal/security/.
    :
}
EOF
if bash "$AUDIT_SCRIPT" >/dev/null 2>&1; then
    pass "allowlisted file: audit honors the --m35-allowlist marker"
else
    fail "allowlisted file: audit should exit 0 when marker is present"
fi
rm -f -- "$PLANT_FN"

# -- Test 6: full cleanup → audit goes green ---------------------------------

if bash "$AUDIT_SCRIPT" >/dev/null 2>&1; then
    pass "post-cleanup: audit exits 0 again"
else
    fail "post-cleanup: audit still failing after all plants removed"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
