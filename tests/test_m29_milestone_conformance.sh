#!/usr/bin/env bash
# =============================================================================
# test_m29_milestone_conformance.sh — Verify m29 parent AC satisfaction
#
# Tests all seven acceptance criteria from the m29 parent milestone spec:
#   AC1: m29.1 exists, meta block id="29.1" status="todo", Depends on m27
#   AC2: m29.2 exists, meta block id="29.2" status="todo", Depends on m29.1
#   AC3: Both child milestones name all three parity-gate fixtures
#   AC4: m29.2 has VERSION=4.29.0 AC; m29.1 does not
#   AC5: Both child milestones have Watch For bullets for read-only + dogfood
#   AC6: Parent m29-detect-port.md has status: "split"
#   AC7: MANIFEST.cfg has three rows: m29 (split), m29.1 (todo), m29.2 (todo)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MILESTONE_DIR="${TEKHTON_HOME}/.claude/milestones"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Helpers — defined before any call sites
# ---------------------------------------------------------------------------

# Extract text from a named markdown section and check for a keyword (ERE).
# Uses a flag-based awk so it handles the "start == end" same-line-match edge
# case and avoids the reserved awk keyword "in".
_section_has() {
    local file="$1" section="$2" keyword="$3"
    awk -v sec="$section" '
        $0 == "## " sec { found=1; next }
        /^## /          { found=0 }
        found           { print }
    ' "$file" 2>/dev/null | grep -qiE "$keyword"
}

_watch_for_has() {
    local file="$1" keyword="$2"
    _section_has "$file" "Watch For" "$keyword"
}

_ac_has() {
    local file="$1" keyword="$2"
    _section_has "$file" "Acceptance Criteria" "$keyword"
}

# ---------------------------------------------------------------------------
# File paths under test
# ---------------------------------------------------------------------------
M29_PARENT="${MILESTONE_DIR}/m29-detect-port.md"
M29_1="${MILESTONE_DIR}/m29.1-detect-core-and-report.md"
M29_2="${MILESTONE_DIR}/m29.2-detect-domain-detectors.md"
MANIFEST="${MILESTONE_DIR}/MANIFEST.cfg"

# ---------------------------------------------------------------------------
# AC1 — m29.1 exists with correct meta block and Overview dependency
# ---------------------------------------------------------------------------
echo "Suite 1: m29.1 file existence and meta"

if [[ -f "$M29_1" ]]; then
    pass "m29.1 file exists"
else
    fail "m29.1 file missing: $M29_1"
fi

if grep -q 'id: "29.1"' "$M29_1" 2>/dev/null; then
    pass "m29.1 meta block has id: \"29.1\""
else
    fail "m29.1 meta block missing id: \"29.1\""
fi

if grep -q 'status: "todo"' "$M29_1" 2>/dev/null; then
    pass "m29.1 meta block has status: \"todo\""
else
    fail "m29.1 meta block missing status: \"todo\""
fi

if grep -qE '\*\*Depends on\*\*.*m27' "$M29_1" 2>/dev/null; then
    pass "m29.1 Overview table declares Depends on m27"
else
    fail "m29.1 Overview table missing 'Depends on | m27' row"
fi

# ---------------------------------------------------------------------------
# AC2 — m29.2 exists with correct meta block and Overview dependency
# ---------------------------------------------------------------------------
echo "Suite 2: m29.2 file existence and meta"

if [[ -f "$M29_2" ]]; then
    pass "m29.2 file exists"
else
    fail "m29.2 file missing: $M29_2"
fi

if grep -q 'id: "29.2"' "$M29_2" 2>/dev/null; then
    pass "m29.2 meta block has id: \"29.2\""
else
    fail "m29.2 meta block missing id: \"29.2\""
fi

if grep -q 'status: "todo"' "$M29_2" 2>/dev/null; then
    pass "m29.2 meta block has status: \"todo\""
else
    fail "m29.2 meta block missing status: \"todo\""
fi

if grep -qE '\*\*Depends on\*\*.*m29\.1' "$M29_2" 2>/dev/null; then
    pass "m29.2 Overview table declares Depends on m29.1"
else
    fail "m29.2 Overview table missing 'Depends on | m29.1' row"
fi

# ---------------------------------------------------------------------------
# AC3 — Both child milestones name the three parity-gate fixtures
# ---------------------------------------------------------------------------
echo "Suite 3: Parity-gate fixture names in both children"

for fixture in monorepo-pnpm polyglot-services ai-heavy-mess; do
    if grep -q "$fixture" "$M29_1" 2>/dev/null; then
        pass "m29.1 names fixture: $fixture"
    else
        fail "m29.1 missing fixture reference: $fixture"
    fi
    if grep -q "$fixture" "$M29_2" 2>/dev/null; then
        pass "m29.2 names fixture: $fixture"
    else
        fail "m29.2 missing fixture reference: $fixture"
    fi
