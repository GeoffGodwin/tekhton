#!/usr/bin/env bash
# =============================================================================
# Test: _indexer_run_startup_audit() — M123 startup grammar audit (shell level)
#
# Verifies:
#   - MISMATCH output triggers warn() with the extension, module name, and
#     captured error class/message (AC#4)
#   - MISSING output triggers log_verbose() only — no warn() (AC#5)
#   - INDEXER_STARTUP_AUDIT=false skips the audit; no subprocess called,
#     no messages emitted (AC#6)
#   - Guard paths (empty/absent venv_python or tools_dir) return 0 silently
#   - Subprocess failure returns 0 — audit never blocks the pipeline
#   - Empty subprocess output returns 0
#   - LOADED output is silent (no warn, no "missing" log_verbose)
#   - SUMMARY line produces a log_verbose count summary
#   - INDEXER_STARTUP_AUDIT default in config_defaults.sh is "true"
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# --- Test scaffolding ---------------------------------------------------------

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# Capture function calls from the module under test.
WARN_CALLS=""
LOG_VERBOSE_CALLS=""

warn()        { WARN_CALLS+="${*}|||"; }
log_verbose() { LOG_VERBOSE_CALLS+="${*}|||"; }
log()         { :; }

reset_calls() {
    WARN_CALLS=""
    LOG_VERBOSE_CALLS=""
}

# Fake tools directory — just needs to exist as a directory.
TOOLS_DIR="$TEST_TMP/tools"
mkdir -p "$TOOLS_DIR"

# Shared response file: the fake python reads and cats this file.
# Exported so the subprocess can find it.
FAKE_RESPONSE="$TEST_TMP/fake_response"
export FAKE_RESPONSE

# Fake python that exits 0 and outputs the content of $FAKE_RESPONSE.
# Called as: "$FAKE_PYTHON" -c '<python code>' — arguments are ignored.
FAKE_PYTHON="$TEST_TMP/fake_python"
cat > "$FAKE_PYTHON" << 'EOF'
#!/usr/bin/env bash
cat "$FAKE_RESPONSE"
EOF
chmod +x "$FAKE_PYTHON"

# Fake python that always exits 1 (subprocess failure simulation).
FAKE_PYTHON_FAIL="$TEST_TMP/fake_python_fail"
cat > "$FAKE_PYTHON_FAIL" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_PYTHON_FAIL"

# Source the module under test after stubs are defined.
# shellcheck source=../lib/indexer_audit.sh
source "${TEKHTON_HOME}/lib/indexer_audit.sh"

# =============================================================================
echo "=== INDEXER_STARTUP_AUDIT=false skips audit entirely (AC#6) ==="

INDEXER_STARTUP_AUDIT=false
reset_calls
_indexer_run_startup_audit "$FAKE_PYTHON" "$TOOLS_DIR"

if [[ -z "$WARN_CALLS" ]] && [[ -z "$LOG_VERBOSE_CALLS" ]]; then
    pass "INDEXER_STARTUP_AUDIT=false: no warn or log_verbose emitted"
else
    fail "INDEXER_STARTUP_AUDIT=false: unexpected output warn='${WARN_CALLS}' verbose='${LOG_VERBOSE_CALLS}'"
fi
INDEXER_STARTUP_AUDIT=true

# =============================================================================
echo "=== Guard: empty venv_python returns 0 silently ==="

reset_calls
_indexer_run_startup_audit "" "$TOOLS_DIR"

if [[ -z "$WARN_CALLS" ]]; then
    pass "empty venv_python: no warn emitted"
else
    fail "empty venv_python: unexpected warn: '${WARN_CALLS}'"
fi

# =============================================================================
echo "=== Guard: non-existent venv_python returns 0 silently ==="

reset_calls
_indexer_run_startup_audit "/nonexistent/path/to/python" "$TOOLS_DIR"

if [[ -z "$WARN_CALLS" ]]; then
    pass "non-existent venv_python: no warn emitted"
else
    fail "non-existent venv_python: unexpected warn: '${WARN_CALLS}'"
fi

# =============================================================================
echo "=== Guard: empty tools_dir returns 0 silently ==="

reset_calls
_indexer_run_startup_audit "$FAKE_PYTHON" ""

if [[ -z "$WARN_CALLS" ]]; then
    pass "empty tools_dir: no warn emitted"
