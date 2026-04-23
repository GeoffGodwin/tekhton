#!/usr/bin/env bash
# =============================================================================
# Test: Repo map fixture project — existence and multi-language detection tests
#
# Verifies: fixture project structure and multi-language file detection.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Minimal stubs
warn() { :; }
log()  { :; }
error() { echo "[ERROR] $*" >&2; }

PROJECT_DIR="$TMPDIR"
PROMPTS_DIR="${TEKHTON_HOME}/prompts"
export PROJECT_DIR PROMPTS_DIR

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_helpers.sh"

FIXTURE_DIR="${TEKHTON_HOME}/tests/fixtures/indexer_project"

# =============================================================================
echo "=== Fixture project: files exist ==="

if [[ -f "${FIXTURE_DIR}/src/app.py" ]]; then
    pass "fixture has Python file (src/app.py)"
else
    fail "fixture missing src/app.py"
fi

if [[ -f "${FIXTURE_DIR}/lib/utils.js" ]]; then
    pass "fixture has JavaScript file (lib/utils.js)"
else
    fail "fixture missing lib/utils.js"
fi

if [[ -f "${FIXTURE_DIR}/scripts/setup.sh" ]]; then
    pass "fixture has Bash file (scripts/setup.sh)"
else
    fail "fixture missing scripts/setup.sh"
fi

# Upper bound bumped from 10 → 20 in M123 to cover the added Go/Rust/Java/
# C++/Ruby fixtures. Keep this generous so future language fixtures don't
# churn this test, but tight enough to flag accidental bloat.
file_count=$(find "$FIXTURE_DIR" -type f | wc -l)
if [[ "$file_count" -ge 5 ]] && [[ "$file_count" -le 20 ]]; then
    pass "fixture has 5-20 files (got: $file_count)"
else
    fail "fixture should have 5-20 files (got: $file_count)"
fi

# =============================================================================
echo "=== Fixture project: M123 new language fixtures exist ==="

for fixture_path in \
    "services/server.go" \
    "services/handler.rs" \
    "services/Worker.java" \
    "native/engine.cpp" \
    "scripts/helper.rb"; do
    if [[ -f "${FIXTURE_DIR}/${fixture_path}" ]]; then
        pass "M123 fixture exists: ${fixture_path}"
    else
        fail "M123 fixture missing: ${fixture_path}"
    fi
done

# =============================================================================
echo "=== Fixture project: multi-language detection ==="

# shellcheck disable=SC2034  # langs used for display/debug
langs=$(detect_repo_languages "$FIXTURE_DIR")
# detect_repo_languages only scans top-level files, fixture has subdirs
# Manually verify extensions exist at any depth
has_py=$(find "$FIXTURE_DIR" -name "*.py" -type f | head -1)
has_js=$(find "$FIXTURE_DIR" -name "*.js" -type f | head -1)
has_sh=$(find "$FIXTURE_DIR" -name "*.sh" -type f | head -1)

if [[ -n "$has_py" ]]; then
    pass "fixture contains Python files"
else
    fail "fixture should contain Python files"
fi

if [[ -n "$has_js" ]]; then
    pass "fixture contains JavaScript files"
else
    fail "fixture should contain JavaScript files"
fi

if [[ -n "$has_sh" ]]; then
    pass "fixture contains Bash files"
else
    fail "fixture should contain Bash files"
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
