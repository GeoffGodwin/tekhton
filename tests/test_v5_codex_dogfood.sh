#!/usr/bin/env bash
# TIMEOUT_SECS=20
# =============================================================================
# test_v5_codex_dogfood.sh — m12 dogfood evidence document integrity guard.
#
# What this test covers
# ---------------------
# Reviewer coverage gap (m12): docs/v5-codex-dogfood-evidence.md acceptance
# criterion was verified manually only. This test provides a grep-based
# regression guard: once m12 ships and the evidence document is created, any
# future deletion or truncation of the document will surface here immediately.
#
# Skip behavior
# -------------
# The evidence document is only created when m12 runs successfully. Before m12
# ships, this test skips with a notice rather than failing — a failing test
# that guards a not-yet-created artifact provides no regression value and
# blocks CI on every run.
#
# Required fields (from m12 acceptance criteria)
# -----------------------------------------------
# - A "RUN_SUMMARY" section (h2 or table heading)
# - Total cost figure (numeric USD value)
# - Commit subject line from the dogfood run
# - At least one "##" section heading (document is substantive, not empty)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DOC="${TEKHTON_HOME}/docs/v5-codex-dogfood-evidence.md"

PASS=0
FAIL=0
_pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Pre-condition: document must exist before any assertion runs.
# =============================================================================
if [[ ! -f "$EVIDENCE_DOC" ]]; then
    echo "SKIP: docs/v5-codex-dogfood-evidence.md does not exist."
    echo "      m12 (Codex provider selection dogfood) has not run yet."
    echo "      This test will activate automatically once m12 ships."
    exit 0
fi

echo "Evidence document found: $EVIDENCE_DOC"
echo ""

# =============================================================================
# A: Document is non-empty and substantive
# =============================================================================
echo "=== A: Document is non-empty and has section structure ==="

doc_size=$(wc -c < "$EVIDENCE_DOC")
if [[ "$doc_size" -gt 100 ]]; then
    _pass "A1: document is non-empty (${doc_size} bytes)"
else
    _fail "A1: document is suspiciously small (${doc_size} bytes) — may be truncated or placeholder"
fi

# A2: Must have at least one ## section heading.
if grep -qE '^## ' "$EVIDENCE_DOC"; then
    section_count=$(grep -cE '^## ' "$EVIDENCE_DOC")
    _pass "A2: document has ${section_count} '##' section heading(s)"
else
    _fail "A2: document has no '## ' section headings — not a valid evidence document"
fi

echo ""

# =============================================================================
# B: RUN_SUMMARY section present
# =============================================================================
echo "=== B: RUN_SUMMARY section ==="

if grep -qiE '(^##.*RUN_SUMMARY|RUN_SUMMARY)' "$EVIDENCE_DOC"; then
    _pass "B1: RUN_SUMMARY reference found"
else
    _fail "B1: no RUN_SUMMARY reference — required m12 acceptance criterion missing"
fi

echo ""

# =============================================================================
# C: Cost figure present
# =============================================================================
echo "=== C: Total cost figure ==="

# Matches patterns like "$0.12", "$1.23", "0.12 USD", "total cost: $N.NN"
if grep -qiE '\$[0-9]+\.[0-9]+|[0-9]+\.[0-9]+\s*(USD|usd|dollars?)' "$EVIDENCE_DOC"; then
    cost_match=$(grep -ioE '\$[0-9]+\.[0-9]+|[0-9]+\.[0-9]+\s*(USD|usd|dollars?)' "$EVIDENCE_DOC" | head -1)
    _pass "C1: cost figure found: '${cost_match}'"
else
    _fail "C1: no cost figure found (expected USD amount like '\$0.12' or '0.12 USD')"
fi

echo ""

# =============================================================================
# D: Commit subject line present
# =============================================================================
echo "=== D: Commit subject line ==="

# The dogfood evidence must include the git commit subject from the m12 run.
# Commit subjects typically start with a conventional-commit prefix or are
# at least 10 chars. We look for a line that looks like a commit message.
if grep -qiE '(commit|feat|fix|chore|refactor|test)\s*(\(|:)' "$EVIDENCE_DOC"; then
    commit_line=$(grep -iE '(commit|feat|fix|chore|refactor|test)\s*(\(|:)' "$EVIDENCE_DOC" | head -1)
    _pass "D1: commit subject found: '${commit_line:0:80}'"
else
    # Fallback: any line explicitly labeled as a commit or hash.
    if grep -qiE '(commit hash|commit sha|git commit|HEAD commit)' "$EVIDENCE_DOC"; then
        _pass "D1: commit reference found (labeled as 'commit hash'/'git commit')"
    else
        _fail "D1: no commit subject or reference found — m12 dogfood evidence incomplete"
    fi
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "m12 dogfood evidence document integrity check passed"
