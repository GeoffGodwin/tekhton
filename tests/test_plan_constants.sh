#!/usr/bin/env bash
# Test: Planning phase array constants — lengths, slug/label parity, slug-to-filename mapping
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Source plan.sh to load the arrays (common.sh needed for header/log/etc.)
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/plan.sh"

echo "=== Array Lengths ==="

types_count="${#PLAN_PROJECT_TYPES[@]}"
labels_count="${#PLAN_PROJECT_LABELS[@]}"

if [ "$types_count" -eq 7 ]; then
    pass "PLAN_PROJECT_TYPES has 7 entries"
else
    fail "PLAN_PROJECT_TYPES: expected 7, got ${types_count}"
fi

if [ "$labels_count" -eq 7 ]; then
    pass "PLAN_PROJECT_LABELS has 7 entries"
else
    fail "PLAN_PROJECT_LABELS: expected 7, got ${labels_count}"
fi

if [ "$types_count" -eq "$labels_count" ]; then
    pass "PLAN_PROJECT_TYPES and PLAN_PROJECT_LABELS are the same length"
else
    fail "Array length mismatch: types=${types_count} labels=${labels_count}"
fi

echo
echo "=== Slug-to-Filename Mapping ==="

for slug in "${PLAN_PROJECT_TYPES[@]}"; do
    tmpl="${PLAN_TEMPLATES_DIR}/${slug}.md"
    if [ -f "$tmpl" ]; then
        pass "Slug '${slug}' → '${tmpl}' exists"
    else
        fail "Slug '${slug}' → '${tmpl}' does NOT exist"
    fi
done

echo
echo "=== PLAN_TEMPLATES_DIR Points to templates/plans ==="

expected_dir="${TEKHTON_HOME}/templates/plans"
if [ "$PLAN_TEMPLATES_DIR" = "$expected_dir" ]; then
    pass "PLAN_TEMPLATES_DIR='${PLAN_TEMPLATES_DIR}'"
else
    fail "PLAN_TEMPLATES_DIR: expected '${expected_dir}', got '${PLAN_TEMPLATES_DIR}'"
fi

echo
echo "=== Known Type Order ==="

# Verify order is deterministic and matches the documented menu order
known_order=("web-app" "web-game" "cli-tool" "api-service" "mobile-app" "library" "custom")
for i in "${!known_order[@]}"; do
    if [ "${PLAN_PROJECT_TYPES[$i]}" = "${known_order[$i]}" ]; then
        pass "Position $((i + 1)): '${PLAN_PROJECT_TYPES[$i]}'"
    else
        fail "Position $((i + 1)): expected '${known_order[$i]}', got '${PLAN_PROJECT_TYPES[$i]}'"
    fi
done

echo
echo "=== Label Non-Empty ==="

for i in "${!PLAN_PROJECT_LABELS[@]}"; do
    label="${PLAN_PROJECT_LABELS[$i]}"
    if [ -n "$label" ]; then
        pass "PLAN_PROJECT_LABELS[$i] is non-empty"
    else
        fail "PLAN_PROJECT_LABELS[$i] is empty"
    fi
done

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
