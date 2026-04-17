#!/usr/bin/env bash
# =============================================================================
# test_m88_emit_symbol_map_happy_path.sh — emit_test_symbol_map success path (M88)
#
# Closes the coverage gap identified by the reviewer: no shell test verified that
# emit_test_symbol_map() actually writes test_map.json and sets TEST_SYMBOL_MAP_FILE
# to a non-empty value on the happy path.  The graceful-failure file covers all
# skip/non-fatal paths; this file covers the success path.
#
# Tests:
#   1. TEST_SYMBOL_MAP_FILE is set to a non-empty value after a successful call
#   2. The file at TEST_SYMBOL_MAP_FILE actually exists on disk
#   3. TEST_SYMBOL_MAP_FILE points to <cache_dir>/test_map.json
#   4. log() is called with a "Test symbol map written" message on success
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
export TEKHTON_HOME PROJECT_DIR

cd "$PROJECT_DIR"

# --- Stubs (must be defined before sourcing indexer_history.sh) ---------------

INDEXER_AVAILABLE=true
REPO_MAP_ENABLED=true
TEST_AUDIT_SYMBOL_MAP_ENABLED=true
export INDEXER_AVAILABLE REPO_MAP_ENABLED TEST_AUDIT_SYMBOL_MAP_ENABLED

CACHE_DIR="${TMPDIR_TEST}/.claude/index"
mkdir -p "$CACHE_DIR"

_CAPTURED_LOG=""
_CAPTURED_WARN=""
log()         { _CAPTURED_LOG="${_CAPTURED_LOG}${*}"$'\n'; }
log_verbose() { _CAPTURED_LOG="${_CAPTURED_LOG}${*}"$'\n'; }
warn()        { _CAPTURED_WARN="${_CAPTURED_WARN}${*}"$'\n'; }

# Initial stubs — will be overridden per-test below.
_indexer_find_venv_python() { return 1; }
_indexer_resolve_cache_dir() { echo "$CACHE_DIR"; }

# --- Source the library under test -------------------------------------------
source "${TEKHTON_HOME}/lib/indexer_history.sh"

# --- Fake python binary -------------------------------------------------------
# Simulates repo_map.py --emit-test-map PATH: writes minimal JSON and exits 0.
# Called as: "$FAKE_PYTHON" "/path/to/repo_map.py" --root ... --emit-test-map PATH ...
# $1 = repo_map.py path (ignored), remaining args parsed for --emit-test-map.
FAKE_PYTHON="${TMPDIR_TEST}/fake_repo_map.sh"
cat > "$FAKE_PYTHON" << 'PYEOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--emit-test-map" ]] && [[ $# -gt 1 ]]; then
        printf '{"version":1,"generated":"2026-01-01T00:00:00Z","files":{}}\n' > "$2"
        exit 0
    fi
    shift
done
exit 0
PYEOF
chmod +x "$FAKE_PYTHON"

# --- Test helpers -------------------------------------------------------------
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

_reset() {
    TEST_SYMBOL_MAP_FILE=""
    _CAPTURED_LOG=""
    _CAPTURED_WARN=""
    export TEST_SYMBOL_MAP_FILE
    # Restore enabled flags for each test
    TEST_AUDIT_SYMBOL_MAP_ENABLED=true
    REPO_MAP_ENABLED=true
    INDEXER_AVAILABLE=true
}

# ============================================================================
echo "=== emit_test_symbol_map happy path tests (M88) ==="

# --- test_sets_TEST_SYMBOL_MAP_FILE_on_success --------------------------------
echo "--- test_sets_TEST_SYMBOL_MAP_FILE_on_success ---"
_reset
_indexer_find_venv_python() { echo "$FAKE_PYTHON"; }

emit_test_symbol_map

if [[ -n "$TEST_SYMBOL_MAP_FILE" ]]; then
    pass "TEST_SYMBOL_MAP_FILE is non-empty after successful emit"
else
    fail "TEST_SYMBOL_MAP_FILE was not set after successful emit"
fi

# --- test_file_exists_on_disk -------------------------------------------------
echo "--- test_file_exists_on_disk ---"
# Uses TEST_SYMBOL_MAP_FILE set by previous test (no reset needed — same call)
if [[ -f "$TEST_SYMBOL_MAP_FILE" ]]; then
    pass "test_map.json file exists on disk at TEST_SYMBOL_MAP_FILE path"
else
    fail "Expected file at '${TEST_SYMBOL_MAP_FILE:-<empty>}' but it does not exist"
fi

# --- test_path_in_cache_dir ---------------------------------------------------
echo "--- test_path_in_cache_dir ---"
expected_path="${CACHE_DIR}/test_map.json"
if [[ "$TEST_SYMBOL_MAP_FILE" == "$expected_path" ]]; then
    pass "TEST_SYMBOL_MAP_FILE points to <cache_dir>/test_map.json"
else
    fail "Expected TEST_SYMBOL_MAP_FILE='${expected_path}', got: '${TEST_SYMBOL_MAP_FILE}'"
fi

# --- test_log_message_emitted -------------------------------------------------
echo "--- test_log_message_emitted ---"
if echo "$_CAPTURED_LOG" | grep -q "Test symbol map written"; then
    pass "log() called with 'Test symbol map written' on success"
else
    fail "Expected log about test symbol map written; captured log: '${_CAPTURED_LOG}'"
fi

# ============================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
