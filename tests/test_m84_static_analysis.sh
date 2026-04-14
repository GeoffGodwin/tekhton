#!/usr/bin/env bash
# =============================================================================
# test_m84_static_analysis.sh — Regression guard: zero M84 literal filenames
# outside of config/default definitions
#
# Covers M84 acceptance criteria 2-5:
#  AC2: Zero literal occurrences of the 7 M84 filenames in lib/**/*.sh and
#       stages/**/*.sh (excluding config_defaults.sh and common.sh, which
#       intentionally carry the default assignments)
#  AC3: Specialist findings files use ${TEKHTON_DIR}/ prefix in their
#       dynamic construction (no bare SPECIALIST_*_FINDINGS.md)
#  AC4: All prompt templates use {{VAR}} refs; no literal M84 filenames
#  AC5: tekhton.sh carries zero literal Tekhton-managed M84 filenames
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

# The 7 M84 literal filenames whose hardcoded occurrences were eliminated
M84_FILES=(
    "SCOUT_REPORT.md"
    "ARCHITECT_PLAN.md"
    "CLEANUP_REPORT.md"
    "DRIFT_ARCHIVE.md"
    "PROJECT_INDEX.md"
    "REPLAN_DELTA.md"
    "MERGE_CONTEXT.md"
)

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "FAIL: $*"; }

# =============================================================================
# Suite 1: lib/**/*.sh — zero literal M84 filenames outside default definitions
#
# config_defaults.sh and common.sh are excluded: both intentionally carry the
# "${VAR:=${TEKHTON_DIR}/FILENAME.md}" default assignments. All other lib/
# files must use the config variable, not the literal filename.
# =============================================================================
echo "--- Suite 1: lib/**/*.sh — zero literal filenames (excl. default files) ---"

for fname in "${M84_FILES[@]}"; do
    matches=$(grep -r --include="*.sh" \
        --exclude="config_defaults.sh" \
        --exclude="common.sh" \
        "$fname" "${TEKHTON_HOME}/lib" 2>/dev/null || true)
    if [[ -z "$matches" ]]; then
        pass
    else
        fail "lib/ literal '${fname}' found outside defaults:"
        echo "$matches" | sed 's/^/      /'
    fi
done

# =============================================================================
# Suite 2: stages/**/*.sh — zero literal M84 filenames
# =============================================================================
echo "--- Suite 2: stages/**/*.sh — zero literal filenames ---"

for fname in "${M84_FILES[@]}"; do
    matches=$(grep -r --include="*.sh" \
        "$fname" "${TEKHTON_HOME}/stages" 2>/dev/null || true)
    if [[ -z "$matches" ]]; then
        pass
    else
        fail "stages/ literal '${fname}' found:"
        echo "$matches" | sed 's/^/      /'
    fi
done

# =============================================================================
# Suite 3: tekhton.sh — zero literal M84 filenames (AC5)
# =============================================================================
echo "--- Suite 3: tekhton.sh — zero literal filenames ---"

for fname in "${M84_FILES[@]}"; do
    matches=$(grep "$fname" "${TEKHTON_HOME}/tekhton.sh" 2>/dev/null || true)
    if [[ -z "$matches" ]]; then
        pass
    else
        fail "tekhton.sh literal '${fname}' found:"
        echo "$matches" | sed 's/^/      /'
    fi
done

# =============================================================================
# Suite 4: prompts/**/*.md — zero literal M84 filenames (AC4)
#
# All prompt templates that instruct agents to write files must use
# {{VAR}} substitution (e.g., {{SCOUT_REPORT_FILE}}).
# =============================================================================
echo "--- Suite 4: prompts/**/*.md — zero literal filenames, use {{VAR}} ---"

for fname in "${M84_FILES[@]}"; do
    matches=$(grep -r "$fname" "${TEKHTON_HOME}/prompts" 2>/dev/null || true)
    if [[ -z "$matches" ]]; then
        pass
    else
        fail "prompts/ literal '${fname}' found (should use {{VAR}}):"
        echo "$matches" | sed 's/^/      /'
    fi
done

# =============================================================================
# Suite 5: Specialist findings use ${TEKHTON_DIR}/ prefix (AC3)
#
# lib/specialists.sh and lib/specialists_helpers.sh must construct findings
# file paths using ${TEKHTON_DIR}/, not bare filenames at project root.
# =============================================================================
echo "--- Suite 5: specialist findings use TEKHTON_DIR prefix ---"

spec_helpers="${TEKHTON_HOME}/lib/specialists_helpers.sh"
spec_main="${TEKHTON_HOME}/lib/specialists.sh"

# 5.1: specialists_helpers.sh uses TEKHTON_DIR in findings path construction
TOTAL=$((TOTAL + 1))
if grep -q 'TEKHTON_DIR.*SPECIALIST.*FINDINGS\.md' "$spec_helpers" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 5.1 specialists_helpers.sh: no TEKHTON_DIR prefix in findings path"
fi

# 5.2: specialists.sh uses TEKHTON_DIR in findings path construction
TOTAL=$((TOTAL + 1))
if grep -q 'TEKHTON_DIR.*SPECIALIST.*FINDINGS\.md' "$spec_main" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 5.2 specialists.sh: no TEKHTON_DIR prefix in findings path"
fi

# 5.3: No bare SPECIALIST_*_FINDINGS.md without TEKHTON_DIR prefix
TOTAL=$((TOTAL + 1))
bare=$(grep -n 'SPECIALIST_[A-Z_]*FINDINGS\.md' "$spec_helpers" "$spec_main" 2>/dev/null \
    | grep -v 'TEKHTON_DIR' || true)
if [[ -z "$bare" ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: 5.3 specialist findings without TEKHTON_DIR prefix:"
    echo "$bare" | sed 's/^/      /'
fi

# =============================================================================
# Suite 6: common.sh defaults use ${TEKHTON_DIR}/ prefix (not bare filenames)
#
# The duplicate defaults in common.sh must follow the same pattern as
# config_defaults.sh: "${VAR:=${TEKHTON_DIR}/FILENAME.md}".
# This verifies the duplicates are correct, not bare path assignments.
# =============================================================================
echo "--- Suite 6: common.sh M84 defaults use \${TEKHTON_DIR}/ prefix ---"

common_sh="${TEKHTON_HOME}/lib/common.sh"

for fname in "${M84_FILES[@]}"; do
    TOTAL=$((TOTAL + 1))
    # The line must contain both the filename AND TEKHTON_DIR (as a default assignment)
    if grep -q "TEKHTON_DIR.*${fname}" "$common_sh" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: 6.x common.sh: '${fname}' default does not use \${TEKHTON_DIR}/ prefix"
    fi
done

# =============================================================================
# Results
# =============================================================================
echo
echo "=== M84 Static Analysis Tests: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
