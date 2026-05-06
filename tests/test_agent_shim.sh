#!/usr/bin/env bash
# test_agent_shim.sh — Unit tests for lib/agent_shim.sh (suites 1–6).
# Extended suites (7–10: null-run detection, exec_rc fallback, round-trip,
# tool profiles) live in test_agent_shim_extras.sh — extracted in m12 to
# stay under the 300-line bash ceiling.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Stub logging so tests aren't polluted by output.sh's TUI machinery.
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }
log_verbose() { :; }
emit_event() { :; }

# Stub common.sh _tui_* so sourcing agent_shim.sh doesn't need the sidecar.
_TUI_ACTIVE=false
export _TUI_ACTIVE

# Source _json_escape from common.sh (agent_shim.sh requires it).
# Override the function BEFORE sourcing agent_shim.sh so our stub is used if
# needed, but common.sh's production version is preferred.
source "${TEKHTON_HOME}/lib/common.sh"

# Now source the unit under test.
source "${TEKHTON_HOME}/lib/agent_shim.sh"

# ---------------------------------------------------------------------------
PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" = "$got" ]]; then pass "$name"
    else fail "$name — want '${want}', got '${got}'"
    fi
}

assert_not_empty() {
    local name="$1" val="$2"
    if [[ -n "$val" ]]; then pass "$name"
    else fail "$name — expected non-empty, got empty"
    fi
}

# =============================================================================
# Suite 1: V3 contract globals initialized on source
# =============================================================================
echo "=== Suite 1: V3 contract globals defaults ==="

assert_eq "1.1 LAST_AGENT_TURNS=0"          "0"     "$LAST_AGENT_TURNS"
assert_eq "1.2 LAST_AGENT_EXIT_CODE=0"       "0"     "$LAST_AGENT_EXIT_CODE"
assert_eq "1.3 LAST_AGENT_ELAPSED=0"         "0"     "$LAST_AGENT_ELAPSED"
assert_eq "1.4 LAST_AGENT_NULL_RUN=false"    "false" "$LAST_AGENT_NULL_RUN"
assert_eq "1.5 LAST_AGENT_RETRY_COUNT=0"     "0"     "$LAST_AGENT_RETRY_COUNT"
assert_eq "1.6 TOTAL_AGENT_INVOCATIONS=0"    "0"     "$TOTAL_AGENT_INVOCATIONS"
assert_eq "1.7 AGENT_ERROR_CATEGORY empty"  ""      "$AGENT_ERROR_CATEGORY"
assert_eq "1.8 AGENT_ERROR_MESSAGE empty"   ""      "$AGENT_ERROR_MESSAGE"
# m12 deleted _RWR_*; LAST_AGENT_WAS_ACTIVITY_TIMEOUT is the survivor.
assert_eq "1.9 LAST_AGENT_WAS_ACTIVITY_TIMEOUT=false" "false" "$LAST_AGENT_WAS_ACTIVITY_TIMEOUT"

# =============================================================================
# Suite 2: _shim_resolve_binary
# =============================================================================
echo "=== Suite 2: _shim_resolve_binary ==="

# Test 2.1: TEKHTON_BIN env var points at an executable → returned directly.
_mock_bin="${TMPDIR}/mock_tekhton"
printf '#!/bin/sh\n' > "$_mock_bin"
chmod +x "$_mock_bin"
result=$(TEKHTON_BIN="$_mock_bin" _shim_resolve_binary)
assert_eq "2.1 TEKHTON_BIN respected" "$_mock_bin" "$result"

# Test 2.2: TEKHTON_BIN set to non-executable → falls through.
_non_exec="${TMPDIR}/not_executable"
touch "$_non_exec"
# non-executable; should not be returned
result=$(TEKHTON_BIN="$_non_exec" TEKHTON_HOME="${TMPDIR}/nohome" _shim_resolve_binary 2>/dev/null || true)
# Should not equal the non-executable file (will be empty or PATH/home result)
if [[ "$result" = "$_non_exec" ]]; then
    fail "2.2 non-executable TEKHTON_BIN should not be returned"
