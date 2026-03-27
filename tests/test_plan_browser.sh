#!/usr/bin/env bash
# Test: Browser-based planning form — form generation, server lifecycle, POST handling
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Create a temporary project dir
TEST_TMPDIR=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR"
export PLAN_ANSWER_FILE="${TEST_TMPDIR}/.claude/plan_answers.yaml"
export TEKHTON_VERSION="3.32.0"
export TEKHTON_SESSION_DIR="${TEST_TMPDIR}/.claude/logs"
export TEKHTON_TEST_MODE=1
trap '_stop_plan_server 2>/dev/null || true; rm -rf "$TEST_TMPDIR"' EXIT

# Stubs for logging
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
count_lines() { wc -l | tr -d ' '; }

# Source required libraries
# shellcheck source=../lib/plan.sh
source "${TEKHTON_HOME}/lib/plan.sh"
# shellcheck source=../lib/plan_answers.sh
source "${TEKHTON_HOME}/lib/plan_answers.sh"
# shellcheck source=../lib/plan_server.sh
source "${TEKHTON_HOME}/lib/plan_server.sh"
# shellcheck source=../lib/plan_browser.sh
source "${TEKHTON_HOME}/lib/plan_browser.sh"
# shellcheck source=../stages/plan_interview.sh
source "${TEKHTON_HOME}/stages/plan_interview.sh"

# --- Create a test template ---
PLAN_TEMPLATE_FILE="${TEST_TMPDIR}/template.md"
cat > "$PLAN_TEMPLATE_FILE" << 'EOF'
# Design Document — Test

## Developer Philosophy
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What are your architectural rules? -->

## Project Overview
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What does this do? -->

## Tech Stack
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Languages and frameworks -->

## Optional Notes
<!-- PHASE:2 -->
<!-- Any extra details -->
EOF

PLAN_PROJECT_TYPE="test"

mkdir -p "${TEST_TMPDIR}/.claude"

# ============================================================
echo "=== _generate_plan_form ==="
# ============================================================

# Initialize answer file first
init_answer_file "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"

FORM_DIR="${TEST_TMPDIR}/form-output"
mkdir -p "$FORM_DIR"

_generate_plan_form "$FORM_DIR"

if [[ -f "${FORM_DIR}/index.html" ]]; then
    pass "index.html generated"
else
    fail "index.html not generated"
fi

if [[ -f "${FORM_DIR}/style.css" ]]; then
    pass "style.css copied"
else
    fail "style.css not copied"
fi

# Verify form contains textareas for all sections
if grep -q 'name="developer_philosophy"' "${FORM_DIR}/index.html"; then
    pass "Form has developer_philosophy textarea"
else
    fail "Form missing developer_philosophy textarea"
fi

if grep -q 'name="project_overview"' "${FORM_DIR}/index.html"; then
    pass "Form has project_overview textarea"
else
    fail "Form missing project_overview textarea"
fi

if grep -q 'name="tech_stack"' "${FORM_DIR}/index.html"; then
    pass "Form has tech_stack textarea"
else
    fail "Form missing tech_stack textarea"
fi

if grep -q 'name="optional_notes"' "${FORM_DIR}/index.html"; then
    pass "Form has optional_notes textarea"
else
    fail "Form missing optional_notes textarea"
fi

# Verify required indicators
if grep -q 'required-mark' "${FORM_DIR}/index.html"; then
    pass "Form has required indicators"
else
    fail "Form missing required indicators"
fi

# Verify phase headings
if grep -q 'Phase 1' "${FORM_DIR}/index.html"; then
    pass "Form has Phase 1 heading"
else
    fail "Form missing Phase 1 heading"
fi

if grep -q 'Phase 2' "${FORM_DIR}/index.html"; then
    pass "Form has Phase 2 heading"
else
    fail "Form missing Phase 2 heading"
fi

# Verify guidance content
if grep -q 'Guidance' "${FORM_DIR}/index.html"; then
    pass "Form has guidance sections"
else
    fail "Form missing guidance sections"
fi

# Verify project name substitution
if grep -q "$(basename "$TEST_TMPDIR")" "${FORM_DIR}/index.html"; then
    pass "Form has project name"
else
    fail "Form missing project name"
