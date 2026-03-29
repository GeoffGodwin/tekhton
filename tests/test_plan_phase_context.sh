#!/usr/bin/env bash
# Test: _build_phase_context() in stages/plan_interview.sh
# Verifies that phase context summaries include only prior-phase answers
# and exclude SKIP, TBD, and empty entries.
#
# Updated for M31: _build_phase_context now reads from the YAML answer layer
# rather than taking nameref arrays. Takes a single arg (max_phase).
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Setup: source libraries, create a test template and answer file.
# ---------------------------------------------------------------------------

export PROJECT_DIR="$TMPDIR_BASE"
export PLAN_ANSWER_FILE="${TMPDIR_BASE}/.claude/plan_answers.yaml"
export TEKHTON_VERSION="3.31.0"
export TEKHTON_HOME

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/plan_answers.sh"
source "${TEKHTON_HOME}/stages/plan_interview.sh"

# Create a test template
TEST_TEMPLATE="${TMPDIR_BASE}/template.md"
cat > "$TEST_TEMPLATE" << 'EOF'
# Design Document — Test

## Overview
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Describe the project -->

## Tech Stack
<!-- PHASE:1 -->
<!-- Languages and frameworks -->

## Core Features
<!-- PHASE:2 -->
<!-- List features -->

## Config Architecture
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- Configuration details -->
EOF

PLAN_TEMPLATE_FILE="$TEST_TEMPLATE"
PLAN_PROJECT_TYPE="test"

# Helper: create answer file with specific answers
setup_answers() {
    init_answer_file "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
    local overview_ans="${1:-}"
    local techstack_ans="${2:-}"
    local features_ans="${3:-}"
    local config_ans="${4:-}"

    if [[ -n "$overview_ans" ]]; then
        save_answer "overview" "$overview_ans"
    fi
    if [[ -n "$techstack_ans" ]]; then
        save_answer "tech_stack" "$techstack_ans"
    fi
    if [[ -n "$features_ans" ]]; then
        save_answer "core_features" "$features_ans"
    fi
    if [[ -n "$config_ans" ]]; then
        save_answer "config_architecture" "$config_ans"
    fi
}

# ---------------------------------------------------------------------------
echo "=== Includes prior-phase answers when max_phase=2 ==="

setup_answers "A web app for teams" "React and Node.js" "Authentication module" ""

result_a=$(_build_phase_context 2)

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

setup_answers "SKIP" "React and Node.js" "" ""

result_b=$(_build_phase_context 2)

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

setup_answers "TBD" "" "" ""
save_answer "tech_stack" "Config-driven from day one"

result_c=$(_build_phase_context 2)

if echo "$result_c" | grep -q "Overview"; then
    fail "TBD answer for 'Overview' incorrectly included in context"
else
    pass "TBD answer excluded from context"
fi

if echo "$result_c" | grep -q "Tech Stack"; then
    pass "Non-TBD 'Tech Stack' answer included alongside TBD entry"
else
    fail "Non-TBD 'Tech Stack' answer missing"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Excludes empty answers ==="

setup_answers "" "React and Node.js" "" ""

result_d=$(_build_phase_context 2)

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

setup_answers "A web app for teams" "" "" ""

result_e=$(_build_phase_context 2)

if echo "$result_e" | grep -q "\*\*Overview\*\*"; then
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

setup_answers "" "" "Authentication and login" ""

result_f=$(_build_phase_context 2)
stripped_f=$(echo "$result_f" | tr -d '[:space:]')

if [[ -z "$stripped_f" ]]; then
    pass "Empty output when all answers are from current or later phase"
else
    fail "Unexpected output when no prior-phase answers: '${result_f}'"
fi

# ---------------------------------------------------------------------------
echo
echo "=== max_phase=3 includes phases 1 and 2, excludes phase 3 ==="

setup_answers "A web app" "" "" "JSON config file"
save_answer "core_features" "Auth module"

result_g=$(_build_phase_context 3)

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

setup_answers "SKIP" "TBD" "" ""

result_h=$(_build_phase_context 2)
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
