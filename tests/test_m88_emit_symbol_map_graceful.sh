#!/usr/bin/env bash
# =============================================================================
# test_m88_emit_symbol_map_graceful.sh — emit_test_symbol_map non-fatal paths (M88)
#
# Covers the reviewer coverage gap: no shell test for emit_test_symbol_map
# failing gracefully (the warn + return 0 non-fatal path in indexer_history.sh).
#
# Tests:
#   1. Returns 0 and skips when TEST_AUDIT_SYMBOL_MAP_ENABLED=false
#   2. Returns 0 and skips when REPO_MAP_ENABLED=false
#   3. Returns 0 and skips when INDEXER_AVAILABLE=false
#   4. Returns 0 (non-fatal) when _indexer_find_venv_python fails
#   5. Returns 0 + warns when the python command exits non-zero (non-fatal path)
#   6. TEST_SYMBOL_MAP_FILE stays empty when python command fails
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
export TEKHTON_HOME PROJECT_DIR

cd "$PROJECT_DIR"

# Stubs for functions emit_test_symbol_map depends on.
# Define these BEFORE sourcing indexer_history.sh so they are in scope
# when the sourced file's global code runs.

INDEXER_AVAILABLE=false
export INDEXER_AVAILABLE

_CAPTURED_WARN=""
log()  { :; }
warn() { _CAPTURED_WARN="${_CAPTURED_WARN}${*}"$'\n'; }

_indexer_find_venv_python() { command -v python3; }
_indexer_resolve_cache_dir() { echo "${TMPDIR_TEST}/.claude/index"; }

mkdir -p "${TMPDIR_TEST}/.claude/index"

# Source the library under test.
# indexer_history.sh depends on log/warn/INDEXER_AVAILABLE/_indexer_find_venv_python/
# _indexer_resolve_cache_dir — all stubbed above.
source "${TEKHTON_HOME}/lib/indexer_history.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Helper: reset state between test cases
_reset() {
    TEST_SYMBOL_MAP_FILE=""
    _CAPTURED_WARN=""
    export TEST_SYMBOL_MAP_FILE
}

# ============================================================================
echo "=== emit_test_symbol_map graceful failure tests (M88) ==="

# --- test_skips_when_disabled ---
echo "--- test_skips_when_disabled ---"
_reset
TEST_AUDIT_SYMBOL_MAP_ENABLED=false
REPO_MAP_ENABLED=true
INDEXER_AVAILABLE=true

rc=0
emit_test_symbol_map || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "Returns 0 when TEST_AUDIT_SYMBOL_MAP_ENABLED=false"
else
    fail "Expected exit 0 when disabled, got: $rc"
fi
if [[ -z "$TEST_SYMBOL_MAP_FILE" ]]; then
    pass "TEST_SYMBOL_MAP_FILE stays empty when skipped via disabled flag"
else
    fail "Expected TEST_SYMBOL_MAP_FILE empty, got: $TEST_SYMBOL_MAP_FILE"
fi

# --- test_skips_when_repo_map_disabled ---
echo "--- test_skips_when_repo_map_disabled ---"
_reset
TEST_AUDIT_SYMBOL_MAP_ENABLED=true
REPO_MAP_ENABLED=false
INDEXER_AVAILABLE=true

rc=0
emit_test_symbol_map || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "Returns 0 when REPO_MAP_ENABLED=false"
else
    fail "Expected exit 0 when REPO_MAP_ENABLED=false, got: $rc"
fi
if [[ -z "$TEST_SYMBOL_MAP_FILE" ]]; then
    pass "TEST_SYMBOL_MAP_FILE stays empty when REPO_MAP_ENABLED=false"
else
    fail "Expected TEST_SYMBOL_MAP_FILE empty, got: $TEST_SYMBOL_MAP_FILE"
fi

# --- test_skips_when_indexer_unavailable ---
echo "--- test_skips_when_indexer_unavailable ---"
_reset
TEST_AUDIT_SYMBOL_MAP_ENABLED=true
REPO_MAP_ENABLED=true
INDEXER_AVAILABLE=false

rc=0
emit_test_symbol_map || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "Returns 0 when INDEXER_AVAILABLE=false"
else
    fail "Expected exit 0 when indexer unavailable, got: $rc"
fi
if [[ -z "$TEST_SYMBOL_MAP_FILE" ]]; then
    pass "TEST_SYMBOL_MAP_FILE stays empty when INDEXER_AVAILABLE=false"
else
    fail "Expected TEST_SYMBOL_MAP_FILE empty, got: $TEST_SYMBOL_MAP_FILE"
fi

# --- test_nonfatal_when_venv_python_fails ---
echo "--- test_nonfatal_when_venv_python_fails ---"
_reset
TEST_AUDIT_SYMBOL_MAP_ENABLED=true
REPO_MAP_ENABLED=true
INDEXER_AVAILABLE=true
_indexer_find_venv_python() { return 1; }

rc=0
emit_test_symbol_map || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "Returns 0 (non-fatal) when _indexer_find_venv_python fails"
else
    fail "Expected exit 0 when venv python unavailable, got: $rc"
fi
if [[ -z "$TEST_SYMBOL_MAP_FILE" ]]; then
    pass "TEST_SYMBOL_MAP_FILE stays empty when venv python fails"
else
    fail "Expected TEST_SYMBOL_MAP_FILE empty, got: $TEST_SYMBOL_MAP_FILE"
fi

# --- test_nonfatal_when_python_command_exits_nonzero ---
echo "--- test_nonfatal_when_python_command_exits_nonzero ---"
# Create a fake python binary that always exits 1 regardless of arguments.
# This exercises the "|| { warn ...; return 0; }" branch in emit_test_symbol_map.
FAKE_PYTHON="${TMPDIR_TEST}/fake_python.sh"
cat > "$FAKE_PYTHON" << 'PYEOF'
#!/usr/bin/env bash
exit 1
PYEOF
chmod +x "$FAKE_PYTHON"

_reset
TEST_AUDIT_SYMBOL_MAP_ENABLED=true
REPO_MAP_ENABLED=true
INDEXER_AVAILABLE=true
_indexer_find_venv_python() { echo "$FAKE_PYTHON"; }

rc=0
emit_test_symbol_map || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "Returns 0 (non-fatal) when python command exits non-zero"
else
    fail "Expected exit 0 on python failure, got: $rc"
fi

if [[ -z "$TEST_SYMBOL_MAP_FILE" ]]; then
    pass "TEST_SYMBOL_MAP_FILE stays empty when python command fails"
else
    fail "Expected TEST_SYMBOL_MAP_FILE empty after python failure, got: $TEST_SYMBOL_MAP_FILE"
fi

if echo "$_CAPTURED_WARN" | grep -q "Failed to emit test symbol map"; then
    pass "warn() called with non-fatal message when python command fails"
else
    fail "Expected warn about failed emit, captured warn output: ${_CAPTURED_WARN}"
fi

# ============================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
