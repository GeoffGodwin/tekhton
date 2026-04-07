#!/usr/bin/env bash
# Test: Phase-transition flow in run_plan_interview()
#
# Verifies that:
#   1. Phase 1 header fires before the first section is presented
#   2. Phase 2 header fires when the first Phase 2 section is reached
#   3. Phase 3 header fires when the first Phase 3 section is reached
#   4. Prior-phase context block appears at the Phase 2 transition
#      when Phase 1 answers are non-empty
#   5. Context block is omitted when all Phase 1 answers are SKIP/TBD
#
# Uses the test fixture: tests/fixtures/plan_test_template.md
# Sections: Overview (P1, REQUIRED), Tech Stack (P1), Core Features (P2),
#           Config Architecture (P3, REQUIRED)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# build_interview_script — Write the inner bash script to a temp file.
# The script sources libraries, mocks _call_planning_batch, and calls
# run_plan_interview with stderr suppressed.
# ---------------------------------------------------------------------------
build_interview_script() {
    local script_file="$1"
    cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"
source "${TEKHTON_HOME}/lib/plan.sh"
source "${TEKHTON_HOME}/lib/plan_answers.sh"
source "${TEKHTON_HOME}/lib/plan_review.sh"

# Mock _call_planning_batch — avoids real claude invocation.
_call_planning_batch() {
    printf '# DESIGN.md\n\nMock content.\n'
    return 0
}

source "${TEKHTON_HOME}/stages/plan_interview.sh"

# Redirect stderr so prompts/guidance from _read_section_answer don't
# pollute the captured stdout used for phase-header assertions.
run_plan_interview 2>/dev/null
INNERSCRIPT
}

