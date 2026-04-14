#!/usr/bin/env bash
# Test: --milestones flag path in tekhton.sh (M82 coverage gap)
#
# Covers:
#   - --milestones exits 0 and shows progress header
#   - --milestones with no manifest shows graceful "No milestones found"
#   - --milestones --all includes completed milestones
#   - --milestones --deps shows dependency edges
#   - PIPELINE.lock is NOT left behind (clean exit path)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# --- Helper: create a minimal project with pipeline.conf and a git repo -------

make_proj() {
    local dir="$1"
    mkdir -p "${dir}/.claude"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit --allow-empty -q -m "init"

    # Minimal pipeline.conf — only the three required keys
    cat > "${dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=smoke-test
CLAUDE_STANDARD_MODEL=claude-sonnet-4-6
ANALYZE_CMD=true
EOF
}

# --- Helper: write a milestone manifest with mixed done/pending milestones ----

write_manifest() {
    local dir="$1"
    mkdir -p "${dir}/.claude/milestones"
    cat > "${dir}/.claude/milestones/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Foundation Work|done||m01.md|
m02|Feature Alpha|pending|m01|m02.md|
m03|Feature Beta|pending|m01,m02|m03.md|
EOF
    for f in m01.md m02.md m03.md; do
        printf '# Milestone\n' > "${dir}/.claude/milestones/$f"
    done
}

# ── Test 1: --milestones exits 0 and shows progress with a manifest ───────────
echo "Test 1: --milestones exits 0 and shows progress header"

PROJ1="${TMPDIR}/proj_with_manifest"
mkdir -p "$PROJ1"
make_proj "$PROJ1"
write_manifest "$PROJ1"

rc=0
output=$(cd "$PROJ1" && bash "${TEKHTON_HOME}/tekhton.sh" --milestones 2>/dev/null) || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "--milestones exits 0"
else
    fail "--milestones exited $rc (expected 0)"
fi
if echo "$output" | grep -q "Milestones:"; then
    pass "--milestones shows progress header"
else
    fail "--milestones missing 'Milestones:' header (got: ${output})"
fi
if echo "$output" | grep -q "Feature Alpha"; then
    pass "--milestones shows pending milestone name"
else
    fail "--milestones missing pending milestone name 'Feature Alpha'"
fi

# ── Test 2: --milestones with no manifest shows graceful message ──────────────
echo "Test 2: --milestones with no manifest shows 'No milestones found'"

PROJ2="${TMPDIR}/proj_no_manifest"
mkdir -p "$PROJ2"
make_proj "$PROJ2"

rc=0
output=$(cd "$PROJ2" && bash "${TEKHTON_HOME}/tekhton.sh" --milestones 2>/dev/null) || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "--milestones exits 0 with no manifest"
else
    fail "--milestones exited $rc with no manifest (expected 0)"
fi
if echo "$output" | grep -q "No milestones found"; then
    pass "--milestones shows 'No milestones found' when no manifest"
else
    fail "--milestones missing 'No milestones found' message (got: ${output})"
fi

# ── Test 3: --milestones --all shows completed milestones ─────────────────────
echo "Test 3: --milestones --all shows completed milestones"

rc=0
output=$(cd "$PROJ1" && bash "${TEKHTON_HOME}/tekhton.sh" --milestones --all 2>/dev/null) || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "--milestones --all exits 0"
else
    fail "--milestones --all exited $rc (expected 0)"
fi
if echo "$output" | grep -q "Foundation Work"; then
    pass "--milestones --all shows done milestone 'Foundation Work'"
else
    fail "--milestones --all missing done milestone 'Foundation Work' (got: ${output})"
fi

# ── Test 4: --milestones --deps shows dependency edges ────────────────────────
echo "Test 4: --milestones --deps shows dependency info"

rc=0
output=$(cd "$PROJ1" && bash "${TEKHTON_HOME}/tekhton.sh" --milestones --deps 2>/dev/null) || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "--milestones --deps exits 0"
else
    fail "--milestones --deps exited $rc (expected 0)"
fi
if echo "$output" | grep -q "depends:"; then
    pass "--milestones --deps shows 'depends:' edge info"
else
    fail "--milestones --deps missing 'depends:' line (got: ${output})"
fi

# ── Test 5: PIPELINE.lock is cleaned up (clean exit path) ─────────────────────
echo "Test 5: PIPELINE.lock not left behind after --milestones"

if [[ ! -f "${PROJ1}/.claude/PIPELINE.lock" ]]; then
    pass "PIPELINE.lock cleaned up after --milestones"
else
    fail "PIPELINE.lock was left behind — clean exit not reached"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
