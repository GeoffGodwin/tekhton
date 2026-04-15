#!/usr/bin/env bash
# Test: ui_validate.sh — _find_available_port, _is_port_in_use, _detect_ui_targets
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export PROJECT_DIR TEKHTON_HOME
mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR}"

CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
export CODER_SUMMARY_FILE

source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null

# Set required globals that ui_validate.sh references at parse time
UI_SERVE_CMD=""
UI_SERVE_PORT=3000
UI_SERVER_STARTUP_TIMEOUT=30
UI_VALIDATION_VIEWPORTS="1280x800,375x812"
UI_VALIDATION_TIMEOUT=30
UI_VALIDATION_CONSOLE_SEVERITY=error
UI_VALIDATION_FLICKER_THRESHOLD=0.05
UI_VALIDATION_RETRY=true
UI_VALIDATION_SCREENSHOTS=false
WATCHTOWER_SELF_TEST=false
TEKHTON_SESSION_DIR="$TMPDIR"
export UI_SERVE_CMD UI_SERVE_PORT UI_SERVER_STARTUP_TIMEOUT \
    UI_VALIDATION_VIEWPORTS UI_VALIDATION_TIMEOUT \
    UI_VALIDATION_CONSOLE_SEVERITY UI_VALIDATION_FLICKER_THRESHOLD \
    UI_VALIDATION_RETRY UI_VALIDATION_SCREENSHOTS \
    WATCHTOWER_SELF_TEST TEKHTON_SESSION_DIR

source "${TEKHTON_HOME}/lib/ui_validate.sh" 2>/dev/null

# ---------------------------------------------------------------------------
# Tests: _is_port_in_use
# ---------------------------------------------------------------------------

# A port with no listener should report as free
# Use a high ephemeral port unlikely to be occupied
FREE_PORT=59998
result=0
_is_port_in_use "$FREE_PORT" && result=1 || result=0
if [[ "$result" -eq 0 ]]; then
    pass "_is_port_in_use: reports free port as not in use"
else
    fail "_is_port_in_use: free port $FREE_PORT incorrectly reported as in use"
fi

# Start a listener and verify the port is detected as in use
if command -v python3 &>/dev/null; then
    LISTEN_PORT=59997
    python3 -m http.server "$LISTEN_PORT" --directory "$TMPDIR" &>/dev/null &
    SRV_PID=$!
    sleep 1

    result=0
    _is_port_in_use "$LISTEN_PORT" && result=1 || result=0
    if [[ "$result" -eq 1 ]]; then
        pass "_is_port_in_use: detects port in use while server running"
    else
        fail "_is_port_in_use: failed to detect occupied port $LISTEN_PORT"
    fi

    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true

    # After kill the port should be free again
    sleep 0.5
    result=0
    _is_port_in_use "$LISTEN_PORT" && result=1 || result=0
    if [[ "$result" -eq 0 ]]; then
        pass "_is_port_in_use: port free after server stopped"
    else
        fail "_is_port_in_use: port $LISTEN_PORT still appears in use after server killed"
    fi
else
    echo "SKIP: _is_port_in_use (python3 not available for listener test)"
fi

# ---------------------------------------------------------------------------
# Tests: _find_available_port
# ---------------------------------------------------------------------------

# With no listeners, the base port itself should be returned
BASE_PORT=59990
result=$(_find_available_port "$BASE_PORT")
if [[ "$result" -eq "$BASE_PORT" ]]; then
    pass "_find_available_port: returns base port when it is free"
else
    fail "_find_available_port: expected $BASE_PORT, got '${result}'"
fi

# Port must be within the scanned range [base, base+10]
result=$(_find_available_port "$BASE_PORT")
if [[ "$result" -ge "$BASE_PORT" ]] && [[ "$result" -le "$((BASE_PORT + 10))" ]]; then
    pass "_find_available_port: result within expected scan range"
else
    fail "_find_available_port: result $result outside range [$BASE_PORT, $((BASE_PORT+10))]"
fi

# When the base port is occupied, it should advance to the next free one
if command -v python3 &>/dev/null; then
    OCCUPIED_PORT=59985
    python3 -m http.server "$OCCUPIED_PORT" --directory "$TMPDIR" &>/dev/null &
    SRV2_PID=$!
    sleep 1

    result=$(_find_available_port "$OCCUPIED_PORT")
    if [[ "$result" -gt "$OCCUPIED_PORT" ]]; then
        pass "_find_available_port: advances past occupied port"
    else
        fail "_find_available_port: expected port > $OCCUPIED_PORT, got '${result}'"
    fi

    kill "$SRV2_PID" 2>/dev/null || true
    wait "$SRV2_PID" 2>/dev/null || true
else
    echo "SKIP: _find_available_port occupied-port test (python3 not available)"
fi

# ---------------------------------------------------------------------------
# Tests: _detect_ui_targets
# ---------------------------------------------------------------------------

cd "$TMPDIR"

# Create a CODER_SUMMARY.md with HTML and non-HTML files
cat > "${TMPDIR}/${CODER_SUMMARY_FILE:-${TEKHTON_DIR:-.tekhton}/CODER_SUMMARY.md}" << 'EOF'
## Status
COMPLETE

## Files Created or Modified
- `src/index.html` — main page
- `src/app.js` — application logic
- `src/component.tsx` — React component
- `lib/utils.sh` — shell utility
EOF

# Run in the TMPDIR context so git diff returns nothing (not a git repo)
result=$(cd "$TMPDIR" && _detect_ui_targets 2>/dev/null || true)

if echo "$result" | grep -q "html|src/index.html"; then
    pass "_detect_ui_targets: detects HTML file from CODER_SUMMARY.md"
else
    fail "_detect_ui_targets: did not detect html|src/index.html in output: '${result}'"
fi

if echo "$result" | grep -q "webapp|src/component.tsx"; then
    pass "_detect_ui_targets: detects .tsx as webapp target"
else
    fail "_detect_ui_targets: did not detect webapp|src/component.tsx in output: '${result}'"
fi

# Non-UI files should not appear
if echo "$result" | grep -qE "\|src/app\.js|\|lib/utils\.sh"; then
    fail "_detect_ui_targets: non-UI files leaked into output: '${result}'"
else
    pass "_detect_ui_targets: non-UI files correctly excluded"
fi

# Without CODER_SUMMARY.md, output should be empty (non-git dir produces no git diff)
rm -f "${TMPDIR}/${CODER_SUMMARY_FILE}"
result=$(cd "$TMPDIR" && _detect_ui_targets 2>/dev/null || true)
if [[ -z "$result" ]]; then
    pass "_detect_ui_targets: empty output when no CODER_SUMMARY.md and no git diff"
else
    fail "_detect_ui_targets: expected empty output without CODER_SUMMARY.md, got '${result}'"
fi

# Only non-UI files in CODER_SUMMARY.md should produce no targets
cat > "${TMPDIR}/${CODER_SUMMARY_FILE:-${TEKHTON_DIR:-.tekhton}/CODER_SUMMARY.md}" << 'EOF'
## Files Modified
- `lib/gates.sh` — gate logic
- `lib/config.sh` — config loading
EOF
result=$(cd "$TMPDIR" && _detect_ui_targets 2>/dev/null || true)
if [[ -z "$result" ]]; then
    pass "_detect_ui_targets: no targets when only non-UI files listed"
else
    fail "_detect_ui_targets: expected no targets for non-UI files, got '${result}'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    exit 0
else
    exit 1
fi