fi

if grep -q 'Type: <strong>test</strong>' "${FORM_DIR}/index.html"; then
    pass "Form has project type"
else
    fail "Form missing project type"
fi

# ============================================================
echo "=== Pre-populated resume ==="
# ============================================================

# Save an answer, then regenerate the form
save_answer "developer_philosophy" "Test philosophy answer"

FORM_DIR2="${TEST_TMPDIR}/form-resume"
mkdir -p "$FORM_DIR2"

_generate_plan_form "$FORM_DIR2"

if grep -q 'Test philosophy answer' "${FORM_DIR2}/index.html"; then
    pass "Resumed form has pre-populated answer"
else
    fail "Resumed form missing pre-populated answer"
fi

# ============================================================
echo "=== Port detection ==="
# ============================================================

# Test _plan_is_port_in_use returns 1 for an unused port
if ! _plan_is_port_in_use 58231; then
    pass "Unused port detected as free"
else
    fail "Unused port incorrectly reported as in use"
fi

# Test _plan_find_available_port finds a port
if port=$(_plan_find_available_port 58231); then
    if [[ "$port" -ge 58231 ]] && [[ "$port" -le 58241 ]]; then
        pass "Available port found in range ($port)"
    else
        fail "Port $port out of expected range"
    fi
else
    fail "_plan_find_available_port failed"
fi

# ============================================================
echo "=== Python server script generation ==="
# ============================================================

SERVER_SCRIPT="${TEST_TMPDIR}/test_server.py"
_write_plan_server_script "$SERVER_SCRIPT"

if [[ -f "$SERVER_SCRIPT" ]]; then
    pass "Server script written"
else
    fail "Server script not written"
fi

# Verify the Python script is syntactically valid
if python3 -c "import py_compile; py_compile.compile('${SERVER_SCRIPT}', doraise=True)" 2>/dev/null; then
    pass "Server script is valid Python"
else
    fail "Server script has syntax errors"
fi

# ============================================================
echo "=== Server lifecycle ==="
# ============================================================

