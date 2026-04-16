#!/usr/bin/env bash
# Test: --progress flag path in tekhton.sh (M82 coverage gap)
#
# Covers:
#   - --progress exits 0 and shows progress header
#   - --progress with no manifest shows graceful "No milestones found"
#   - --progress --all includes completed milestones
#   - --progress --deps shows dependency edges
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

# ── Test 1: --progress exits 0 and shows progress with a manifest ───────────
echo "Test 1: --progress exits 0 and shows progress header"

PROJ1="${TMPDIR}/proj_with_manifest"
mkdir -p "$PROJ1"
make_proj "$PROJ1"
write_manifest "$PROJ1"

rc=0
output=$(cd "$PROJ1" && bash "${TEKHTON_HOME}/tekhton.sh" --progress 2>/dev/null) || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "--progress exits 0"
else
    fail "--progress exited $rc (expected 0)"
fi
if echo "$output" | grep -q "Milestones:"; then
    pass "--progress shows progress header"
else
    fail "--progress missing 'Milestones:' header (got: ${output})"
fi
if echo "$output" | grep -q "Feature Alpha"; then
    pass "--progress shows pending milestone name"
else
    fail "--progress missing pending milestone name 'Feature Alpha'"
fi

# ── Test 2: --progress with no manifest shows graceful message ──────────────
echo "Test 2: --progress with no manifest shows 'No milestones found'"

PROJ2="${TMPDIR}/proj_no_manifest"
mkdir -p "$PROJ2"
make_proj "$PROJ2"

rc=0
output=$(cd "$PROJ2" && bash "${TEKHTON_HOME}/tekhton.sh" --progress 2>/dev/null) || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "--progress exits 0 with no manifest"
else
    fail "--progress exited $rc with no manifest (expected 0)"
fi
if echo "$output" | grep -q "No milestones found"; then
    pass "--progress shows 'No milestones found' when no manifest"
else
    fail "--progress missing 'No milestones found' message (got: ${output})"
fi

# ── Test 3: --progress --all shows completed milestones ─────────────────────
echo "Test 3: --progress --all shows completed milestones"

rc=0
output=$(cd "$PROJ1" && bash "${TEKHTON_HOME}/tekhton.sh" --progress --all 2>/dev/null) || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "--progress --all exits 0"
else
    fail "--progress --all exited $rc (expected 0)"
fi
if echo "$output" | grep -q "Foundation Work"; then
    pass "--progress --all shows done milestone 'Foundation Work'"
else
    fail "--progress --all missing done milestone 'Foundation Work' (got: ${output})"
fi

# ── Test 4: --progress --deps shows dependency edges ────────────────────────
echo "Test 4: --progress --deps shows dependency info"

rc=0
output=$(cd "$PROJ1" && bash "${TEKHTON_HOME}/tekhton.sh" --progress --deps 2>/dev/null) || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "--progress --deps exits 0"
else
    fail "--progress --deps exited $rc (expected 0)"
fi
if echo "$output" | grep -q "depends:"; then
    pass "--progress --deps shows 'depends:' edge info"
else
    fail "--progress --deps missing 'depends:' line (got: ${output})"
fi

# ── Test 5: PIPELINE.lock is cleaned up (clean exit path) ─────────────────────
echo "Test 5: PIPELINE.lock not left behind after --progress"

if [[ ! -f "${PROJ1}/.claude/PIPELINE.lock" ]]; then
    pass "PIPELINE.lock cleaned up after --progress"
else
    fail "PIPELINE.lock was left behind — clean exit not reached"
fi

# ── Test 6: --auto-advance documented with optional count argument ──────────
echo "Test 6: --help and --help --all document --auto-advance [N]"

PROJ_HELP="${TMPDIR}/proj_help"
mkdir -p "$PROJ_HELP"
make_proj "$PROJ_HELP"

rc=0
help_grouped=$(cd "$PROJ_HELP" && bash "${TEKHTON_HOME}/tekhton.sh" --help 2>/dev/null) || rc=$?
if [[ "$rc" -eq 0 ]] && echo "$help_grouped" | grep -q -- "--auto-advance \[N\]"; then
    pass "--help shows --auto-advance [N] in grouped output"
else
    fail "--help missing '--auto-advance [N]' in grouped output"
fi

rc=0
help_all=$(cd "$PROJ_HELP" && bash "${TEKHTON_HOME}/tekhton.sh" --help --all 2>/dev/null) || rc=$?
if [[ "$rc" -eq 0 ]] && echo "$help_all" | grep -q -- "--auto-advance \[N\]"; then
    pass "--help --all shows --auto-advance [N] in full flag list"
else
    fail "--help --all missing '--auto-advance [N]' in full flag list"
fi

# ── Test 7: --auto-advance accepts an optional integer without erroring ─────
echo "Test 7: --auto-advance N parsing consumes the integer (does not break --help)"

# The integer immediately following --auto-advance must be consumed by the flag
# parser; the loop should then continue to --help and exit cleanly. If the int
# were left on the arg stack as a task, the parser would error out.
rc=0
out=$(cd "$PROJ_HELP" && bash "${TEKHTON_HOME}/tekhton.sh" --auto-advance 5 --help 2>&1) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "--auto-advance 5 --help exits 0 (integer consumed by flag)"
else
    fail "--auto-advance 5 --help exited $rc (expected 0; got: ${out})"
fi

# Without an integer, the flag should still work and --help still exits cleanly
rc=0
out=$(cd "$PROJ_HELP" && bash "${TEKHTON_HOME}/tekhton.sh" --auto-advance --help 2>&1) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "--auto-advance --help (no integer) exits 0"
else
    fail "--auto-advance --help exited $rc (expected 0; got: ${out})"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
