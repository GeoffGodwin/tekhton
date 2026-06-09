#!/usr/bin/env bash
# TIMEOUT_SECS=30
# =============================================================================
# test_v5_codex_dogfood.sh — m12 dogfood evidence regression guard.
#
# What this test covers
# ---------------------
# Coverage gap from m12 reviewer: docs/v5-codex-dogfood-evidence.md must
# exist and contain the required fields so future accidental deletion or
# truncation is caught by CI rather than going unnoticed.
#
# The test verifies:
#   A. docs/v5-codex-dogfood-evidence.md exists (not deleted or never created).
#   B. The document contains a RUN_SUMMARY section (proof it's a real run log).
#   C. The document mentions total cost or token usage (cost framing is core
#      to the m12 motivation — Anthropic pricing change makes Codex cost matter).
#   D. The document includes a commit subject (evidence the pipeline committed).
#   E. The document has at least 5 ## section headings (structural completeness;
#      a truncated doc would have fewer sections).
#
# This test does NOT require the Codex binary to be installed. It checks the
# committed evidence document only. New Codex runs are captured separately.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0
_pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

EVIDENCE_DOC="${TEKHTON_HOME}/docs/v5-codex-dogfood-evidence.md"

# =============================================================================
# A. Document exists
# =============================================================================
echo "=== A: docs/v5-codex-dogfood-evidence.md exists ==="
if [[ -f "$EVIDENCE_DOC" ]]; then
    _pass "A: $EVIDENCE_DOC exists"
else
    _fail "A: $EVIDENCE_DOC not found — m12 dogfood evidence was never captured or was deleted"
    echo ""
    echo "────────────────────────────────────────"
    echo "  Passed: ${PASS}  Failed: ${FAIL}"
    echo "────────────────────────────────────────"
    echo "m12 dogfood evidence document missing — all remaining checks skipped"
    exit 1
fi

# =============================================================================
# B. Contains RUN_SUMMARY section
# =============================================================================
echo ""
echo "=== B: document contains RUN_SUMMARY section ==="
if grep -qiE '(RUN_SUMMARY|run_summary|## Run Summary)' "$EVIDENCE_DOC"; then
    _pass "B: RUN_SUMMARY section found in $EVIDENCE_DOC"
else
    _fail "B: No RUN_SUMMARY section found — document may be truncated or incomplete (m12 acceptance criterion: captured RUN_SUMMARY.json)"
fi

# =============================================================================
# C. Contains cost / token usage information
# =============================================================================
echo ""
echo "=== C: document mentions total cost or token usage ==="
if grep -qiE '(total[ _]cost|token[ _]usage|cost:|tokens?[ _]used|usage_tokens|input_tokens|output_tokens)' "$EVIDENCE_DOC"; then
    _pass "C: cost or token usage found in $EVIDENCE_DOC"
else
    _fail "C: No cost or token usage information found — m12 acceptance criterion: total cost from Codex run must be recorded"
fi

# =============================================================================
# D. Contains a commit subject
# =============================================================================
echo ""
echo "=== D: document includes a commit subject ==="
if grep -qiE '(commit[ _]subject|## Commit|### Commit|git[ _]commit|feat:|fix:|refactor:|chore:)' "$EVIDENCE_DOC"; then
    _pass "D: commit subject found in $EVIDENCE_DOC"
else
    _fail "D: No commit subject found — m12 acceptance criterion: final commit subject must be recorded in dogfood evidence"
fi

# =============================================================================
# E. Structural completeness — at least 5 ## section headings
# =============================================================================
echo ""
echo "=== E: document has >= 5 ## section headings ==="
section_count=$(grep -cE '^## ' "$EVIDENCE_DOC" || true)
if [[ "$section_count" -ge 5 ]]; then
    _pass "E: $section_count ## sections found (>= 5 required for structural completeness)"
else
    _fail "E: only $section_count ## sections found — document appears truncated (need >= 5 per m12 spec: pipeline.conf, milestone, RUN_SUMMARY, commit, cost)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "m12 dogfood evidence document structure verified"
