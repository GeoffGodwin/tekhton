#!/usr/bin/env bash
# tests/test_plan_batch_label_routing.sh — m22 label-routing unit test.
#
# Verifies that _call_planning_batch passes the label (5th arg) through to
# _shim_write_request as the 3rd positional argument, so the Go supervisor
# can use it for PROVIDER_<LABEL> routing.
#
# m22 adds the optional 5th label arg to _call_planning_batch and updates all
# callers (plan_interview, plan_generate, plan_followup_interview, replan,
# replan_brownfield, replan_midrun) to pass their stage-specific labels.
# Without the label, the PROVIDER_plan_interview override is silently ignored.
#
# Tests:
#   A — explicit label "plan_interview" → _shim_write_request receives "plan_interview"
#   B — explicit label "plan_generate"  → _shim_write_request receives "plan_generate"
#   C — explicit label "replan"         → _shim_write_request receives "replan"
#   D — no label (default)              → _shim_write_request receives "planning"
#   E — structural: _call_planning_batch 5th-arg default is "planning" in source
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

WORK_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

LOG_FILE="${WORK_DIR}/plan.log"
touch "$LOG_FILE"

# Capture file: written by fake _shim_write_request with the label argument.
LABEL_CAP="${WORK_DIR}/captured_label.txt"

# Fake tekhton binary — accepts "supervise --request-file SOMETHING" and emits
# a minimal agent.response.v1 to stdout. The response has exit_code=0 and an
# empty stdout_tail so _call_planning_batch returns cleanly.
FAKE_BIN="${WORK_DIR}/tekhton"
cat > "$FAKE_BIN" << 'BIN_EOF'
#!/usr/bin/env bash
# Emit minimal agent.response.v1 JSON to stdout.
printf '{"proto":"tekhton.agent.response.v1","exit_code":0,"outcome":"success","turns_used":1,"stdout_tail":null}\n'
exit 0
BIN_EOF
chmod +x "$FAKE_BIN"

# Stub logging.
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
log_verbose() { :; }
header()      { :; }
emit_event()  { :; }
_TUI_ACTIVE=false

export TEKHTON_HOME TEKHTON_TEST_MODE=1 PROJECT_DIR="${WORK_DIR}"
export TEKHTON_SESSION_DIR="${WORK_DIR}"
export TEKHTON_BIN="${FAKE_BIN}"
export _TUI_ACTIVE

# Override _shim_resolve_binary before sourcing plan_batch.sh so the lazy-load
# block picks up the stub. Declare the stubs early so the plan_batch.sh
# source-time guard skips sourcing agent_shim.sh (which would pull in common.sh
# and overwrite our stubs).
_shim_resolve_binary() {
    printf '%s\n' "${FAKE_BIN}"; return 0
}

# _shim_write_request: write label (3rd arg) to capture file; create request JSON.
_shim_write_request() {
    local _cap_lbl="$3"
    printf '%s' "$_cap_lbl" > "${LABEL_CAP}"
    printf '{"proto":"tekhton.agent.request.v1","label":"%s"}\n' "$_cap_lbl" > "$1"
}

# _shim_field: return stub values for fields parsed from the response file.
_shim_field() {
    local _field="$2"
    case "$_field" in
        exit_code) echo "0" ;;
        *)         echo "" ;;
    esac
}

# _json_escape: minimal stub (common.sh normally provides this).
_json_escape() { printf '%s' "$1"; }

# Source plan_batch.sh under test. The guard at the top skips agent_shim.sh
# because _shim_resolve_binary is already declared.
# shellcheck source=../lib/plan_batch.sh
source "${TEKHTON_HOME}/lib/plan_batch.sh"

# --- helper: call _call_planning_batch and read captured label ---------------
_run_and_capture_label() {
    local _label_arg="${1:-}"
    rm -f "${LABEL_CAP}"
    if [[ -n "$_label_arg" ]]; then
        (
            export TEKHTON_BIN="${FAKE_BIN}"
            _call_planning_batch "model" "5" "test prompt" "$LOG_FILE" "$_label_arg"
        ) > /dev/null 2>&1 || true
    else
        (
            export TEKHTON_BIN="${FAKE_BIN}"
            _call_planning_batch "model" "5" "test prompt" "$LOG_FILE"
        ) > /dev/null 2>&1 || true
    fi
    cat "${LABEL_CAP}" 2>/dev/null || echo ""
}

# --- A: label "plan_interview" -----------------------------------------------
got_a=$(_run_and_capture_label "plan_interview")
if [[ "$got_a" == "plan_interview" ]]; then
    pass "A: label 'plan_interview' passed through to _shim_write_request"
else
    fail "A: expected 'plan_interview', got '${got_a}'"
fi

# --- B: label "plan_generate" ------------------------------------------------
got_b=$(_run_and_capture_label "plan_generate")
if [[ "$got_b" == "plan_generate" ]]; then
    pass "B: label 'plan_generate' passed through to _shim_write_request"
else
    fail "B: expected 'plan_generate', got '${got_b}'"
fi

# --- C: label "replan" -------------------------------------------------------
got_c=$(_run_and_capture_label "replan")
if [[ "$got_c" == "replan" ]]; then
    pass "C: label 'replan' passed through to _shim_write_request"
else
    fail "C: expected 'replan', got '${got_c}'"
fi

# --- D: no label — default is "planning" -------------------------------------
got_d=$(_run_and_capture_label)
if [[ "$got_d" == "planning" ]]; then
    pass "D: default label 'planning' used when 5th arg is absent"
else
    fail "D: expected 'planning' (default), got '${got_d}'"
fi

# --- E: structural — source confirms default is "planning" -------------------
# Check that the source file contains the expected default: ${5:-planning}
# This catches regressions where someone changes the default without noticing.
PLAN_BATCH="${TEKHTON_HOME}/lib/plan_batch.sh"
if grep -qE '\$\{5:-planning\}' "$PLAN_BATCH" 2>/dev/null; then
    pass "E: _call_planning_batch 5th-arg default is 'planning' (${5:-planning} pattern present)"
else
    fail "E: '${5:-planning}' pattern not found in lib/plan_batch.sh — default label may have changed"
fi

# --- summary -----------------------------------------------------------------
if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo "All plan_batch label routing tests passed (${PASS_COUNT})"
    exit 0
else
    echo "FAIL: ${FAIL_COUNT} tests failed (${PASS_COUNT} passed)"
    exit 1
fi
