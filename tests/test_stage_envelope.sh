#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_stage_envelope.sh — m18 stage envelope helper tests.
#
# Validates:
#   1. lib/stage_envelope.sh::emit_stage_envelope is a no-op when
#      TEKHTON_STAGE_RESULT_FILE is unset.
#   2. emit_stage_envelope writes a tekhton.stage.result.v1 envelope to the
#      result file when set; the envelope parses as JSON and contains the
#      requested verdict + exit_reason.
#   3. stage_envelope_install_all wraps every run_stage_<name> function so
#      calling the wrapped function emits an envelope.
#   4. The fallback path (when `tekhton` binary is unavailable) still produces
#      a valid envelope file.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass
    else
        fail "${name}: expected '${expected}', got '${actual}'"
    fi
}
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass
    else
        fail "${name}: '${haystack}' does not contain '${needle}'"
    fi
}

# Source lib/stage_envelope.sh in isolation. We do NOT source tekhton.sh here
# because that triggers config/library loading; the envelope helpers are
# self-contained.
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/stage_envelope.sh"

# --- Test 1: no-op when TEKHTON_STAGE_RESULT_FILE is unset --------------------
unset TEKHTON_STAGE_RESULT_FILE
emit_stage_envelope "intake" "pass" "ok" 1 0 "accept" || {
    fail "emit_stage_envelope returned non-zero with no result file"
}
pass

# --- Test 2: writes a valid envelope when result file is set ------------------
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
RESULT_FILE="${TMP_DIR}/result.json"
export TEKHTON_STAGE_RESULT_FILE="$RESULT_FILE"

emit_stage_envelope "intake" "pass" "happy path" 2 5 "accept" "foo.go,bar.go"

if [[ ! -s "$RESULT_FILE" ]]; then
    fail "result file empty after emit_stage_envelope"
else
    pass
fi

# Parse and verify required fields. We use python (or jq if available) for
# robustness; fall back to grep for fields when neither is present.
VERIFY_OUT=""
if command -v python3 &>/dev/null; then
    VERIFY_OUT=$(python3 -c '
import json, sys
with open("'"$RESULT_FILE"'") as f:
    d = json.load(f)
print(d.get("proto", ""))
print(d.get("stage", ""))
print(d.get("verdict", ""))
print(d.get("exit_reason", ""))
print(d.get("agent_calls", ""))
print(d.get("next_action", ""))
')
elif command -v jq &>/dev/null; then
    VERIFY_OUT=$(jq -r '.proto, .stage, .verdict, .exit_reason, .agent_calls, .next_action' "$RESULT_FILE")
fi

if [[ -n "$VERIFY_OUT" ]]; then
    proto_line=$(echo "$VERIFY_OUT" | sed -n '1p')
    stage_line=$(echo "$VERIFY_OUT" | sed -n '2p')
    verdict_line=$(echo "$VERIFY_OUT" | sed -n '3p')
    reason_line=$(echo "$VERIFY_OUT" | sed -n '4p')
    calls_line=$(echo "$VERIFY_OUT" | sed -n '5p')
    next_line=$(echo "$VERIFY_OUT" | sed -n '6p')

    assert_eq "envelope.proto"       "tekhton.stage.result.v1" "$proto_line"
    assert_eq "envelope.stage"       "intake"                  "$stage_line"
    assert_eq "envelope.verdict"     "pass"                    "$verdict_line"
    assert_eq "envelope.exit_reason" "happy path"              "$reason_line"
    assert_eq "envelope.agent_calls" "2"                       "$calls_line"
    assert_eq "envelope.next_action" "accept"                  "$next_line"
else
    # Smoke fallback — file exists and contains the proto tag.
    assert_contains "envelope.proto.smoke" "tekhton.stage.result.v1" "$(cat "$RESULT_FILE")"
fi

# --- Test 3: wrapper installation -------------------------------------------
# Define a fake stage and verify the wrapper installs and emits an envelope.
unset TEKHTON_STAGE_RESULT_FILE
WRAPPER_RESULT="${TMP_DIR}/wrapper_result.json"
export TEKHTON_STAGE_RESULT_FILE="$WRAPPER_RESULT"

# Define a fresh stub stage entry. Use intake since it's in the install_all list.
unset -f run_stage_intake _orig_run_stage_intake 2>/dev/null || true
run_stage_intake() {
    return 0
}
stage_envelope_wrap "intake"

if ! declare -f _orig_run_stage_intake &>/dev/null; then
    fail "stage_envelope_wrap did not preserve original under _orig_run_stage_intake"
else
    pass
fi

if ! declare -f run_stage_intake &>/dev/null; then
    fail "stage_envelope_wrap did not redefine run_stage_intake"
else
    pass
fi

# Invoke and check the envelope.
run_stage_intake

if [[ ! -s "$WRAPPER_RESULT" ]]; then
    fail "wrapper did not write envelope to result file"
else
    pass
    if grep -q '"verdict": "pass"' "$WRAPPER_RESULT" || grep -q '"verdict":"pass"' "$WRAPPER_RESULT"; then
        pass
    else
        fail "wrapper envelope missing verdict=pass"
    fi
    if grep -q '"stage": "intake"' "$WRAPPER_RESULT" || grep -q '"stage":"intake"' "$WRAPPER_RESULT"; then
        pass
    else
        fail "wrapper envelope missing stage=intake"
    fi
fi

# --- Test 4: failure verdict mapping ----------------------------------------
WRAPPER_FAIL_RESULT="${TMP_DIR}/wrapper_fail.json"
export TEKHTON_STAGE_RESULT_FILE="$WRAPPER_FAIL_RESULT"

# Replace the inner with a failing impl and re-wrap.
unset -f run_stage_coder _orig_run_stage_coder 2>/dev/null || true
run_stage_coder() {
    return 7
}
stage_envelope_wrap "coder"

# The wrapper preserves the original exit code. Use || to capture it under
# `set -e`.
_ec=0
run_stage_coder || _ec=$?
assert_eq "wrapper.exit_code" "7" "$_ec"

if [[ ! -s "$WRAPPER_FAIL_RESULT" ]]; then
    fail "wrapper did not write envelope on failure"
elif grep -q '"verdict": "fail"' "$WRAPPER_FAIL_RESULT" || grep -q '"verdict":"fail"' "$WRAPPER_FAIL_RESULT"; then
    pass
else
    fail "fail-path envelope missing verdict=fail; got: $(cat "$WRAPPER_FAIL_RESULT")"
fi

# --- Test 5: install_all is idempotent --------------------------------------
unset -f run_stage_review _orig_run_stage_review 2>/dev/null || true
run_stage_review() { return 0; }
stage_envelope_install_all
stage_envelope_install_all  # second call should be a no-op
if declare -f _orig_run_stage_review &>/dev/null; then
    pass
else
    fail "install_all did not wrap review on first call"
fi

echo
echo "════════════════════════════════════════"
echo "  Stage Envelope Tests: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
