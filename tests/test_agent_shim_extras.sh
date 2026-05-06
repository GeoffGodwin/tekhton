#!/usr/bin/env bash
# =============================================================================
# test_agent_shim_extras.sh — Extended tests for lib/agent_shim.sh
#
# Extracted from test_agent_shim.sh during the m12 wedge to keep the parent
# file under the 300-line bash ceiling. Suites 7–10 (null-run detection,
# exec_rc fallback, request/response round-trip, tool profile exports).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Stub logging so tests aren't polluted by output.sh's TUI machinery.
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
header()      { :; }
log_verbose() { :; }
emit_event()  { :; }

_TUI_ACTIVE=false
export _TUI_ACTIVE

# shellcheck source=lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=lib/agent_shim.sh
source "${TEKHTON_HOME}/lib/agent_shim.sh"

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

# =============================================================================
# Suite 7: _shim_apply_response — null run detection
# =============================================================================
echo "=== Suite 7: _shim_apply_response null run detection ==="

# 7.1 exit_code != 0 AND turns_used <= threshold (2) → LAST_AGENT_NULL_RUN=true
_resp5="${TMPDIR}/resp_nullrun.json"
cat > "$_resp5" <<'EOF'
{
  "outcome": "fatal_error",
  "exit_code": 1,
  "turns_used": 1
}
EOF
# shellcheck disable=SC2034  # consumed by _shim_apply_response
AGENT_NULL_RUN_THRESHOLD=2
_shim_apply_response "$_resp5" 1
assert_eq "7.1 null run: nonzero exit + low turns" "true" "$LAST_AGENT_NULL_RUN"

# 7.2 exit_code != 0 AND turns_used > threshold → NOT null run
_resp6="${TMPDIR}/resp_not_nullrun.json"
cat > "$_resp6" <<'EOF'
{
  "outcome": "fatal_error",
  "exit_code": 1,
  "turns_used": 5
}
EOF
# shellcheck disable=SC2034  # consumed by _shim_apply_response
AGENT_NULL_RUN_THRESHOLD=2
_shim_apply_response "$_resp6" 1
assert_eq "7.2 not null run: nonzero exit + turns above threshold" "false" "$LAST_AGENT_NULL_RUN"

# 7.3 turns_used == 0 → null run regardless of exit code
_resp7="${TMPDIR}/resp_zero_turns.json"
cat > "$_resp7" <<'EOF'
{
  "outcome": "success",
  "exit_code": 0,
  "turns_used": 0
}
EOF
_shim_apply_response "$_resp7" 0
assert_eq "7.3 null run: zero turns" "true" "$LAST_AGENT_NULL_RUN"

# 7.4 Successful run with substantial turns → NOT null run
_resp8="${TMPDIR}/resp_substantive.json"
cat > "$_resp8" <<'EOF'
{
  "outcome": "success",
  "exit_code": 0,
  "turns_used": 15
}
EOF
_shim_apply_response "$_resp8" 0
assert_eq "7.4 not null run: success + substantive turns" "false" "$LAST_AGENT_NULL_RUN"

# =============================================================================
# Suite 8: _shim_apply_response — exec_rc fallback when exit_code absent
# =============================================================================
echo "=== Suite 8: _shim_apply_response exec_rc fallback ==="

_resp9="${TMPDIR}/resp_no_exitcode.json"
cat > "$_resp9" <<'EOF'
{
  "outcome": "fatal_error",
  "turns_used": 3
}
EOF
_shim_apply_response "$_resp9" 42
assert_eq "8.1 exec_rc fallback when exit_code absent" "42" "$LAST_AGENT_EXIT_CODE"

# =============================================================================
# Suite 9: _shim_write_request + _shim_field round-trip
# =============================================================================
echo "=== Suite 9: request write / field read round-trip ==="

_rreq="${TMPDIR}/roundtrip_req.json"
_shim_write_request "$_rreq" "rt-run" "Coder" "claude-opus-4-7" \
    "100" "/srv/prompt.md" "/srv/project" "3600" "300"

assert_eq "9.1 round-trip proto"     "tekhton.agent.request.v1" "$(_shim_field "$_rreq" proto)"
assert_eq "9.2 round-trip run_id"    "rt-run"                   "$(_shim_field "$_rreq" run_id)"
assert_eq "9.3 round-trip label"     "Coder"                    "$(_shim_field "$_rreq" label)"
assert_eq "9.4 round-trip model"     "claude-opus-4-7"          "$(_shim_field "$_rreq" model)"
assert_eq "9.5 round-trip max_turns" "100"                      "$(_shim_field "$_rreq" max_turns)"

# =============================================================================
# Suite 10: Tool profile exports present after sourcing
# =============================================================================
echo "=== Suite 10: Tool profiles exported ==="

[[ -n "${AGENT_TOOLS_CODER:-}" ]]   && pass "10.1 AGENT_TOOLS_CODER exported"   || fail "10.1 AGENT_TOOLS_CODER missing"
[[ -n "${AGENT_TOOLS_SCOUT:-}" ]]   && pass "10.2 AGENT_TOOLS_SCOUT exported"   || fail "10.2 AGENT_TOOLS_SCOUT missing"
[[ -n "${AGENT_TOOLS_TESTER:-}" ]]  && pass "10.3 AGENT_TOOLS_TESTER exported"  || fail "10.3 AGENT_TOOLS_TESTER missing"
[[ -n "${AGENT_DISALLOWED_TOOLS:-}" ]] && pass "10.4 AGENT_DISALLOWED_TOOLS exported" || fail "10.4 AGENT_DISALLOWED_TOOLS missing"

if echo "${AGENT_DISALLOWED_TOOLS}" | grep -q 'git push'; then
    pass "10.5 AGENT_DISALLOWED_TOOLS contains git push protection"
else
    fail "10.5 AGENT_DISALLOWED_TOOLS missing git push guard: ${AGENT_DISALLOWED_TOOLS}"
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