done

# ---------------------------------------------------------------------------
# AC4 — m29.2 has 4.29.0 VERSION AC; m29.1 Acceptance Criteria section does not
# ---------------------------------------------------------------------------
echo "Suite 4: VERSION acceptance criteria"

if _ac_has "$M29_2" "4\.29\.0"; then
    pass "m29.2 Acceptance Criteria references VERSION 4.29.0"
else
    fail "m29.2 Acceptance Criteria missing VERSION 4.29.0 reference"
fi

# m29.1 may mention 4.29.0 in Seeds Forward (describing what m29.2 will do),
# but its own AC section must NOT contain a 4.29.0 VERSION criterion — the
# bump belongs to the last-decimal child (m29.2) per m27.3 precedent.
if _ac_has "$M29_1" "4\.29\.0"; then
    fail "m29.1 Acceptance Criteria section incorrectly references VERSION 4.29.0 (should only be in m29.2)"
else
    pass "m29.1 Acceptance Criteria correctly omits VERSION 4.29.0 reference"
fi

# ---------------------------------------------------------------------------
# AC5 — Both child milestones have Watch For bullets for read-only + dogfood
# ---------------------------------------------------------------------------
echo "Suite 5: Watch For bullets — read-only contract and dogfood stability"

if _watch_for_has "$M29_1" "read-only|readonly|read only"; then
    pass "m29.1 Watch For has read-only contract bullet"
else
    fail "m29.1 Watch For missing read-only contract bullet"
fi

if _watch_for_has "$M29_1" "dogfood"; then
    pass "m29.1 Watch For has dogfood stability bullet"
else
    fail "m29.1 Watch For missing dogfood stability bullet"
fi

if _watch_for_has "$M29_2" "read-only|readonly|read only"; then
    pass "m29.2 Watch For has read-only contract bullet"
else
    fail "m29.2 Watch For missing read-only contract bullet"
fi

if _watch_for_has "$M29_2" "dogfood"; then
    pass "m29.2 Watch For has dogfood stability bullet"
else
    fail "m29.2 Watch For missing dogfood stability bullet"
fi

# ---------------------------------------------------------------------------
# AC6 — Parent m29-detect-port.md has status: "split"
# ---------------------------------------------------------------------------
echo "Suite 6: Parent milestone status"

if [[ -f "$M29_PARENT" ]]; then
    pass "m29 parent file exists"
else
    fail "m29 parent file missing: $M29_PARENT"
fi

if grep -q 'status: "split"' "$M29_PARENT" 2>/dev/null; then
    pass "m29 parent has status: \"split\""
else
    fail "m29 parent missing status: \"split\""
fi

# ---------------------------------------------------------------------------
# AC7 — MANIFEST.cfg carries three rows: m29 (split), m29.1 (todo), m29.2 (todo)
# ---------------------------------------------------------------------------
echo "Suite 7: MANIFEST.cfg rows"

if [[ -f "$MANIFEST" ]]; then
    pass "MANIFEST.cfg exists"
else
    fail "MANIFEST.cfg missing: $MANIFEST"
fi

# Each row is pipe-delimited: id|title|status|depends_on|file|tags
if grep -qE '^m29\|[^|]+\|split\|' "$MANIFEST" 2>/dev/null; then
    pass "MANIFEST.cfg has m29 row with status=split"
else
    fail "MANIFEST.cfg missing m29 row with status=split"
fi

if grep -qE '^m29\.1\|[^|]+\|todo\|' "$MANIFEST" 2>/dev/null; then
    pass "MANIFEST.cfg has m29.1 row with status=todo"
else
    fail "MANIFEST.cfg missing m29.1 row with status=todo"
fi

if grep -qE '^m29\.2\|[^|]+\|todo\|' "$MANIFEST" 2>/dev/null; then
    pass "MANIFEST.cfg has m29.2 row with status=todo"
else
    fail "MANIFEST.cfg missing m29.2 row with status=todo"
fi

# Verify dependency columns in MANIFEST
if grep -qE '^m29\.1\|[^|]+\|[^|]+\|m27\|' "$MANIFEST" 2>/dev/null; then
    pass "MANIFEST.cfg m29.1 row has depends_on=m27"
else
    fail "MANIFEST.cfg m29.1 row missing depends_on=m27"
fi

if grep -qE '^m29\.2\|[^|]+\|[^|]+\|m29\.1\|' "$MANIFEST" 2>/dev/null; then
    pass "MANIFEST.cfg m29.2 row has depends_on=m29.1"
else
    fail "MANIFEST.cfg m29.2 row missing depends_on=m29.1"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Results: Passed=$PASS Failed=$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
