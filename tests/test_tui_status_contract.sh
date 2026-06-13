#!/usr/bin/env bash
# m26: Contract test for the Go writer ↔ Python renderer tui_status.json seam.
#
# The Go writer (tekhton tui start + tekhton tui append-event, via state.go /
# proto/tui.go) and the Python renderer (tools/tui_render.py) must agree on
# field names and shapes. Historically the now-dead WriteInitial() in status.go
# used the wrong JSON key names (agent_status vs current_agent_status, []string
# vs []TUIEventEntry for recent_events), creating a visible contract drift.
#
# Tests:
#   A — tekhton tui start emits payload.current_agent_status, not agent_status
#   B — tekhton tui append-event emits events as dicts {ts, level, msg, source}
#   C — event dict keys match the keys Python reads (ts/level/msg/source present)
#   D — Python renderer consumes the Go-emitted JSON without raising
#         (skipped when 'rich' package is not available)
#
# Also tests WriteInitial() in status.go — a function that was not wired into
# the production pipeline but still has wrong field names. A future re-wire
# would immediately corrupt the seam; these tests prevent silent regression.
#   E — WriteInitial emits current_agent_status (not agent_status)
#   F — WriteFinal emits complete=true and verdict

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${TEKHTON_BIN:-${TEKHTON_HOME}/bin/tekhton}"
PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP $1"; SKIP=$((SKIP + 1)); }

if [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "SKIP test_tui_status_contract.sh: tekhton binary not found at ${TEKHTON_BIN}"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP test_tui_status_contract.sh: jq not found (required for JSON assertion)"
    exit 0
fi

# ─── Test A: tekhton tui start payload uses current_agent_status ─────────────

_run_test_A() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    local sf="${tmpdir}/status.json"

    "$TEKHTON_BIN" tui start --status-file "$sf" --run-mode task 2>/dev/null

    # The payload must use current_agent_status (the field name Python reads).
    local payload_status
    payload_status=$(jq -r '.payload.current_agent_status // empty' "$sf" 2>/dev/null)
    if [[ "$payload_status" == "idle" ]]; then
        pass "A: payload.current_agent_status == 'idle'"
    else
        fail "A: payload.current_agent_status not found or not 'idle' (got: $(jq -r '.payload // empty' "$sf" 2>/dev/null | head -1))"
    fi

    # Confirm the legacy root-level agent_status is NOT present (which would
    # indicate the Go side reverted to the WriteInitial schema).
    local root_agent_status
    root_agent_status=$(jq -r '.agent_status // empty' "$sf" 2>/dev/null)
    if [[ -n "$root_agent_status" ]]; then
        fail "A-b: root-level 'agent_status' present — Go writer reverted to legacy schema"
    fi
}

# ─── Test B: tekhton tui append-event emits dicts, not strings ───────────────

_run_test_B() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    local sf="${tmpdir}/status.json"

    "$TEKHTON_BIN" tui start --status-file "$sf" --run-mode task 2>/dev/null
    "$TEKHTON_BIN" tui append-event \
        --status-file "$sf" \
        --level info \
        --message "contract test event" \
        --source "tester » contract" \
        2>/dev/null

    # recent_events must be an array of objects (dicts), not strings.
    local event_type
    event_type=$(jq -r '.payload.recent_events[0] | type' "$sf" 2>/dev/null)
    if [[ "$event_type" == "object" ]]; then
        pass "B: recent_events[0] is an object (dict)"
    elif [[ "$event_type" == "string" ]]; then
        fail "B: recent_events[0] is a string — Python .get('ts') will crash"
    else
        fail "B: recent_events is empty or malformed (type=${event_type})"
    fi
}

# ─── Test C: event dict has the keys Python reads ────────────────────────────

_run_test_C() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    local sf="${tmpdir}/status.json"

    "$TEKHTON_BIN" tui start --status-file "$sf" --run-mode task 2>/dev/null
    "$TEKHTON_BIN" tui append-event \
        --status-file "$sf" \
        --level warn \
        --message "hello from tester" \
        --source "tester" \
        2>/dev/null

    local missing=()
    for key in ts level msg source; do
        local val
        val=$(jq -r ".payload.recent_events[0].${key} // empty" "$sf" 2>/dev/null)
        if [[ -z "$val" && "$key" != "source" ]]; then
            missing+=("$key")
        fi
    done

    # 'source' is optional (can be empty) — only flag it missing if the key
    # itself is absent from the object.
    local has_source
    has_source=$(jq -r '.payload.recent_events[0] | has("source")' "$sf" 2>/dev/null)
    if [[ "$has_source" != "true" ]]; then
        missing+=("source")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "C: event dict contains all required keys: ts, level, msg, source"
    else
        fail "C: event dict missing keys: ${missing[*]}"
    fi
}

