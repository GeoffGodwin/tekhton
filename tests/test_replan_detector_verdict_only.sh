#!/usr/bin/env bash
# =============================================================================
# test_replan_detector_verdict_only.sh — m46 regression guard for the
# heading-anchored detect_replan_required.
#
# The pre-m46 implementation did `grep -qi "REPLAN_REQUIRED" "$report"`
# against the full reviewer-report body. The 2026-06-06 m37.2 auto-advance
# run hit a report whose verdict was APPROVED_WITH_NOTES but whose
# Non-Blocking Notes section mentioned REPLAN_REQUIRED three times. The
# body-grep false-positively opened the operator-override dialog AND
# tripped the commit gate, silently skipping every downstream commit in
# the m37.2 → m38.1 → m38.2 → m38.3 chain.
#
# Three scenarios:
#   1. Heading-anchored REPLAN_REQUIRED → detector returns 0.
#   2. APPROVED_WITH_NOTES with REPLAN_REQUIRED in non-blocking notes →
#      detector returns 1 (the regression guard).
#   3. Missing `## Verdict` heading, REPLAN_REQUIRED only in body →
#      detector returns 1 (heading-anchored extraction does NOT
#      fall through to the inline parser's greedy body match for the
#      override-dialog detector — distinct concerns).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export TEKHTON_HOME
export PROJECT_DIR="$TMPDIR"
export TEKHTON_SESSION_DIR="$TMPDIR"
export TEKHTON_TEST_MODE="true"
export TASK="m46 test"
export MILESTONE_MODE=""
export PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
export LOG_DIR="${TMPDIR}/.claude/logs"
export REPLAN_MODEL="opus"
export REPLAN_MAX_TURNS="5"
mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}"

# Stub logging functions so the dispatcher does not emit during tests.
# shellcheck disable=SC2317  # called indirectly via lib/replan*.sh
log()     { :; }
# shellcheck disable=SC2317
success() { :; }
# shellcheck disable=SC2317
warn()    { :; }
# shellcheck disable=SC2317
error()   { :; }
# shellcheck disable=SC2317
header()  { :; }
# shellcheck disable=SC2317
_safe_read_file() { cat "$1" 2>/dev/null || true; }
# shellcheck disable=SC2317
write_pipeline_state() { :; }

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null || true

# Re-stub after common.sh source so the silent stubs win over real impls.
# shellcheck disable=SC2317
log()     { :; }
# shellcheck disable=SC2317
success() { :; }
# shellcheck disable=SC2317
warn()    { :; }
# shellcheck disable=SC2317
error()   { :; }
# shellcheck disable=SC2317
header()  { :; }

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/state.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/replan.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ============================================================
# Scenario 1: Heading-anchored REPLAN_REQUIRED → detector returns 0
# ============================================================
echo '=== Scenario 1: ## Verdict + REPLAN_REQUIRED next line (heading-anchored) ==='

REPORT1="${TMPDIR}/report_scenario_1.md"
cat > "$REPORT1" << 'EOF'
# Reviewer Report

## Verdict
REPLAN_REQUIRED

## Rationale
- Scope contradicts the architecture
- Task is mis-scoped relative to the milestone
EOF

if detect_replan_required "$REPORT1"; then
    pass "Returns 0 when ## Verdict is REPLAN_REQUIRED"
else
    fail "Should return 0 when ## Verdict is REPLAN_REQUIRED"
fi

# ============================================================
# Scenario 1b: Inline ## Verdict REPLAN_REQUIRED (same line) → 0
# ============================================================
echo "=== Scenario 1b: ## Verdict REPLAN_REQUIRED (inline) ==="

REPORT1B="${TMPDIR}/report_scenario_1b.md"
cat > "$REPORT1B" << 'EOF'
# Reviewer Report

## Verdict REPLAN_REQUIRED

## Rationale
- Inline value on the same line as the heading.
EOF

