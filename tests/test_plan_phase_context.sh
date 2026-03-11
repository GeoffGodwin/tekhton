#!/usr/bin/env bash
# Test: _build_phase_context() in stages/plan_interview.sh
# Verifies that phase context summaries include only prior-phase answers
# and exclude SKIP, TBD, and empty entries.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Setup: source libraries in a subshell wrapper to avoid polluting test env.
# _build_phase_context uses bash namerefs (local -n), so it must be called
# in the same shell that defined the arrays.
# ---------------------------------------------------------------------------

export PROJECT_DIR="$TMPDIR_BASE"
export TEKHTON_HOME

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/stages/plan_interview.sh"

# ---------------------------------------------------------------------------
echo "=== Includes prior-phase answers when max_phase=2 ==="

names_a=("Overview" "Tech Stack" "Core Features")
answers_a=("A web app for teams" "React and Node.js" "Authentication module")
phases_a=("1" "1" "2")

result_a=$(_build_phase_context names_a answers_a phases_a 2)

if echo "$result_a" | grep -q "Overview"; then
    pass "Phase 1 'Overview' answer included when max_phase=2"
else
    fail "Phase 1 'Overview' answer missing when max_phase=2: '${result_a}'"
fi

if echo "$result_a" | grep -q "Tech Stack"; then
    pass "Phase 1 'Tech Stack' answer included when max_phase=2"
else
    fail "Phase 1 'Tech Stack' answer missing when max_phase=2"
fi

if echo "$result_a" | grep -q "Core Features"; then
    fail "Phase 2 'Core Features' incorrectly included when max_phase=2 (same phase should be excluded)"
else
    pass "Phase 2 'Core Features' excluded when max_phase=2 (correct: same phase not shown)"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Excludes SKIP answers ==="

names_b=("Overview" "Tech Stack")
answers_b=("SKIP" "React and Node.js")
phases_b=("1" "1")

result_b=$(_build_phase_context names_b answers_b phases_b 2)

if echo "$result_b" | grep -q "Overview"; then
    fail "SKIP answer for 'Overview' incorrectly included in context"
else
    pass "SKIP answer excluded from context"
fi

if echo "$result_b" | grep -q "Tech Stack"; then
    pass "Non-SKIP 'Tech Stack' answer included alongside SKIP entry"
else
    fail "Non-SKIP 'Tech Stack' answer missing"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Excludes TBD answers ==="

names_c=("Overview" "Philosophy")
answers_c=("TBD" "Config-driven from day one")
phases_c=("1" "1")

result_c=$(_build_phase_context names_c answers_c phases_c 2)

if echo "$result_c" | grep -q "Overview"; then
    fail "TBD answer for 'Overview' incorrectly included in context"
else
    pass "TBD answer excluded from context"
fi

if echo "$result_c" | grep -q "Philosophy"; then
    pass "Non-TBD 'Philosophy' answer included alongside TBD entry"
else
    fail "Non-TBD 'Philosophy' answer missing"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Excludes empty answers ==="

names_d=("Overview" "Tech Stack")
answers_d=("" "React and Node.js")
phases_d=("1" "1")

result_d=$(_build_phase_context names_d answers_d phases_d 2)

if echo "$result_d" | grep -q "\*\*Overview\*\*"; then
    fail "Empty answer for 'Overview' incorrectly included in context"
else
    pass "Empty answer excluded from context"
fi

if echo "$result_d" | grep -q "Tech Stack"; then
    pass "Non-empty 'Tech Stack' answer included alongside empty entry"
else
    fail "Non-empty 'Tech Stack' answer missing"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Output uses bold markdown formatting ==="

names_e=("Project Overview")
answers_e=("A web app for teams")
phases_e=("1")

result_e=$(_build_phase_context names_e answers_e phases_e 2)

if echo "$result_e" | grep -q "\*\*Project Overview\*\*"; then
    pass "Section name wrapped in bold markdown (**Name**)"
else
    fail "Section name not wrapped in bold markdown: '${result_e}'"
fi

if echo "$result_e" | grep -q "A web app for teams"; then
    pass "Answer value appears after section name"
else
    fail "Answer value missing from output: '${result_e}'"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Returns empty string when no prior-phase answers exist ==="

names_f=("Core Features")
answers_f=("Authentication and login")
phases_f=("2")

result_f=$(_build_phase_context names_f answers_f phases_f 2)
stripped_f=$(echo "$result_f" | tr -d '[:space:]')

if [[ -z "$stripped_f" ]]; then
    pass "Empty output when all answers are from current or later phase"
else
    fail "Unexpected output when no prior-phase answers: '${result_f}'"
fi

# ---------------------------------------------------------------------------
echo
echo "=== max_phase=3 includes phases 1 and 2, excludes phase 3 ==="

names_g=("Overview" "Core Features" "Config Architecture")
answers_g=("A web app" "Auth module" "JSON config file")
phases_g=("1" "2" "3")

result_g=$(_build_phase_context names_g answers_g phases_g 3)

if echo "$result_g" | grep -q "Overview"; then
    pass "Phase 1 answer included when max_phase=3"
else
    fail "Phase 1 answer missing when max_phase=3"
fi

if echo "$result_g" | grep -q "Core Features"; then
    pass "Phase 2 answer included when max_phase=3"
else
    fail "Phase 2 answer missing when max_phase=3"
fi

if echo "$result_g" | grep -q "Config Architecture"; then
    fail "Phase 3 'Config Architecture' incorrectly included when max_phase=3"
else
    pass "Phase 3 'Config Architecture' excluded when max_phase=3"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Returns empty string when all answers are SKIP or TBD ==="

names_h=("Overview" "Tech Stack")
answers_h=("SKIP" "TBD")
phases_h=("1" "1")

result_h=$(_build_phase_context names_h answers_h phases_h 2)
stripped_h=$(echo "$result_h" | tr -d '[:space:]')

if [[ -z "$stripped_h" ]]; then
    pass "Empty output when all answers are SKIP or TBD"
else
    fail "Unexpected non-empty output when all answers are SKIP/TBD: '${result_h}'"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
