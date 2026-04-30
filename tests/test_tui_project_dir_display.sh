#!/usr/bin/env bash
# =============================================================================
# test_tui_project_dir_display.sh — Verify project directory name is in JSON.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0; FAIL=0

pass() { echo "  PASS: $1"; ((++PASS)); }
fail() { echo "  FAIL: $1 — $2"; ((++FAIL)); }

# Stubs
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
header()      { :; }
log_verbose() { :; }
_tui_strip_ansi() { printf '%s' "$*"; }
_tui_notify()     { :; }
CYAN="" RED="" GREEN="" YELLOW="" BOLD="" NC=""

# Source libraries once
source "${TEKHTON_HOME}/lib/tui.sh"
source "${TEKHTON_HOME}/lib/output.sh"

_test_project_dir() {
    local test_name="$1" proj_dir_input="$2" expected="$3"
    local tmpfile tmpdir_for_test

    tmpdir_for_test=$(mktemp -d) || { echo "ERROR: mktemp failed"; return 1; }
    tmpfile="$tmpdir_for_test/status.json"
    [[ -d "$tmpdir_for_test" ]] || { echo "ERROR: tmpdir not created"; return 1; }

    # Reset TUI globals
    _TUI_PIPELINE_START_TS=$(date +%s)
    _TUI_RECENT_EVENTS=()
    _TUI_STAGES_COMPLETE=()
    TASK="test-task"
    _CURRENT_MILESTONE=""
    _CURRENT_RUN_ID="run-test"
    MAX_PIPELINE_ATTEMPTS=5

    # Set PROJECT_DIR
    if [[ "$proj_dir_input" == "__UNSET__" ]]; then
        unset PROJECT_DIR 2>/dev/null || true
    else
        export PROJECT_DIR="$proj_dir_input"
    fi

    # Reset output context (safe unset for associative array under -u)
    if declare -p _OUT_CTX &>/dev/null 2>&1; then
        unset _OUT_CTX
    fi
    declare -gA _OUT_CTX
    out_init

    # Generate JSON
    _tui_json_build_status 0 > "$tmpfile"

    # Verify JSON and extract field
    if ! python3 -c "import json; json.load(open('$tmpfile'))" 2>/dev/null; then
        fail "$test_name" "invalid JSON"
        return 1
    fi

    local got
    got=$(python3 -c "import json; d=json.load(open('$tmpfile')); print(d.get('project_dir', ''))")

    if [[ "$got" == "$expected" ]]; then
        pass "$test_name"
    else
        fail "$test_name" "expected $(printf '%q' "$expected"), got $(printf '%q' "$got")"
    fi

    rm -rf "$tmpdir_for_test"
}

# =============================================================================
echo "=== Test 1: Deep path → basename ==="
_test_project_dir \
    "Deep path yields basename" \
    "/home/user/projects/my-cool-project" \
    "my-cool-project"

echo "Test 1 completed"

# =============================================================================
echo "=== Test 2: Empty string → empty ==="
_test_project_dir \
    "Empty PROJECT_DIR → empty field" \
    "" \
    ""

echo "Test 2 completed"

# =============================================================================
echo "=== Test 3: Unset → empty ==="
_test_project_dir \
    "Unset PROJECT_DIR → empty field" \
    "__UNSET__" \
    ""

# =============================================================================
echo "=== Test 4: Simple name → same ==="
_test_project_dir \
    "Simple name unchanged" \
    "tekhton" \
    "tekhton"

# =============================================================================
echo "=== Test 5: Trailing slash → stripped ==="
_test_project_dir \
    "Trailing slash removed" \
    "/path/to/my-project/" \
    "my-project"

# =============================================================================
echo "=== Test 6: With hyphenated name ==="
_test_project_dir \
    "Hyphenated name preserved" \
    "/home/user/my-project-1.0.0" \
    "my-project-1.0.0"

# =============================================================================
echo ""
echo "Test Summary: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