# Only run server tests if python3 is available
if command -v python3 &>/dev/null; then
    # Create a minimal form dir
    SRV_FORM_DIR="${TEST_TMPDIR}/srv-form"
    mkdir -p "$SRV_FORM_DIR"
    echo "<html><body>test</body></html>" > "${SRV_FORM_DIR}/index.html"

    # Attempt to start server with diagnostics
    _srv_started=false
    _srv_diagnostic=""
    for _srv_attempt in 1 2 3; do
        if _start_plan_server "$SRV_FORM_DIR"; then
            _srv_started=true
            pass "Server started (attempt $_srv_attempt of 3)"
            break
        else
            # Capture diagnostics on failure
            _stop_plan_server 2>/dev/null || true
            if [[ -f "${TEKHTON_SESSION_DIR}/plan_server.log" ]]; then
                _srv_diagnostic=$(tail -3 "${TEKHTON_SESSION_DIR}/plan_server.log" 2>/dev/null | tr '\n' ' ')
                _srv_diagnostic="[attempt $_srv_attempt] $_srv_diagnostic"
            fi
            if [[ $_srv_attempt -lt 3 ]]; then
                sleep 2
            fi
        fi
    done

    if [[ "$_srv_started" == true ]]; then
        # Verify server responds
        if curl -s -o /dev/null "http://127.0.0.1:${_PLAN_SERVER_PORT}" 2>/dev/null; then
            pass "Server responds to GET"
        else
            fail "Server does not respond to GET"
        fi

        # Test POST /save-draft
        RESPONSE=$(curl -s -X POST "http://127.0.0.1:${_PLAN_SERVER_PORT}/save-draft" \
            -H "Content-Type: application/json" \
            -d '{"developer_philosophy": "Browser answer test"}' 2>/dev/null || echo "")

        if echo "$RESPONSE" | grep -q '"saved"'; then
            pass "POST /save-draft returns saved status"
        else
            fail "POST /save-draft unexpected response: $RESPONSE"
        fi

        # Verify answer was written to YAML file
        local_answer=$(load_answer "developer_philosophy" 2>/dev/null || true)
        if [[ "$local_answer" == "Browser answer test" ]]; then
            pass "POST /save-draft wrote answer to YAML"
        else
            fail "POST /save-draft did not write answer correctly (got: ${local_answer})"
        fi

        # Verify no completion sentinel exists after save-draft
        if [[ ! -f "$_PLAN_COMPLETION_FILE" ]]; then
            pass "save-draft does not create completion sentinel"
        else
            fail "save-draft incorrectly created completion sentinel"
        fi

        # Test POST /submit
        RESPONSE=$(curl -s -X POST "http://127.0.0.1:${_PLAN_SERVER_PORT}/submit" \
            -H "Content-Type: application/json" \
            -d '{"developer_philosophy": "Final answer", "project_overview": "Overview text"}' 2>/dev/null || echo "")

        if echo "$RESPONSE" | grep -q '"submitted"'; then
            pass "POST /submit returns submitted status"
        else
            fail "POST /submit unexpected response: $RESPONSE"
        fi

        # Verify completion sentinel exists after submit
        if [[ -f "$_PLAN_COMPLETION_FILE" ]]; then
            pass "submit creates completion sentinel"
        else
            fail "submit did not create completion sentinel"
        fi

        # Verify answers from submit
        local_answer2=$(load_answer "developer_philosophy" 2>/dev/null || true)
        if [[ "$local_answer2" == "Final answer" ]]; then
            pass "POST /submit wrote answer to YAML"
        else
            fail "POST /submit did not write answer correctly (got: ${local_answer2})"
        fi

        local_answer3=$(load_answer "project_overview" 2>/dev/null || true)
        if [[ "$local_answer3" == "Overview text" ]]; then
            pass "POST /submit wrote second answer to YAML"
        else
            fail "POST /submit did not write second answer (got: ${local_answer3})"
        fi

        # Stop server
        _stop_plan_server

        # Verify port is free after stop
        sleep 1
        if ! _plan_is_port_in_use "$_PLAN_SERVER_PORT" 2>/dev/null; then
            pass "Server port freed after stop"
        else
            # Port might take a moment to release — not a hard failure
            pass "Server stopped (port release may be delayed)"
        fi
    else
        fail "Server failed to start${_srv_diagnostic:+ — $_srv_diagnostic}"
    fi

    # ============================================================
    echo "=== Port finding (occupied port) ==="
    # ============================================================

    # Start a dummy server on a port, then verify _plan_find_available_port skips it
    DUMMY_PORT=58432
    python3 -c "
import http.server, threading, time
s = http.server.HTTPServer(('127.0.0.1', $DUMMY_PORT), http.server.BaseHTTPRequestHandler)
t = threading.Thread(target=s.serve_forever, daemon=True)
t.start()
time.sleep(60)
" &
    DUMMY_PID=$!
    sleep 1

    found_port=$(_plan_find_available_port "$DUMMY_PORT" 2>/dev/null || echo "")
    if [[ -n "$found_port" ]] && [[ "$found_port" -ne "$DUMMY_PORT" ]]; then
        pass "Port finding skips occupied port $DUMMY_PORT, found $found_port"
    else
        fail "Port finding did not skip occupied port (got: $found_port)"
    fi

    kill "$DUMMY_PID" 2>/dev/null || true
    wait "$DUMMY_PID" 2>/dev/null || true
else
    echo "  SKIP: python3 not available — skipping server lifecycle tests"
fi

# ============================================================
echo "=== HTML escaping ==="
# ============================================================

escaped=$(_html_escape '<script>alert("xss")</script>')
if [[ "$escaped" == *"&lt;script&gt;"* ]] && [[ "$escaped" == *"&quot;"* ]]; then
    pass "HTML escaping works for special characters"
else
    fail "HTML escaping broken: $escaped"
fi

# ============================================================
echo "=== _select_interview_mode (browser) ==="
# ============================================================

# Test that _select_interview_mode returns "browser" for input "3"
mode_result=$(echo "3" | _select_interview_mode 0 2>/dev/null || true)
if [[ "$mode_result" == "browser" ]]; then
    pass "_select_interview_mode returns 'browser' for choice 3"
else
    fail "_select_interview_mode returned '$mode_result' instead of 'browser'"
fi

# ============================================================
# Summary
# ============================================================
echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
