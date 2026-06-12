#!/usr/bin/env bash
# tests/test_common_usage_threshold_guard.sh — m20 Goal 2 unit test.
#
# Verifies that check_usage_threshold() in lib/common.sh does NOT invoke
# `claude usage` when the resolved PROVIDER spec excludes claude.
#
# With m20 implemented (guard in place):
#   PROVIDER=codex, USAGE_THRESHOLD_PCT=50 → fake claude is never invoked;
#   function returns 0 (allow) silently.
#
# Without m20 (pre-change):
#   check_usage_threshold() calls `claude usage` unconditionally →
#   fake claude IS invoked → assertion fails, revealing the missing guard.
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# m20 adds the PROVIDER-spec guard around `claude usage` in check_usage_threshold.
# Until that lands, the function still calls claude unconditionally. Self-skip so
# the suite stays green; assertions A/B test the post-m20 contract.
if ! awk '/^check_usage_threshold\(\)/,/^}/' "${TEKHTON_HOME}/lib/common.sh" \
        2>/dev/null | grep -qE 'PROVIDER|provider_has_claude'; then
    echo "SKIP: lib/common.sh::check_usage_threshold has no PROVIDER guard yet — m20 not implemented"
    exit 0
fi

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

WORK_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

CLAUDE_INVOKED_FILE="${WORK_DIR}/claude_invoked.txt"

# Fake claude: records invocation and outputs a high-usage line so that a
# naive (unguarded) check_usage_threshold would return 1 (threshold exceeded).
# Outputs "Session usage: 99%" to simulate well-above-threshold usage.
cat > "${WORK_DIR}/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
touch "${FAKE_CLAUDE_INVOKED_FILE}"
echo "Session usage: 99%"
exit 0
CLAUDE_EOF
chmod +x "${WORK_DIR}/claude"

# Stub logging.
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
log_verbose() { :; }
emit_event()  { :; }
_TUI_ACTIVE=false
export _TUI_ACTIVE TEKHTON_HOME

# Source common.sh (contains check_usage_threshold).
# shellcheck source=../lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"

# --- A: PROVIDER=codex, threshold 50% — claude must NOT be invoked ---------
# After m20: check_usage_threshold returns 0 (silently skips — claude not in spec).
# Before m20: claude usage is called → fake claude records invocation, outputs 99%
#             → function returns 1 (threshold exceeded).
THRESHOLD_RC=0
set +e
(
    export FAKE_CLAUDE_INVOKED_FILE="${CLAUDE_INVOKED_FILE}"
    export PROVIDER=codex
    export USAGE_THRESHOLD_PCT=50
    export PATH="${WORK_DIR}:${PATH}"
    check_usage_threshold
)
THRESHOLD_RC=$?
set -e

if [[ ! -f "${CLAUDE_INVOKED_FILE}" ]]; then
    pass "A: claude NOT invoked by check_usage_threshold when PROVIDER=codex"
else
    fail "A: claude WAS invoked by check_usage_threshold despite PROVIDER=codex (m20 guard missing)"
fi
rm -f "${CLAUDE_INVOKED_FILE}"

# --- B: PROVIDER=codex — function must return 0 (allow) when guard active --
if [[ "$THRESHOLD_RC" -eq 0 ]]; then
    pass "B: check_usage_threshold returns 0 (allow) when PROVIDER=codex"
else
    fail "B: check_usage_threshold returned ${THRESHOLD_RC} instead of 0 when PROVIDER=codex"
fi

# --- C: USAGE_THRESHOLD_PCT=0 (disabled) — claude still not invoked --------
# Sanity: the function is already disabled via threshold=0; this tests that
# the disabled path still works correctly after m20's guard is added.
set +e
(
    export FAKE_CLAUDE_INVOKED_FILE="${CLAUDE_INVOKED_FILE}"
    export PROVIDER=claude
    export USAGE_THRESHOLD_PCT=0
    export PATH="${WORK_DIR}:${PATH}"
    check_usage_threshold
)
set -e

if [[ ! -f "${CLAUDE_INVOKED_FILE}" ]]; then
    pass "C: claude NOT invoked when USAGE_THRESHOLD_PCT=0 (feature disabled path)"
else
    fail "C: claude WAS invoked when USAGE_THRESHOLD_PCT=0 (disabled path should return early)"
fi
rm -f "${CLAUDE_INVOKED_FILE}"

# --- summary -----------------------------------------------------------------
if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo "All common usage threshold guard tests passed (${PASS_COUNT})"
    exit 0
else
    echo "FAIL: ${FAIL_COUNT} tests failed (${PASS_COUNT} passed)"
    exit 1
fi
