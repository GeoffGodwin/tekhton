#!/usr/bin/env bash
# =============================================================================
# test_m29_milestone_conformance.sh — Verify m29 parent AC satisfaction
#
# Tests all seven acceptance criteria from the m29 parent milestone spec.
# Both m29.1 and m29.2 have completed — their files are deleted on close per
# the finalize orchestrator; MANIFEST carries status=done. Content checks for
# deleted milestones use git history.
#
#   AC1: m29.1 completed (file deleted); MANIFEST has status=done, depends=m27
#   AC2: m29.2 completed (file deleted); MANIFEST has status=done, depends=m29.1
#   AC3: m29.2 named all three parity-gate fixtures (verified via git history)
#   AC4: m29.2 had VERSION=4.29.0 AC (verified via git history)
#   AC5: m29.2 had Watch For bullets for read-only + dogfood (via git history)
#   AC6: Parent m29-detect-port.md has status: "split"
#   AC7: MANIFEST.cfg has three rows: m29 (split), m29.1 (done), m29.2 (done)
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

# Same as _section_has but operates on a string variable (for git-retrieved content).
_section_has_str() {
    local content="$1" section="$2" keyword="$3"
    echo "$content" | awk -v sec="$section" '
        $0 == "## " sec { found=1; next }
        /^## /          { found=0 }
        found           { print }
    ' | grep -qiE "$keyword"
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
# V4 milestones were archived to MANIFEST_V4.cfg at the V5 kickoff (commit 084d148).
# The active MANIFEST.cfg is the fresh V5 manifest; V4 row checks read the archive.
MANIFEST="${MILESTONE_DIR}/MANIFEST_V4.cfg"

# ---------------------------------------------------------------------------
# Load m29 parent + m29.2 file content from git history (files deleted on
# milestone close, and again wholesale at the V5 cleanup).
# ---------------------------------------------------------------------------
_git_last_content() {
    local path="$1"
    local sha
    sha=$(git -C "$TEKHTON_HOME" log --all --format="%H" --diff-filter=D \
        -- "$path" 2>/dev/null | head -1)
    if [[ -n "$sha" ]]; then
        git -C "$TEKHTON_HOME" show "${sha}^:${path}" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

M29_2_HIST="$(_git_last_content ".claude/milestones/m29.2-detect-domain-detectors.md")"
M29_PARENT_HIST="$(_git_last_content ".claude/milestones/m29-detect-port.md")"

# ---------------------------------------------------------------------------
# AC1 — m29.1 completed: file deleted by finalize, MANIFEST shows done
# ---------------------------------------------------------------------------
echo "Suite 1: m29.1 milestone completion state"

# The finalize orchestrator deletes the milestone file on close.
if [[ ! -f "$M29_1" ]]; then
    pass "m29.1 file absent (deleted by finalize on milestone close)"
else
    fail "m29.1 file unexpectedly present (expected deleted after completion)"
fi

# MANIFEST is the source of truth for completed milestones.
if grep -qE '^m29\.1\|[^|]+\|done\|' "$MANIFEST" 2>/dev/null; then
    pass "m29.1 MANIFEST row has status=done"
else
    fail "m29.1 MANIFEST row missing status=done"
fi

if grep -qE '^m29\.1\|[^|]+\|[^|]+\|m27\|' "$MANIFEST" 2>/dev/null; then
    pass "m29.1 MANIFEST row has depends_on=m27"
else
    fail "m29.1 MANIFEST row missing depends_on=m27"
fi

# ---------------------------------------------------------------------------
# AC2 — m29.2 completed: file deleted by finalize, MANIFEST shows done
# ---------------------------------------------------------------------------
echo "Suite 2: m29.2 milestone completion state"

if [[ ! -f "$M29_2" ]]; then
    pass "m29.2 file absent (deleted by finalize on milestone close)"
else
    fail "m29.2 file unexpectedly present (expected deleted after completion)"
fi

if grep -qE '^m29\.2\|[^|]+\|done\|' "$MANIFEST" 2>/dev/null; then
    pass "m29.2 MANIFEST row has status=done"
else
    fail "m29.2 MANIFEST row missing status=done"
fi

if grep -qE '^m29\.2\|[^|]+\|[^|]+\|m29\.1\|' "$MANIFEST" 2>/dev/null; then
    pass "m29.2 MANIFEST row has depends_on=m29.1"
else
    fail "m29.2 MANIFEST row missing depends_on=m29.1"
fi

# ---------------------------------------------------------------------------
# AC3 — m29.2 named the three parity-gate fixtures (verified via git history)
# ---------------------------------------------------------------------------
echo "Suite 3: Parity-gate fixture names in m29.2 (git history)"

for fixture in monorepo-pnpm polyglot-services ai-heavy-mess; do
    if echo "$M29_2_HIST" | grep -q "$fixture"; then
        pass "m29.2 named fixture: $fixture"
    else
        fail "m29.2 missing fixture reference: $fixture"
    fi
done

# ---------------------------------------------------------------------------
# AC4 — m29.2 had 4.29.0 VERSION AC (verified via git history)
# ---------------------------------------------------------------------------
echo "Suite 4: VERSION acceptance criteria (git history)"

if _section_has_str "$M29_2_HIST" "Acceptance Criteria" "4\.29\.0"; then
    pass "m29.2 Acceptance Criteria referenced VERSION 4.29.0"
else
    fail "m29.2 Acceptance Criteria missing VERSION 4.29.0 reference"
fi

# ---------------------------------------------------------------------------
# AC5 — Watch For bullets for read-only + dogfood (verified via git history)
# ---------------------------------------------------------------------------
echo "Suite 5: Watch For bullets — read-only contract and dogfood stability (git history)"

if _section_has_str "$M29_2_HIST" "Watch For" "read-only|readonly|read only"; then
    pass "m29.2 Watch For had read-only contract bullet"
else
    fail "m29.2 Watch For missing read-only contract bullet"
fi

if _section_has_str "$M29_2_HIST" "Watch For" "dogfood"; then
    pass "m29.2 Watch For had dogfood stability bullet"
else
    fail "m29.2 Watch For missing dogfood stability bullet"
fi

# ---------------------------------------------------------------------------
# AC6 — Parent m29-detect-port.md has status: "split"
# ---------------------------------------------------------------------------
echo "Suite 6: Parent milestone status"

if [[ -f "$M29_PARENT" ]]; then
    pass "m29 parent file exists"
elif [[ -n "$M29_PARENT_HIST" ]]; then
    pass "m29 parent recovered from git history (V4 cleanup deleted the file)"
else
    fail "m29 parent file missing: $M29_PARENT"
fi

if grep -q 'status: "split"' "$M29_PARENT" 2>/dev/null; then
    pass "m29 parent has status: \"split\""
elif echo "$M29_PARENT_HIST" | grep -q 'status: "split"'; then
    pass "m29 parent had status: \"split\" at last on-disk version (git history)"
else
    fail "m29 parent missing status: \"split\""
fi

# ---------------------------------------------------------------------------
# AC7 — MANIFEST.cfg carries three rows: m29 (split), m29.1 (done), m29.2 (done)
#       Both m29.1 and m29.2 have completed.
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

if grep -qE '^m29\.1\|[^|]+\|done\|' "$MANIFEST" 2>/dev/null; then
    pass "MANIFEST.cfg has m29.1 row with status=done"
else
    fail "MANIFEST.cfg missing m29.1 row with status=done"
fi

if grep -qE '^m29\.2\|[^|]+\|done\|' "$MANIFEST" 2>/dev/null; then
    pass "MANIFEST.cfg has m29.2 row with status=done"
else
    fail "MANIFEST.cfg missing m29.2 row with status=done"
fi

# Verify dependency column for m29.2 (m29.1 depends_on already verified in Suite 1)
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