else
    pass "2.2 non-executable TEKHTON_BIN falls through"
fi

# Test 2.3: TEKHTON_HOME/bin/tekhton exists and is executable → returned.
_home="${TMPDIR}/fakehome"
mkdir -p "${_home}/bin"
_home_bin="${_home}/bin/tekhton"
printf '#!/bin/sh\n' > "$_home_bin"
chmod +x "$_home_bin"
result=$(TEKHTON_BIN="" TEKHTON_HOME="$_home" PATH="/nonexistent_$$" _shim_resolve_binary 2>/dev/null || true)
assert_eq "2.3 TEKHTON_HOME/bin/tekhton fallback" "$_home_bin" "$result"

# Test 2.4: Nothing found → returns 1.
rc=0
TEKHTON_BIN="" TEKHTON_HOME="${TMPDIR}/empty_home" PATH="/nonexistent_$$" \
    _shim_resolve_binary >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
    pass "2.4 not found returns 1"
else
    fail "2.4 expected non-zero return when binary not found"
fi

# =============================================================================
# Suite 3: _shim_write_request
# =============================================================================
echo "=== Suite 3: _shim_write_request ==="

_req="${TMPDIR}/req_test.json"
_shim_write_request "$_req" "run-123" "Scout" "claude-sonnet-4-6" \
    "50" "/tmp/prompt.md" "/home/user/project" "7200" "600"

# 3.1 File was created.
if [[ -f "$_req" ]]; then pass "3.1 request file created"; else fail "3.1 request file not created"; fi

# 3.2 Contains proto tag.
if grep -q '"proto":"tekhton.agent.request.v1"' "$_req"; then
    pass "3.2 proto field present"
else
    fail "3.2 proto field missing: $(cat "$_req")"
fi

# 3.3 run_id matches.
if grep -q '"run_id":"run-123"' "$_req"; then
    pass "3.3 run_id field correct"
else
    fail "3.3 run_id field missing: $(cat "$_req")"
fi

# 3.4 label matches.
if grep -q '"label":"Scout"' "$_req"; then
    pass "3.4 label field correct"
else
    fail "3.4 label field missing: $(cat "$_req")"
fi

# 3.5 max_turns is numeric (no quotes).
if grep -qE '"max_turns":50' "$_req"; then
    pass "3.5 max_turns is numeric"
else
    fail "3.5 max_turns not numeric: $(cat "$_req")"
fi

# 3.6 timeout_secs is numeric.
if grep -qE '"timeout_secs":7200' "$_req"; then
    pass "3.6 timeout_secs is numeric"
else
    fail "3.6 timeout_secs not numeric: $(cat "$_req")"
fi

# 3.7 activity_timeout_secs is numeric.
if grep -qE '"activity_timeout_secs":600' "$_req"; then
    pass "3.7 activity_timeout_secs is numeric"
else
    fail "3.7 activity_timeout_secs not numeric: $(cat "$_req")"
fi

# 3.8 Special characters in label are escaped (double-quote in label).
_req2="${TMPDIR}/req_escaped.json"
_shim_write_request "$_req2" "run-2" 'label"with"quotes' "model" \
    "10" "/p" "/w" "60" "30"
if grep -q '"label":"label\\"with\\"quotes"' "$_req2"; then
    pass "3.8 double-quotes in label are escaped"
else
    fail "3.8 label quoting issue: $(cat "$_req2")"
fi

# =============================================================================
# Suite 4: _shim_field
# =============================================================================
echo "=== Suite 4: _shim_field ==="

_resp="${TMPDIR}/resp_test.json"
cat > "$_resp" <<'EOF'
{
  "proto": "tekhton.agent.response.v1",
  "run_id": "run-abc",
  "outcome": "success",
  "exit_code": 0,
  "turns_used": 7,
  "error_message": "",
  "error_category": "UPSTREAM",
  "error_transient": "true"
}
EOF

# 4.1 String field extraction.
v=$(_shim_field "$_resp" outcome)
assert_eq "4.1 string field (outcome)" "success" "$v"

