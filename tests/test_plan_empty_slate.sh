#!/usr/bin/env bash
# Test: M121 — --init → --plan empty-slate integration flow.
#
# Verifies:
#   1. `tekhton --init` on a fresh directory emits the canonical
#      DESIGN_FILE=".tekhton/DESIGN.md" default (M120's root-cause fix).
#   2. run_plan_interview with that config writes a non-empty
#      .tekhton/DESIGN.md file (no silent failure, no zero-byte output).
#   3. _assert_design_file_usable passes at the moment of write.
#   4. Negative: a pipeline.conf with `DESIGN_FILE=""` still round-trips
#      cleanly because M120 + M121 self-heal the empty value.
#
# Exercises lib/plan.sh, lib/artifact_defaults.sh, stages/plan_interview.sh.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Run run_plan_interview() with a stubbed _call_planning_batch to exercise
# the real shell write path without invoking the claude CLI.
# Arguments:
#   $1  project_dir  — PROJECT_DIR to use
#   $2  design_file  — DESIGN_FILE override (pipeline.conf value)
#   $3  stub_content — content the stub batch function should produce
# Prints: exit code of run_plan_interview to stdout (0 or 1).
_run_interview_stubbed() {
    local project_dir="$1"
    local design_file_val="$2"
    local stub_content="$3"

    local script_file
    script_file=$(mktemp "${TMPDIR_BASE}/run_int_XXXXXX.sh")

    cat > "$script_file" << 'INNERSCRIPT'
#!/usr/bin/env bash
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"
source "${TEKHTON_HOME}/lib/plan_state.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR:-.tekhton}"

# Stub: avoids real claude invocation, returns the content in STUB_CONTENT.
_call_planning_batch() {
    printf '%s\n' "${STUB_CONTENT}"
    return 0
}

source "${TEKHTON_HOME}/stages/plan_interview.sh"

run_plan_interview > /dev/null 2>&1 && echo 0 || echo 1
INNERSCRIPT

    PROJECT_DIR="$project_dir" \
    TEKHTON_DIR=".tekhton" \
    DESIGN_FILE="$design_file_val" \
    PLAN_TEMPLATE_FILE="${TEKHTON_HOME}/tests/fixtures/plan_test_template.md" \
    PLAN_PROJECT_TYPE="web-app" \
    PLAN_INTERVIEW_MODEL="test-model" \
    PLAN_INTERVIEW_MAX_TURNS="5" \
    PROJECT_TYPE="web-app" \
    TEKHTON_TEST_MODE=1 \
    STUB_CONTENT="$stub_content" \
    bash "$script_file" 2>/dev/null < /dev/null
}

# ---------------------------------------------------------------------------
echo "=== Test 1: Fresh --init emits canonical DESIGN_FILE default ==="

proj_fresh="${TMPDIR_BASE}/fresh"
mkdir -p "$proj_fresh"
(cd "$proj_fresh" && TEKHTON_NON_INTERACTIVE=true bash "${TEKHTON_HOME}/tekhton.sh" --init >/dev/null 2>&1) || true

if [[ -f "${proj_fresh}/.claude/pipeline.conf" ]]; then
    pass "pipeline.conf created by --init"
else
    fail "pipeline.conf missing after --init"
fi

design_file_value=$(grep '^DESIGN_FILE=' "${proj_fresh}/.claude/pipeline.conf" 2>/dev/null \
    | head -1 | cut -d= -f2 | tr -d '"')
if [[ "$design_file_value" == ".tekhton/DESIGN.md" ]]; then
    pass "pipeline.conf sets DESIGN_FILE to canonical default"
else
    fail "expected DESIGN_FILE='.tekhton/DESIGN.md', got '${design_file_value}'"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Test 2: --plan round-trip produces non-zero DESIGN.md ==="

proj_roundtrip="${TMPDIR_BASE}/roundtrip"
mkdir -p "$proj_roundtrip"
stub_content='# DESIGN — Round-Trip

## Overview
Integration test stub content. Non-zero bytes.'

rc=$(_run_interview_stubbed "$proj_roundtrip" ".tekhton/DESIGN.md" "$stub_content")
if [[ "$rc" == "0" ]]; then
    pass "run_plan_interview returned 0 with canonical DESIGN_FILE"
else
    fail "run_plan_interview returned ${rc}, expected 0"
fi

design_path="${proj_roundtrip}/.tekhton/DESIGN.md"
if [[ -f "$design_path" ]]; then
    pass ".tekhton/DESIGN.md written to disk"
else
    fail ".tekhton/DESIGN.md missing at ${design_path}"
fi

if [[ -s "$design_path" ]]; then
    pass ".tekhton/DESIGN.md has non-zero size"
else
    fail ".tekhton/DESIGN.md is empty (zero bytes)"
fi

if [[ -f "$design_path" ]] && grep -q 'Round-Trip' "$design_path"; then
    pass ".tekhton/DESIGN.md contains stubbed content"
else
    fail ".tekhton/DESIGN.md missing stubbed content"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Test 3: pipeline.conf with DESIGN_FILE=\"\" self-heals ==="

# With DESIGN_FILE="" in the environment (simulating a pre-M120 pipeline.conf
# value surviving load_plan_config), lib/plan.sh re-sources artifact_defaults.sh
# and :=-heals the empty value back to the canonical default. The interview
# should then write to .tekhton/DESIGN.md, and _assert_design_file_usable
# should NOT fire.
proj_empty="${TMPDIR_BASE}/empty_value"
mkdir -p "$proj_empty"

rc=$(_run_interview_stubbed "$proj_empty" "" "$stub_content")
if [[ "$rc" == "0" ]]; then
    pass "run_plan_interview succeeded with empty-string DESIGN_FILE (self-healed)"
else
    fail "run_plan_interview returned ${rc}, expected 0 (M120+M121 self-heal)"
fi

healed_path="${proj_empty}/.tekhton/DESIGN.md"
if [[ -f "$healed_path" ]] && [[ -s "$healed_path" ]]; then
    pass "self-healed DESIGN_FILE produced a non-zero file at canonical path"
else
    fail "self-healed DESIGN_FILE did not produce expected output at ${healed_path}"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
