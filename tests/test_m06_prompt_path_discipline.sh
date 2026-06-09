#!/usr/bin/env bash
# TIMEOUT_SECS=15
# =============================================================================
# test_m06_prompt_path_discipline.sh — m06 Goal B regression guard.
#
# What this test covers
# ---------------------
# Bug B from the V5 m04+m05 run: jr-coder agent wrote JR_CODER_SUMMARY.md to
# the repo root instead of .tekhton/JR_CODER_SUMMARY.md because the prompt
# used the {{JR_CODER_SUMMARY_FILE}} template variable which yields empty
# string when env propagation fails, causing the agent to improvise a path.
#
# m06 Goal B tightens both prompts to use explicit literal paths. This test
# verifies:
#
#  A. prompts/jr_coder.prompt.md contains the literal string
#     ".tekhton/JR_CODER_SUMMARY.md" so the agent always writes to the
#     canonical location even when env substitution fails.
#
#  B. prompts/coder.prompt.md contains the literal string
#     ".tekhton/CODER_SUMMARY.md" for the same reason.
#
# Acceptance criteria source:
#   grep -nE '\.tekhton/JR_CODER_SUMMARY\.md' prompts/jr_coder.prompt.md
#   grep -nE '\.tekhton/CODER_SUMMARY\.md'    prompts/coder.prompt.md
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
_pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

JR_PROMPT="${TEKHTON_HOME}/prompts/jr_coder.prompt.md"
CODER_PROMPT="${TEKHTON_HOME}/prompts/coder.prompt.md"

# =============================================================================
# A: jr_coder.prompt.md contains the literal canonical path
# =============================================================================
echo "=== A: jr_coder.prompt.md contains '.tekhton/JR_CODER_SUMMARY.md' ==="

if [[ ! -f "$JR_PROMPT" ]]; then
    _fail "A0: prompts/jr_coder.prompt.md does not exist"
else
    # A1: Literal path present.
    if grep -qE '\.tekhton/JR_CODER_SUMMARY\.md' "$JR_PROMPT"; then
        _pass "A1: '.tekhton/JR_CODER_SUMMARY.md' found in jr_coder.prompt.md"
    else
        _fail "A1: '.tekhton/JR_CODER_SUMMARY.md' absent from jr_coder.prompt.md (m06 Goal B not satisfied)"
    fi

    # A2: The path appears in a Write instruction context (not just a comment).
    if grep -E '\.tekhton/JR_CODER_SUMMARY\.md' "$JR_PROMPT" | grep -qiE 'write|canonical|location'; then
        _pass "A2: path appears alongside 'Write'/'canonical'/'location' instruction"
    else
        _fail "A2: path not found in a Write instruction context — defensive fallback may be missing"
    fi

    # A3: The template variable reference {{JR_CODER_SUMMARY_FILE}} still
    # appears — the prompt keeps the template var as a secondary reference
    # while the explicit path is the primary defensive instruction.
    # (This is a documentation sanity check, not a hard requirement.)
    if grep -q '{{JR_CODER_SUMMARY_FILE}}' "$JR_PROMPT"; then
        _pass "A3: {{JR_CODER_SUMMARY_FILE}} template var retained alongside explicit path"
    else
        # Non-fatal: the prompt is correct either way; template var removal is valid.
        echo "  NOTE A3: {{JR_CODER_SUMMARY_FILE}} not found — prompt may have dropped the template var (OK if explicit path is present)"
        PASS=$((PASS + 1))
    fi
fi

echo ""

# =============================================================================
# B: coder.prompt.md contains the literal canonical path
# =============================================================================
echo "=== B: coder.prompt.md contains '.tekhton/CODER_SUMMARY.md' ==="

if [[ ! -f "$CODER_PROMPT" ]]; then
    _fail "B0: prompts/coder.prompt.md does not exist"
else
    # B1: Literal path present.
    if grep -qE '\.tekhton/CODER_SUMMARY\.md' "$CODER_PROMPT"; then
        _pass "B1: '.tekhton/CODER_SUMMARY.md' found in coder.prompt.md"
    else
        _fail "B1: '.tekhton/CODER_SUMMARY.md' absent from coder.prompt.md (m06 Goal B not satisfied)"
    fi

    # B2: Path appears in Step 1 execution instruction.
    if grep -E '\.tekhton/CODER_SUMMARY\.md' "$CODER_PROMPT" | grep -qiE 'step 1|write|canonical|location'; then
        _pass "B2: path appears in Step 1 / Write instruction context"
    else
        _fail "B2: path not found in a Step 1 / Write instruction context — defensive fallback may be misplaced"
    fi

    # B3: The template variable {{CODER_SUMMARY_FILE}} still appears.
    if grep -q '{{CODER_SUMMARY_FILE}}' "$CODER_PROMPT"; then
        _pass "B3: {{CODER_SUMMARY_FILE}} template var retained alongside explicit path"
    else
        echo "  NOTE B3: {{CODER_SUMMARY_FILE}} not found — prompt may have dropped the template var (OK if explicit path is present)"
        PASS=$((PASS + 1))
    fi
fi

echo ""

# =============================================================================
# C: Shellcheck on this file (self-referential)
# =============================================================================
echo "=== C: Validate that prompts do not use {{VAR}} for the critical write path ==="

# C1: Confirm neither prompt instructs write via the template var ALONE on the
# critical write line — i.e. the line containing "Write" and "JR_CODER_SUMMARY"
# must NOT consist solely of the {{VAR}} form without an explicit path.
jr_write_line=$(grep -E 'Write.*JR_CODER_SUMMARY' "$JR_PROMPT" 2>/dev/null | head -1 || true)
if [[ -n "$jr_write_line" ]]; then
    if echo "$jr_write_line" | grep -q '\.tekhton/JR_CODER_SUMMARY'; then
        _pass "C1: jr_coder Write line includes literal '.tekhton/JR_CODER_SUMMARY.md'"
    else
        _fail "C1: jr_coder Write line does not include literal path — only template var (regression: m06 Bug B pattern)"
    fi
else
    # The write instruction spans multiple lines — A1 already confirmed the path exists.
    _pass "C1: Write instruction and path are on separate lines (A1 already confirmed path present)"
fi

coder_write_line=$(grep -E 'Write.*CODER_SUMMARY' "$CODER_PROMPT" 2>/dev/null | head -1 || true)
if [[ -n "$coder_write_line" ]]; then
    if echo "$coder_write_line" | grep -q '\.tekhton/CODER_SUMMARY'; then
        _pass "C2: coder Write line includes literal '.tekhton/CODER_SUMMARY.md'"
    else
        _fail "C2: coder Write line does not include literal path — only template var (regression: m06 Bug B pattern)"
    fi
else
    _pass "C2: Write instruction and path are on separate lines (B1 already confirmed path present)"
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
echo "m06 prompt path discipline regression guard passed"