# 4.2 Numeric field extraction.
v=$(_shim_field "$_resp" turns_used)
assert_eq "4.2 numeric field (turns_used)" "7" "$v"

# 4.3 Zero value numeric.
v=$(_shim_field "$_resp" exit_code)
assert_eq "4.3 zero value numeric (exit_code)" "0" "$v"

# 4.4 Missing field → empty string.
v=$(_shim_field "$_resp" nonexistent_field)
assert_eq "4.4 missing field returns empty" "" "$v"

# 4.5 Empty string field returns empty.
v=$(_shim_field "$_resp" error_message)
assert_eq "4.5 empty string field returns empty" "" "$v"

# 4.6 Boolean-like string field.
v=$(_shim_field "$_resp" error_transient)
assert_eq "4.6 boolean-like string field" "true" "$v"

# 4.7 File does not exist → returns empty (no error).
rc=0
v=$(_shim_field "/nonexistent_$$/response.json" outcome) || rc=$?
assert_eq "4.7 nonexistent file returns empty" "" "$v"

# 4.8 Escaped quotes in string value.
_resp2="${TMPDIR}/resp_escaped.json"
cat > "$_resp2" <<'EOF'
{"error_message":"could not parse \"config.json\""}
EOF
v=$(_shim_field "$_resp2" error_message)
if [[ "$v" = 'could not parse "config.json"' ]]; then
    pass "4.8 escaped quotes in string value"
else
    fail "4.8 escaped quote handling — got: '$v'"
fi

# =============================================================================
# Suite 5: _shim_apply_response — happy path
# =============================================================================
echo "=== Suite 5: _shim_apply_response happy path ==="

_resp3="${TMPDIR}/resp_happy.json"
cat > "$_resp3" <<'EOF'
{
  "proto": "tekhton.agent.response.v1",
  "outcome": "success",
  "exit_code": 0,
  "turns_used": 12,
  "error_message": "",
  "error_category": "",
  "error_subcategory": "",
  "error_transient": ""
}
EOF

_shim_apply_response "$_resp3" 0

assert_eq "5.1 LAST_AGENT_EXIT_CODE=0"    "0"     "$LAST_AGENT_EXIT_CODE"
assert_eq "5.2 LAST_AGENT_TURNS=12"       "12"    "$LAST_AGENT_TURNS"
assert_eq "5.3 LAST_AGENT_NULL_RUN=false" "false" "$LAST_AGENT_NULL_RUN"
assert_eq "5.4 LAST_AGENT_WAS_ACTIVITY_TIMEOUT=false" "false" "$LAST_AGENT_WAS_ACTIVITY_TIMEOUT"
assert_eq "5.5 AGENT_ERROR_CATEGORY empty" ""     "$AGENT_ERROR_CATEGORY"

# =============================================================================
# Suite 6: _shim_apply_response — activity timeout outcome
# =============================================================================
echo "=== Suite 6: _shim_apply_response activity_timeout ==="

_resp4="${TMPDIR}/resp_timeout.json"
cat > "$_resp4" <<'EOF'
{
  "proto": "tekhton.agent.response.v1",
  "outcome": "activity_timeout",
  "exit_code": 1,
  "turns_used": 0,
  "error_message": "agent timed out",
  "error_category": "AGENT_SCOPE",
  "error_subcategory": "activity_timeout",
  "error_transient": "false"
}
EOF

_shim_apply_response "$_resp4" 1

assert_eq "6.1 LAST_AGENT_WAS_ACTIVITY_TIMEOUT=true" "true"            "$LAST_AGENT_WAS_ACTIVITY_TIMEOUT"
assert_eq "6.2 LAST_AGENT_EXIT_CODE=1"           "1"              "$LAST_AGENT_EXIT_CODE"
assert_eq "6.3 AGENT_ERROR_CATEGORY=AGENT_SCOPE" "AGENT_SCOPE"   "$AGENT_ERROR_CATEGORY"
assert_eq "6.4 AGENT_ERROR_SUBCATEGORY"          "activity_timeout" "$AGENT_ERROR_SUBCATEGORY"

# =============================================================================
# Summary
# =============================================================================
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
