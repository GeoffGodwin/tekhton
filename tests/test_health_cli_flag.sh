#!/usr/bin/env bash
# Test: --health early-exit path in tekhton.sh (Milestone 15)
#
# Covers: exit code 0, HEALTH_REPORT.md created, HEALTH_BASELINE.json created,
#         report contains expected health score heading.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${label}: expected '${expected}', got '${actual}'" >&2
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================================
# Test 1: --health exits with code 0 on a minimal git repo
# ============================================================================

PROJ1="$TMPDIR/minimal"
mkdir -p "$PROJ1"
git -C "$PROJ1" init -q
git -C "$PROJ1" config user.email "test@test.com"
git -C "$PROJ1" config user.name "Test"
echo "# minimal" > "$PROJ1/README.md"
git -C "$PROJ1" add . && git -C "$PROJ1" commit -q -m "init"

exit_code=0
(cd "$PROJ1" && bash "${TEKHTON_HOME}/tekhton.sh" --health > /dev/null 2>&1) || exit_code=$?
assert_eq "--health exits 0" "0" "$exit_code"

# ============================================================================
# Test 2: HEALTH_BASELINE.json is created by --health
# ============================================================================

if [[ -f "${PROJ1}/.claude/HEALTH_BASELINE.json" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: HEALTH_BASELINE.json not created by --health" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 3: HEALTH_REPORT.md is created by --health
# ============================================================================

if [[ -f "${PROJ1}/HEALTH_REPORT.md" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: HEALTH_REPORT.md not created by --health" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 4: HEALTH_REPORT.md contains expected composite score heading
# ============================================================================

if grep -q "Composite Score:" "${PROJ1}/HEALTH_REPORT.md" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: HEALTH_REPORT.md missing 'Composite Score:' heading" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 5: HEALTH_BASELINE.json contains required fields
# ============================================================================

baseline="${PROJ1}/.claude/HEALTH_BASELINE.json"
for field in "composite" "belt" "dimensions"; do
    if grep -q "\"${field}\"" "$baseline" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: HEALTH_BASELINE.json missing field '${field}'" >&2
        FAIL=$((FAIL + 1))
    fi
done

# ============================================================================
# Test 6: --health does NOT enter the full pipeline (no pipeline lock created)
# ============================================================================

# The pipeline lock is created only by the execution pipeline, not --health.
# Verifies the early-exit happens before _check_pipeline_lock.
if [[ ! -f "${PROJ1}/.claude/PIPELINE.lock" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: PIPELINE.lock should not be created by --health" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 7: --health works on a well-maintained project and scores higher
# ============================================================================

PROJ2="$TMPDIR/goodproject"
mkdir -p "$PROJ2/src" "$PROJ2/tests" "$PROJ2/.github/workflows"
git -C "$PROJ2" init -q
git -C "$PROJ2" config user.email "test@test.com"
git -C "$PROJ2" config user.name "Test"

echo 'export const add = (a: number, b: number) => a + b;' > "$PROJ2/src/math.ts"
echo 'it("adds", () => {});' > "$PROJ2/tests/math.spec.ts"
echo '{"extends":"recommended"}' > "$PROJ2/.eslintrc.json"
echo '{}' > "$PROJ2/package-lock.json"
echo '{"name":"test"}' > "$PROJ2/package.json"
echo '{}' > "$PROJ2/renovate.json"
echo 'name: CI' > "$PROJ2/.github/workflows/ci.yml"
cat > "$PROJ2/.gitignore" << 'GI'
node_modules
.env
dist
GI
printf '# Good Project\n\n## Installation\n\nRun npm install.\n' > "$PROJ2/README.md"

git -C "$PROJ2" add . && git -C "$PROJ2" commit -q -m "init"

(cd "$PROJ2" && bash "${TEKHTON_HOME}/tekhton.sh" --health > /dev/null 2>&1)

# Score should be in the report
if [[ -f "${PROJ2}/HEALTH_REPORT.md" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: HEALTH_REPORT.md not created for good project" >&2
    FAIL=$((FAIL + 1))
fi

# The composite score from the good project should be higher than the minimal one
min_composite=0
good_composite=0
if [[ -f "${PROJ1}/.claude/HEALTH_BASELINE.json" ]]; then
    min_composite=$(grep -oE '"composite":[[:space:]]*[0-9]+' "${PROJ1}/.claude/HEALTH_BASELINE.json" | \
        grep -oE '[0-9]+$' | head -1 || echo 0)
fi
if [[ -f "${PROJ2}/.claude/HEALTH_BASELINE.json" ]]; then
    good_composite=$(grep -oE '"composite":[[:space:]]*[0-9]+' "${PROJ2}/.claude/HEALTH_BASELINE.json" | \
        grep -oE '[0-9]+$' | head -1 || echo 0)
fi

if [[ "$good_composite" -gt "$min_composite" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: good project (${good_composite}) should score higher than minimal (${min_composite})" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Results
# ============================================================================

echo
echo "CLI --health flag tests: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