# ---------------------------------------------------------------------------
# run_interview_with_input — Run run_plan_interview() and capture stdout.
#
# _read_section_answer() reads from a dedicated fd (fd 3) opened by
# run_plan_interview via exec 3<&0.  Fd inheritance across fork() guarantees
# correct position sharing regardless of whether stdin is a pipe or file.
#
# Arguments:
#   $1  project_dir    — isolated PROJECT_DIR for this run
#   $2  input_string   — all section answers in sequence (printf-ready)
#
# Prints captured stdout (phase headers, context lines, section banners).
# ---------------------------------------------------------------------------
run_interview_with_input() {
    local project_dir="$1"
    local input_string="$2"

    local script_file
    script_file=$(mktemp "${TMPDIR_BASE}/interview_XXXXXX.sh")
    build_interview_script "$script_file"

    # Feed input via process substitution (pipe).
    TEKHTON_HOME="$TEKHTON_HOME" \
    PROJECT_DIR="$project_dir" \
    PLAN_ANSWER_FILE="${project_dir}/.claude/plan_answers.yaml" \
    PLAN_TEMPLATE_FILE="${TEKHTON_HOME}/tests/fixtures/plan_test_template.md" \
    PLAN_PROJECT_TYPE="web-app" \
    PLAN_INTERVIEW_MODEL="test-model" \
    PLAN_INTERVIEW_MAX_TURNS="5" \
    TEKHTON_VERSION="3.31.0" \
    TEKHTON_TEST_MODE=1 \
    bash "$script_file" < <(printf '%s' "$input_string") 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Input strings for the four sections in the test fixture:
#   Overview       — Phase 1, REQUIRED
#   Tech Stack     — Phase 1, optional
#   Core Features  — Phase 2, optional
#   Config Architecture — Phase 3, REQUIRED
#
# Each section: answer text + blank line (or just "skip\n\n") to submit.
# ---------------------------------------------------------------------------

# All sections skipped — drives every section to SKIP/TBD quickly.
# Prepend "1\n" for CLI mode selection in _select_interview_mode
ALL_SKIP=$'1\nskip\n\nskip\n\nskip\n\nskip\n\n'

# Phase 1 'Overview' has a real answer; everything else skipped.
WITH_P1_ANSWER=$'1\nMy overview answer\n\nskip\n\nskip\n\nMy config answer\n\n'

# ---------------------------------------------------------------------------
echo "=== Phase 1 header fires before the first section ==="

proj_a="${TMPDIR_BASE}/proj_a"
mkdir -p "$proj_a"
output_a=$(run_interview_with_input "$proj_a" "$ALL_SKIP")

if echo "$output_a" | grep -q "Phase 1: Concept Capture"; then
    pass "Phase 1 header 'Phase 1: Concept Capture' appears in output"
else
    fail "Phase 1 header not found in output"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Phase 2 header fires at the first Phase 2 section ==="

proj_b="${TMPDIR_BASE}/proj_b"
mkdir -p "$proj_b"
output_b=$(run_interview_with_input "$proj_b" "$ALL_SKIP")

if echo "$output_b" | grep -q "Phase 2: System Deep-Dive"; then
    pass "Phase 2 header 'Phase 2: System Deep-Dive' appears in output"
else
    fail "Phase 2 header not found in output"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Phase 3 header fires at the first Phase 3 section ==="

proj_c="${TMPDIR_BASE}/proj_c"
mkdir -p "$proj_c"
output_c=$(run_interview_with_input "$proj_c" "$ALL_SKIP")

if echo "$output_c" | grep -q "Phase 3: Architecture"; then
    pass "Phase 3 header 'Phase 3: Architecture...' appears in output"
else
    fail "Phase 3 header not found in output"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Phase headers appear in correct order (1 before 2 before 3) ==="

proj_d="${TMPDIR_BASE}/proj_d"
mkdir -p "$proj_d"
output_d=$(run_interview_with_input "$proj_d" "$ALL_SKIP")

pos1=$(echo "$output_d" | grep -n "Phase 1:" | head -1 | cut -d: -f1 || echo "0")
pos2=$(echo "$output_d" | grep -n "Phase 2:" | head -1 | cut -d: -f1 || echo "0")
pos3=$(echo "$output_d" | grep -n "Phase 3:" | head -1 | cut -d: -f1 || echo "0")

if [[ "$pos1" -gt 0 ]] && [[ "$pos2" -gt "$pos1" ]] && [[ "$pos3" -gt "$pos2" ]]; then
    pass "Phase headers in correct order: Ph1@${pos1}, Ph2@${pos2}, Ph3@${pos3}"
else
    fail "Phase headers out of order — Ph1@${pos1}, Ph2@${pos2}, Ph3@${pos3}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Context block appears at Phase 2 transition when Phase 1 has real answers ==="

proj_e="${TMPDIR_BASE}/proj_e"
mkdir -p "$proj_e"
output_e=$(run_interview_with_input "$proj_e" "$WITH_P1_ANSWER")

if echo "$output_e" | grep -q "Your answers so far"; then
    pass "'Your answers so far' context header appears at Phase 2 transition"
else
    fail "'Your answers so far' not found — context block missing when Phase 1 answered"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Context block includes Phase 1 answer text ==="

if echo "$output_e" | grep -q "My overview answer"; then
    pass "Phase 1 answer text 'My overview answer' appears in context block"
else
    fail "Phase 1 answer text not found in context block"
fi

if echo "$output_e" | grep -q "Overview"; then
    pass "Section name 'Overview' appears in context block"
else
    fail "'Overview' section name missing from context block"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Context block NOT shown when all Phase 1 answers are skipped ==="

proj_f="${TMPDIR_BASE}/proj_f"
mkdir -p "$proj_f"
output_f=$(run_interview_with_input "$proj_f" "$ALL_SKIP")

if echo "$output_f" | grep -q "Your answers so far"; then
    fail "'Your answers so far' shown even though all Phase 1 answers were skipped"
else
    pass "Context block correctly omitted when all Phase 1 answers are skipped"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Section banners display the correct section names ==="

proj_g="${TMPDIR_BASE}/proj_g"
mkdir -p "$proj_g"
output_g=$(run_interview_with_input "$proj_g" "$ALL_SKIP")

if echo "$output_g" | grep -q "Overview"; then
    pass "Section banner shows 'Overview'"
else
    fail "'Overview' missing from section banners"
fi

if echo "$output_g" | grep -q "Core Features"; then
    pass "Section banner shows 'Core Features'"
else
    fail "'Core Features' missing from section banners"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