else
    fail "empty tools_dir: unexpected warn: '${WARN_CALLS}'"
fi

# =============================================================================
echo "=== Guard: non-existent tools_dir returns 0 silently ==="

reset_calls
_indexer_run_startup_audit "$FAKE_PYTHON" "/nonexistent/tools"

if [[ -z "$WARN_CALLS" ]]; then
    pass "non-existent tools_dir: no warn emitted"
else
    fail "non-existent tools_dir: unexpected warn: '${WARN_CALLS}'"
fi

# =============================================================================
echo "=== Subprocess failure returns 0 (audit never blocks pipeline) ==="

reset_calls
rc=0
_indexer_run_startup_audit "$FAKE_PYTHON_FAIL" "$TOOLS_DIR" || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "subprocess failure: function returns 0"
else
    fail "subprocess failure: function returned $rc (expected 0)"
fi

if echo "$LOG_VERBOSE_CALLS" | grep -q "subprocess failed"; then
    pass "subprocess failure: log_verbose emitted 'subprocess failed'"
else
    fail "subprocess failure: missing 'subprocess failed' in log_verbose; got: '${LOG_VERBOSE_CALLS}'"
fi

# =============================================================================
echo "=== Empty subprocess output returns 0 ==="

printf '' > "$FAKE_RESPONSE"
reset_calls
rc=0
_indexer_run_startup_audit "$FAKE_PYTHON" "$TOOLS_DIR" || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "empty output: function returns 0"
else
    fail "empty output: function returned $rc (expected 0)"
fi

if echo "$LOG_VERBOSE_CALLS" | grep -q "no output"; then
    pass "empty output: log_verbose emitted 'no output'"
else
    fail "empty output: missing 'no output' in log_verbose; got: '${LOG_VERBOSE_CALLS}'"
fi

# =============================================================================
echo "=== MISMATCH output triggers warn with extension, module, error (AC#4) ==="

# Output format: STATUS<TAB>ext<TAB>module<TAB>lang_name<TAB>error
printf 'MISMATCH\t.ts\ttree_sitter_typescript\ttypescript\tAttributeError: no factory\n' > "$FAKE_RESPONSE"
printf 'SUMMARY\t0\t0\t1\t1\n' >> "$FAKE_RESPONSE"
reset_calls
_indexer_run_startup_audit "$FAKE_PYTHON" "$TOOLS_DIR"

if [[ -n "$WARN_CALLS" ]]; then
    pass "MISMATCH: warn() was called"
else
    fail "MISMATCH: warn() was NOT called — API mismatch must surface as a warning"
fi

if echo "$WARN_CALLS" | grep -q "\.ts"; then
    pass "MISMATCH warn: contains the mismatched extension (.ts)"
else
    fail "MISMATCH warn: extension (.ts) missing; got: '${WARN_CALLS}'"
fi

if echo "$WARN_CALLS" | grep -q "tree_sitter_typescript"; then
    pass "MISMATCH warn: contains the module name (tree_sitter_typescript)"
else
    fail "MISMATCH warn: module name missing; got: '${WARN_CALLS}'"
fi

if echo "$WARN_CALLS" | grep -q "AttributeError"; then
    pass "MISMATCH warn: contains the error class (AttributeError)"
else
    fail "MISMATCH warn: error class missing; got: '${WARN_CALLS}'"
fi

# =============================================================================
echo "=== MISSING output triggers log_verbose only — no warn (AC#5) ==="

# MISSING: grammar module simply not installed; benign, stays at verbose level
printf 'MISSING\t.go\ttree_sitter_go\tgo\tModuleNotFoundError: No module named tree_sitter_go\n' > "$FAKE_RESPONSE"
printf 'SUMMARY\t0\t1\t0\t1\n' >> "$FAKE_RESPONSE"
reset_calls
_indexer_run_startup_audit "$FAKE_PYTHON" "$TOOLS_DIR"

if [[ -z "$WARN_CALLS" ]]; then
    pass "MISSING: no warn() emitted (benign missing grammar stays at verbose level)"
else
    fail "MISSING: unexpected warn() emitted: '${WARN_CALLS}'"
fi

if echo "$LOG_VERBOSE_CALLS" | grep -q "\.go"; then
    pass "MISSING: log_verbose() called with the missing extension (.go)"
else
    fail "MISSING: log_verbose not called for .go; got: '${LOG_VERBOSE_CALLS}'"
