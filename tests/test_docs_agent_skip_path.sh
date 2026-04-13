#!/usr/bin/env bash
# Test: docs_agent_should_skip() correctly identifies when to skip/run
# the docs agent stage based on DOCS_AGENT_ENABLED, SKIP_DOCS, and
# CLAUDE.md section 13 (Documentation Responsibilities) parsing.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Create a temporary project dir with a git repo
TEST_TMPDIR=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

cd "$TEST_TMPDIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"

# Stub logging functions
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }

# Stub _safe_read_file (used by stages/docs.sh but not needed for skip-path)
_safe_read_file() { cat "$1" 2>/dev/null || true; }

# Source the skip-path helper
# shellcheck source=../lib/docs_agent.sh
source "${TEKHTON_HOME}/lib/docs_agent.sh"

# Export variables consumed by sourced functions
export DOCS_AGENT_ENABLED SKIP_DOCS DOCS_README_FILE DOCS_DIRS PROJECT_RULES_FILE

# --- Test 1: DOCS_AGENT_ENABLED=false → skip ---
echo "=== Test 1: disabled → skip ==="
DOCS_AGENT_ENABLED=false
SKIP_DOCS=false
if docs_agent_should_skip; then
    pass "skip when DOCS_AGENT_ENABLED=false"
else
    fail "should skip when DOCS_AGENT_ENABLED=false"
fi

# --- Test 2: SKIP_DOCS=true → skip ---
echo "=== Test 2: --skip-docs → skip ==="
DOCS_AGENT_ENABLED=true
SKIP_DOCS=true
if docs_agent_should_skip; then
    pass "skip when SKIP_DOCS=true"
else
    fail "should skip when SKIP_DOCS=true"
fi

# --- Test 3: No changed files → skip ---
echo "=== Test 3: no changed files → skip ==="
DOCS_AGENT_ENABLED=true
SKIP_DOCS=false
# No uncommitted changes in the clean repo
if docs_agent_should_skip; then
    pass "skip when no changed files"
else
    fail "should skip when no changed files"
fi

# --- Test 4: Changed internal file, no public surface → skip ---
echo "=== Test 4: internal-only changes → skip ==="
DOCS_AGENT_ENABLED=true
SKIP_DOCS=false
PROJECT_RULES_FILE="${TEST_TMPDIR}/CLAUDE.md"

# Create a CLAUDE.md with Documentation Responsibilities section
cat > "$PROJECT_RULES_FILE" << 'EOF'
# MyProject

## Non-Negotiable Rules
Do not break things.

## Documentation Responsibilities
- README.md at project root
- docs/ directory for user guides
- Public surface: CLI flags, exported API functions, config keys
- File patterns: *.md in docs/
- Doc freshness: warn-only

## Testing
Run tests with npm test.
EOF

# Create a committed baseline, then modify only internal files
echo "internal" > internal_helper.py
git add internal_helper.py
git commit -q -m "baseline"
echo "changed" > internal_helper.py

if docs_agent_should_skip; then
    pass "skip when only internal files changed"
else
    fail "should skip when only internal files changed (no public surface match)"
fi

# --- Test 5: Changed public surface file → run ---
echo "=== Test 5: public-surface change → run ==="
git checkout -q -- .
mkdir -p docs
echo "# Guide" > docs/guide.md
git add docs/guide.md
git commit -q -m "add guide"
echo "# Updated guide" > docs/guide.md

if docs_agent_should_skip; then
    fail "should run when docs/ file changed (public surface)"
else
    pass "run when docs/ file changed"
fi

# --- Test 6: Changed README → run ---
echo "=== Test 6: README change → run ==="
git checkout -q -- .
echo "# README" > README.md
git add README.md
git commit -q -m "add readme"
echo "# Updated README" > README.md

DOCS_README_FILE="README.md"
if docs_agent_should_skip; then
    fail "should run when README.md changed"
else
    pass "run when README.md changed"
fi

# --- Test 7: No CLAUDE.md Documentation Responsibilities section → run ---
echo "=== Test 7: no section 13 in CLAUDE.md → run (safe default) ==="
git checkout -q -- .
echo "changed again" > internal_helper.py

# Overwrite CLAUDE.md without Documentation Responsibilities
cat > "$PROJECT_RULES_FILE" << 'EOF'
# MyProject
## Rules
Do stuff.
EOF

if docs_agent_should_skip; then
    fail "should run when CLAUDE.md has no Documentation Responsibilities section"
else
    pass "run when no Documentation Responsibilities section (safe default)"
fi

# --- Test 8: No CLAUDE.md at all → run ---
echo "=== Test 8: no CLAUDE.md → run (safe default) ==="
rm -f "$PROJECT_RULES_FILE"

if docs_agent_should_skip; then
    fail "should run when CLAUDE.md is missing"
else
    pass "run when CLAUDE.md missing (safe default)"
fi

# --- Summary ---
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