if detect_replan_required "$REPORT1B"; then
    pass "Returns 0 when verdict is on the same line as the heading"
else
    fail "Should return 0 for inline ## Verdict REPLAN_REQUIRED"
fi

# ============================================================
# Scenario 2: APPROVED_WITH_NOTES + REPLAN_REQUIRED in NB notes → 1
# (the regression guard for the m37.2 false-positive)
# ============================================================
echo "=== Scenario 2: APPROVED_WITH_NOTES + REPLAN_REQUIRED in notes ==="

REPORT2="${TMPDIR}/report_scenario_2.md"
cat > "$REPORT2" << 'EOF'
# Reviewer Report

## Verdict
APPROVED_WITH_NOTES

## Non-Blocking Notes
- The replan dispatcher handles REPLAN_REQUIRED correctly.
- Inline mention of REPLAN_REQUIRED in coverage gap follow-up.
- Drift mentions REPLAN_REQUIRED as a possible future direction.

## Coverage Gaps
- The REPLAN_REQUIRED override-dialog input handling is untested.
EOF

if ! detect_replan_required "$REPORT2"; then
    pass "Returns 1 when verdict is APPROVED_WITH_NOTES despite body mentions"
else
    fail "REGRESSION: body-mention of REPLAN_REQUIRED falsely triggered the detector"
fi

# ============================================================
# Scenario 3: Missing `## Verdict` heading + REPLAN_REQUIRED in body → 1
# ============================================================
echo "=== Scenario 3: No ## Verdict heading; REPLAN_REQUIRED only in body ==="

REPORT3="${TMPDIR}/report_scenario_3.md"
cat > "$REPORT3" << 'EOF'
# Reviewer Report

(No verdict heading authored — the reviewer dropped the section.)

## Notes
- An unparsed report; mentions REPLAN_REQUIRED only as discussion text.
EOF

if ! detect_replan_required "$REPORT3"; then
    pass "Returns 1 when ## Verdict heading is missing (no fallthrough to body)"
else
    fail "Should return 1 when no ## Verdict heading present"
fi

# ============================================================
# Scenario 4: Lowercase replan_required under the heading → 0
# Case-insensitive on the value (mirrors the Go parser's strings.ToUpper).
# ============================================================
echo "=== Scenario 4: lowercase verdict under heading ==="

REPORT4="${TMPDIR}/report_scenario_4.md"
cat > "$REPORT4" << 'EOF'
# Reviewer Report

## Verdict
replan_required
EOF

if detect_replan_required "$REPORT4"; then
    pass "Case-insensitive verdict match on heading-anchored value"
else
    fail "Should match lowercase replan_required under the ## Verdict heading"
fi

# ============================================================
# Scenario 5: APPROVED under the heading → 1
# Baseline: non-REPLAN_REQUIRED verdict must not trigger.
# ============================================================
echo "=== Scenario 5: APPROVED verdict ==="

REPORT5="${TMPDIR}/report_scenario_5.md"
cat > "$REPORT5" << 'EOF'
# Reviewer Report

## Verdict
APPROVED
EOF

if ! detect_replan_required "$REPORT5"; then
    pass "Returns 1 for APPROVED verdict"
else
    fail "Should return 1 for APPROVED verdict"
fi

# ============================================================
# Scenario 6: REPLAN_ENABLED=false suppresses the detector entirely
# ============================================================
echo "=== Scenario 6: REPLAN_ENABLED=false suppression ==="

# shellcheck disable=SC2034  # consumed via env by detect_replan_required
REPLAN_ENABLED=false
if ! detect_replan_required "$REPORT1"; then
    pass "Returns 1 when REPLAN_ENABLED=false even for REPLAN_REQUIRED report"
else
    fail "Should return 1 when REPLAN_ENABLED=false"
fi
# shellcheck disable=SC2034
REPLAN_ENABLED=true

# ============================================================
# Summary
# ============================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