# ─── Test D: Python renderer consumes Go-emitted JSON without raising ─────────

_run_test_D() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "D: python3 not available"
        return 0
    fi

    # Check if rich is available in the tools venv or system Python.
    local py3
    py3="python3"
    local venv_py="${TEKHTON_HOME}/../.claude/indexer-venv/bin/python"
    if [[ -x "${TEKHTON_HOME}/.claude/indexer-venv/bin/python" ]]; then
        venv_py="${TEKHTON_HOME}/.claude/indexer-venv/bin/python"
    fi
    if "$venv_py" -c "import rich" 2>/dev/null; then
        py3="$venv_py"
    elif ! python3 -c "import rich" 2>/dev/null; then
        skip "D: 'rich' package not installed (install via venv or pip install rich)"
        return 0
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    local sf="${tmpdir}/status.json"

    "$TEKHTON_BIN" tui start --status-file "$sf" --run-mode task 2>/dev/null
    "$TEKHTON_BIN" tui append-event \
        --status-file "$sf" \
        --level info \
        --message "python render test" \
        --source "tester" \
        2>/dev/null

    # Read the status file with Python's tui._read_status() and pass it to
    # _build_events_panel(). Assert no exception is raised.
    local py_result
    py_result=$("$py3" - "$sf" "${TEKHTON_HOME}/tools" 2>&1 <<'PYEOF'
import sys, json
from pathlib import Path

status_file = Path(sys.argv[1])
tools_dir = Path(sys.argv[2])
sys.path.insert(0, str(tools_dir))

import tui

status = tui._read_status(status_file)
if status is None:
    print("FAIL: _read_status returned None")
    sys.exit(1)

if status.get("current_agent_status") != "idle":
    print(f"FAIL: current_agent_status wrong: {status.get('current_agent_status')!r}")
    sys.exit(1)

try:
    panel = tui._build_events_panel(status, max_lines=8)
    if panel is None:
        print("FAIL: _build_events_panel returned None")
        sys.exit(1)
except Exception as e:
    print(f"FAIL: _build_events_panel raised: {e}")
    sys.exit(1)

print("OK")
PYEOF
    ) || true

    if [[ "$py_result" == "OK" ]]; then
        pass "D: Python renderer consumed Go-emitted JSON without raising"
    else
        fail "D: Python renderer failed: ${py_result}"
    fi
}

# ─── Test E: WriteInitial emits current_agent_status (not agent_status) ──────
# WriteInitial() in status.go is not in the production pipeline but tests it
# to prevent re-introduction of the broken schema if it ever gets wired up.

_run_test_E() {
    # Run as a Go test; the bash test shells out to `go test`.
    if ! command -v go >/dev/null 2>&1; then
        skip "E: go binary not found (WriteInitial schema test requires go test)"
        return 0
    fi

    local tmpout
    tmpout=$(mktemp)
    local exit_code=0
    (cd "${TEKHTON_HOME}" && go test ./internal/tui/... -run TestWriteInitialFieldName -count=1 -v) \
        > "$tmpout" 2>&1 || exit_code=$?
    local result
    result=$(cat "$tmpout")
    rm -f "$tmpout"

    if echo "$result" | grep -q "no test files\|no tests to run"; then
        skip "E: status_contract_test.go not yet written (run after tester adds it)"
    elif [[ $exit_code -eq 0 ]]; then
        pass "E: TestWriteInitialFieldName passed"
    else
        fail "E: TestWriteInitialFieldName failed — WriteInitial uses wrong field names"
    fi
}

# ─── Test F: WriteFinal emits complete=true and correct field names ───────────
# Parallel to E — guards WriteFinal() against future schema drift.

_run_test_F() {
    if ! command -v go >/dev/null 2>&1; then
        skip "F: go binary not found"
        return 0
    fi

    local tmpout
    tmpout=$(mktemp)
    local exit_code=0
    (cd "${TEKHTON_HOME}" && go test ./internal/tui/... -run TestWriteFinalFieldName -count=1 -v) \
        > "$tmpout" 2>&1 || exit_code=$?
    local result
    result=$(cat "$tmpout")
    rm -f "$tmpout"

    if echo "$result" | grep -q "no test files\|no tests to run"; then
        skip "F: TestWriteFinalFieldName not yet written"
    elif [[ $exit_code -eq 0 ]]; then
        pass "F: TestWriteFinalFieldName passed"
    else
        fail "F: TestWriteFinalFieldName failed — WriteFinal uses wrong field names"
    fi
}

_run_test_A
_run_test_B
_run_test_C
_run_test_D
_run_test_E
_run_test_F

echo ""
echo "────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}  Skipped: ${SKIP}"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