fi

# =============================================================================
echo "=== LOADED output is silent ==="

printf 'LOADED\t.py\ttree_sitter_python\tpython\t\n' > "$FAKE_RESPONSE"
printf 'SUMMARY\t1\t0\t0\t1\n' >> "$FAKE_RESPONSE"
reset_calls
_indexer_run_startup_audit "$FAKE_PYTHON" "$TOOLS_DIR"

if [[ -z "$WARN_CALLS" ]]; then
    pass "LOADED: no warn() emitted"
else
    fail "LOADED: unexpected warn(): '${WARN_CALLS}'"
fi

# LOADED lines should NOT appear in log_verbose as "Grammar module missing"
if ! echo "$LOG_VERBOSE_CALLS" | grep -q "Grammar module missing"; then
    pass "LOADED: no 'Grammar module missing' in log_verbose"
else
    fail "LOADED: unexpected 'Grammar module missing' in log_verbose"
fi

# =============================================================================
echo "=== SUMMARY line produces log_verbose count summary ==="

printf 'LOADED\t.py\ttree_sitter_python\tpython\t\n' > "$FAKE_RESPONSE"
printf 'SUMMARY\t1\t0\t0\t1\n' >> "$FAKE_RESPONSE"
reset_calls
_indexer_run_startup_audit "$FAKE_PYTHON" "$TOOLS_DIR"

if echo "$LOG_VERBOSE_CALLS" | grep -q "Grammars:"; then
    pass "SUMMARY: log_verbose called with 'Grammars:' count summary"
else
    fail "SUMMARY: 'Grammars:' missing from log_verbose; got: '${LOG_VERBOSE_CALLS}'"
fi

# =============================================================================
echo "=== Mixed output: multiple classifications in one audit run ==="

# Three extensions: one loaded, one missing, one mismatch
{
    printf 'LOADED\t.py\ttree_sitter_python\tpython\t\n'
    printf 'MISSING\t.kt\ttree_sitter_kotlin\tkotlin\tModuleNotFoundError: No module named tree_sitter_kotlin\n'
    printf 'MISMATCH\t.ts\ttree_sitter_typescript\ttypescript\tAttributeError: bad api\n'
    printf 'SUMMARY\t1\t1\t1\t3\n'
} > "$FAKE_RESPONSE"
reset_calls
_indexer_run_startup_audit "$FAKE_PYTHON" "$TOOLS_DIR"

if echo "$WARN_CALLS" | grep -q "\.ts"; then
    pass "mixed output: warn emitted for MISMATCH extension (.ts)"
else
    fail "mixed output: no warn for .ts MISMATCH; WARN='${WARN_CALLS}'"
fi

if ! echo "$WARN_CALLS" | grep -q "\.py"; then
    pass "mixed output: no warn for LOADED extension (.py)"
else
    fail "mixed output: unexpected warn for LOADED .py; WARN='${WARN_CALLS}'"
fi

if ! echo "$WARN_CALLS" | grep -q "\.kt"; then
    pass "mixed output: no warn for MISSING extension (.kt)"
else
    fail "mixed output: unexpected warn for MISSING .kt; WARN='${WARN_CALLS}'"
fi

if echo "$LOG_VERBOSE_CALLS" | grep -q "\.kt"; then
    pass "mixed output: log_verbose emitted for MISSING extension (.kt)"
else
    fail "mixed output: no log_verbose for .kt MISSING; VERBOSE='${LOG_VERBOSE_CALLS}'"
fi

# =============================================================================
echo "=== INDEXER_STARTUP_AUDIT default in config_defaults.sh is 'true' ==="

# Unset and re-source to verify the default is applied.
unset INDEXER_STARTUP_AUDIT 2>/dev/null || true

# Stubs required by config_defaults.sh (clamp functions used at bottom of file).
_clamp_config_value() { :; }
_clamp_config_float()  { :; }

# shellcheck source=../lib/config_defaults.sh
source "${TEKHTON_HOME}/lib/config_defaults.sh"

if [[ "${INDEXER_STARTUP_AUDIT:-}" == "true" ]]; then
    pass "INDEXER_STARTUP_AUDIT default is 'true' in config_defaults.sh"
else
    fail "INDEXER_STARTUP_AUDIT default is not 'true' (got: '${INDEXER_STARTUP_AUDIT:-unset}')"
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
