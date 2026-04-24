#!/usr/bin/env bash
# Test: _ensure_gitignore_entries() in lib/common.sh
# Verifies idempotent Tekhton runtime artifact pattern injection into .gitignore.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions consumed by common.sh
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# shellcheck source=../lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"

# Reset stubs after source (common.sh may define its own)
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# =============================================================================
# Section 1: Syntax / static analysis
# =============================================================================

if bash -n "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null; then
    pass "bash -n lib/common.sh passes"
else
    fail "bash -n lib/common.sh: syntax error"
fi

if command -v shellcheck &>/dev/null; then
    if shellcheck "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null; then
        pass "shellcheck lib/common.sh passes"
    else
        fail "shellcheck lib/common.sh: warnings or errors"
    fi
else
    echo "  SKIP: shellcheck not installed"
fi

# =============================================================================
# Section 2: Creates .gitignore when none exists
# =============================================================================

PROJ1="${TEST_TMPDIR}/proj_new"
mkdir -p "$PROJ1"

_ensure_gitignore_entries "$PROJ1"

if [[ -f "${PROJ1}/.gitignore" ]]; then
    pass "creates .gitignore when file does not exist"
else
    fail ".gitignore was not created"
fi

# =============================================================================
# Section 3: All 18 Tekhton runtime patterns are written
# =============================================================================

declare -a EXPECTED_ENTRIES=(
    ".claude/PIPELINE.lock"
    ".claude/PIPELINE_STATE.md"
    ".claude/MILESTONE_STATE.md"
    ".claude/CHECKPOINT_META.json"
    ".claude/LAST_FAILURE_CONTEXT.json"
    ".claude/TEST_BASELINE.json"
    ".claude/TEST_BASELINE_OUTPUT.txt"
    ".claude/test_acceptance_output.tmp"
    ".claude/dashboard/data/"
    ".claude/logs/"
    ".claude/indexer-venv/"
    ".claude/index/"
    ".claude/serena/"
    ".claude/dry_run_cache/"
    ".claude/migration-backups/"
    ".claude/watchtower_inbox/"
    ".claude/tui_sidecar.pid"
    ".claude/worktrees/"
)

for entry in "${EXPECTED_ENTRIES[@]}"; do
    if grep -qF "$entry" "${PROJ1}/.gitignore"; then
        pass "entry present: $entry"
    else
        fail "entry missing: $entry"
    fi
done

# Section header is present
if grep -qF "# Tekhton runtime artifacts" "${PROJ1}/.gitignore"; then
    pass "section header '# Tekhton runtime artifacts' present"
else
    fail "section header missing"
fi

# =============================================================================
# Section 4: Idempotent — calling twice does not duplicate entries
# =============================================================================

_ensure_gitignore_entries "$PROJ1"

for entry in "${EXPECTED_ENTRIES[@]}"; do
    count=$(grep -cF "$entry" "${PROJ1}/.gitignore" || true)
    if [[ "$count" -eq 1 ]]; then
        pass "idempotent: '$entry' appears exactly once"
    else
        fail "idempotent: '$entry' appears $count times (expected 1)"
    fi
done

header_count=$(grep -c "# Tekhton runtime artifacts" "${PROJ1}/.gitignore" || true)
if [[ "$header_count" -eq 1 ]]; then
    pass "idempotent: section header appears exactly once"
else
    fail "idempotent: section header appears $header_count times"
fi

# =============================================================================
# Section 5: Appends to existing .gitignore without destroying it
# =============================================================================

PROJ2="${TEST_TMPDIR}/proj_existing"
mkdir -p "$PROJ2"

cat > "${PROJ2}/.gitignore" << 'EOF'
# Node
node_modules/
dist/

# Python
__pycache__/
*.pyc
EOF

existing_content=$(cat "${PROJ2}/.gitignore")
_ensure_gitignore_entries "$PROJ2"

# Pre-existing entries are still there
if grep -qF "node_modules/" "${PROJ2}/.gitignore" && \
   grep -qF "__pycache__/" "${PROJ2}/.gitignore"; then
    pass "pre-existing entries preserved after appending"
else
    fail "pre-existing entries were lost after appending"
fi

# Tekhton entries added
if grep -qF ".claude/CHECKPOINT_META.json" "${PROJ2}/.gitignore"; then
    pass "Tekhton entries added to existing .gitignore"
else
    fail "Tekhton entries not added to existing .gitignore"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
