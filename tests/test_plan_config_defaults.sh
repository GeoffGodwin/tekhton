#!/usr/bin/env bash
# Test: lib/plan.sh — config defaults and environment variable overrides
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Each default/override test runs in an isolated subshell to avoid
# polluting exported variables between cases.

echo "=== Config Defaults ==="

model=$(
    unset CLAUDE_PLAN_MODEL 2>/dev/null || true
    unset PLAN_INTERVIEW_MAX_TURNS 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    echo "$PLAN_INTERVIEW_MODEL"
)

if [ "$model" = "sonnet" ]; then
    pass "default PLAN_INTERVIEW_MODEL is 'sonnet'"
else
    fail "expected PLAN_INTERVIEW_MODEL='sonnet', got '${model}'"
fi

max_turns=$(
    unset CLAUDE_PLAN_MODEL 2>/dev/null || true
    unset PLAN_INTERVIEW_MAX_TURNS 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    echo "$PLAN_INTERVIEW_MAX_TURNS"
)

if [ "$max_turns" = "50" ]; then
    pass "default PLAN_INTERVIEW_MAX_TURNS is 50"
else
    fail "expected PLAN_INTERVIEW_MAX_TURNS='50', got '${max_turns}'"
fi

echo
echo "=== Environment Variable Overrides ==="

model_override=$(
    CLAUDE_PLAN_MODEL="opus"
    unset PLAN_INTERVIEW_MAX_TURNS 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    echo "$PLAN_INTERVIEW_MODEL"
)

if [ "$model_override" = "opus" ]; then
    pass "CLAUDE_PLAN_MODEL=opus override is respected"
else
    fail "CLAUDE_PLAN_MODEL override failed, got '${model_override}'"
fi

model_haiku=$(
    CLAUDE_PLAN_MODEL="haiku"
    unset PLAN_INTERVIEW_MAX_TURNS 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    echo "$PLAN_INTERVIEW_MODEL"
)

if [ "$model_haiku" = "haiku" ]; then
    pass "CLAUDE_PLAN_MODEL=haiku override is respected"
else
    fail "CLAUDE_PLAN_MODEL=haiku override failed, got '${model_haiku}'"
fi

turns_override=$(
    unset CLAUDE_PLAN_MODEL 2>/dev/null || true
    PLAN_INTERVIEW_MAX_TURNS="100"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    echo "$PLAN_INTERVIEW_MAX_TURNS"
)

if [ "$turns_override" = "100" ]; then
    pass "PLAN_INTERVIEW_MAX_TURNS=100 override is respected"
else
    fail "PLAN_INTERVIEW_MAX_TURNS override failed, got '${turns_override}'"
fi

turns_custom=$(
    unset CLAUDE_PLAN_MODEL 2>/dev/null || true
    PLAN_INTERVIEW_MAX_TURNS="25"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    echo "$PLAN_INTERVIEW_MAX_TURNS"
)

if [ "$turns_custom" = "25" ]; then
    pass "PLAN_INTERVIEW_MAX_TURNS=25 override is respected"
else
    fail "PLAN_INTERVIEW_MAX_TURNS=25 override failed, got '${turns_custom}'"
fi

echo
echo "=== Generation Config Defaults ==="

gen_model=$(
    unset CLAUDE_PLAN_MODEL 2>/dev/null || true
    unset PLAN_GENERATION_MAX_TURNS 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    echo "$PLAN_GENERATION_MODEL"
)

if [ "$gen_model" = "sonnet" ]; then
    pass "default PLAN_GENERATION_MODEL is 'sonnet'"
else
    fail "expected PLAN_GENERATION_MODEL='sonnet', got '${gen_model}'"
fi

gen_turns=$(
    unset CLAUDE_PLAN_MODEL 2>/dev/null || true
    unset PLAN_GENERATION_MAX_TURNS 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    echo "$PLAN_GENERATION_MAX_TURNS"
)

if [ "$gen_turns" = "30" ]; then
    pass "default PLAN_GENERATION_MAX_TURNS is 30"
else
    fail "expected PLAN_GENERATION_MAX_TURNS='30', got '${gen_turns}'"
fi

gen_model_override=$(
    CLAUDE_PLAN_MODEL="opus"
    unset PLAN_GENERATION_MAX_TURNS 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    echo "$PLAN_GENERATION_MODEL"
)

if [ "$gen_model_override" = "opus" ]; then
    pass "CLAUDE_PLAN_MODEL=opus override applies to PLAN_GENERATION_MODEL"
else
    fail "CLAUDE_PLAN_MODEL override for generation failed, got '${gen_model_override}'"
fi

gen_turns_override=$(
    unset CLAUDE_PLAN_MODEL 2>/dev/null || true
    PLAN_GENERATION_MAX_TURNS="20"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/plan.sh"
    echo "$PLAN_GENERATION_MAX_TURNS"
)

if [ "$gen_turns_override" = "20" ]; then
    pass "PLAN_GENERATION_MAX_TURNS=20 override is respected"
else
    fail "PLAN_GENERATION_MAX_TURNS override failed, got '${gen_turns_override}'"
fi

echo
echo "=== Project Type Constants ==="

# Source once for remaining structural checks
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/plan.sh"

expected_types=("web-app" "web-game" "cli-tool" "api-service" "mobile-app" "library" "custom")

for t in "${expected_types[@]}"; do
    found=false
    for defined in "${PLAN_PROJECT_TYPES[@]}"; do
        if [ "$defined" = "$t" ]; then
            found=true
            break
        fi
    done
    if $found; then
        pass "project type '${t}' in PLAN_PROJECT_TYPES"
    else
        fail "project type '${t}' missing from PLAN_PROJECT_TYPES"
    fi
done

type_count="${#PLAN_PROJECT_TYPES[@]}"
if [ "$type_count" -eq 7 ]; then
    pass "exactly 7 project types defined"
else
    fail "expected 7 project types, found ${type_count}"
fi

label_count="${#PLAN_PROJECT_LABELS[@]}"
if [ "$label_count" -eq "$type_count" ]; then
    pass "PLAN_PROJECT_LABELS count (${label_count}) matches PLAN_PROJECT_TYPES count"
else
    fail "label count (${label_count}) does not match type count (${type_count})"
fi

echo
echo "=== Template Directory ==="

if [ "${PLAN_TEMPLATES_DIR}" = "${TEKHTON_HOME}/templates/plans" ]; then
    pass "PLAN_TEMPLATES_DIR resolves to correct path"
else
    fail "PLAN_TEMPLATES_DIR='${PLAN_TEMPLATES_DIR}', expected '${TEKHTON_HOME}/templates/plans'"
fi

# Each project type must have a corresponding template file
for t in "${PLAN_PROJECT_TYPES[@]}"; do
    template_file="${PLAN_TEMPLATES_DIR}/${t}.md"
    if [ -f "$template_file" ]; then
        pass "template file exists for '${t}'"
    else
        fail "template file missing for '${t}': ${template_file}"
    fi
done

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
