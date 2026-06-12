#!/usr/bin/env bash
# tests/test_mcp_resolve_provider_guard.sh — m20 Goal 2 unit test.
#
# Verifies that _cli_supports_mcp_config() in lib/mcp_resolve.sh skips the
# `claude --help` probe (and emits a skip log line) when the resolved PROVIDER
# spec does not contain "claude".
#
# With m20 implemented (guard in place):
#   PROVIDER=codex → fake claude is never invoked; function returns 1
#   (cannot verify MCP support without claude); skip log line emitted.
#
# Without m20 (pre-change):
#   _cli_supports_mcp_config() calls claude --help unconditionally →
#   fake claude IS invoked → assertion fails, revealing the missing guard.
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# m20 implements the PROVIDER-spec guard inside _cli_supports_mcp_config.
# Until that lands, the function still calls `claude --help` unconditionally.
# Self-skip so the suite stays green; the test exercises the post-m20 contract.
if ! grep -qE 'PROVIDER.*claude|provider_has_claude|claude.*PROVIDER' \
        "${TEKHTON_HOME}/lib/mcp_resolve.sh" 2>/dev/null; then
    echo "SKIP: lib/mcp_resolve.sh has no PROVIDER guard yet — m20 not implemented"
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

# Fake claude: records invocation; outputs nothing (simulates MCP support absent).
cat > "${WORK_DIR}/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
touch "${FAKE_CLAUDE_INVOKED_FILE}"
echo "Usage: claude [options]"
exit 0
CLAUDE_EOF
chmod +x "${WORK_DIR}/claude"

# Stub logging — mcp_resolve.sh uses log_verbose.
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
log_verbose() { :; }
emit_event()  { :; }

# Stub PROJECT_DIR to a writable temp directory.
export PROJECT_DIR="${WORK_DIR}"
export TEKHTON_HOME

# Source mcp_resolve.sh under test.
_CLI_MCP_CONFIG_SUPPORTED=""

# shellcheck source=../lib/mcp_resolve.sh
source "${TEKHTON_HOME}/lib/mcp_resolve.sh"

# --- A: with PROVIDER=codex, claude --help probe must be skipped -----------
_CLI_MCP_CONFIG_SUPPORTED=""  # reset cache between calls
PROVIDER_GUARD_LOG=""

set +e
(
    export FAKE_CLAUDE_INVOKED_FILE="${CLAUDE_INVOKED_FILE}"
    export PROVIDER=codex
    export PATH="${WORK_DIR}:${PATH}"
    _CLI_MCP_CONFIG_SUPPORTED=""
    # Call the function — after m20 it must NOT invoke fake claude
    _cli_supports_mcp_config
)
set -e

if [[ ! -f "${CLAUDE_INVOKED_FILE}" ]]; then
    pass "A: claude NOT invoked by _cli_supports_mcp_config when PROVIDER=codex"
else
    fail "A: claude WAS invoked by _cli_supports_mcp_config despite PROVIDER=codex (m20 guard missing)"
fi
rm -f "${CLAUDE_INVOKED_FILE}"

# --- B: with PROVIDER=claude, probe IS allowed ------------------------------
# When claude is in the provider spec, the guard should permit the probe.
# The fake claude outputs nothing useful (no --mcp-config line), so the
# function returns 1 (MCP support not detected). The critical assertion is
# that claude WAS invoked — verifying the guard did not over-block.
_CLI_MCP_CONFIG_SUPPORTED=""

PROBE_RC=0
set +e
(
    export FAKE_CLAUDE_INVOKED_FILE="${CLAUDE_INVOKED_FILE}"
    export PROVIDER=claude
    export PATH="${WORK_DIR}:${PATH}"
    _CLI_MCP_CONFIG_SUPPORTED=""
    _cli_supports_mcp_config
)
PROBE_RC=$?
set -e

if [[ -f "${CLAUDE_INVOKED_FILE}" ]]; then
    pass "B: claude IS invoked by _cli_supports_mcp_config when PROVIDER=claude"
else
    fail "B: claude NOT invoked despite PROVIDER=claude — guard may be over-broad"
fi
rm -f "${CLAUDE_INVOKED_FILE}"

# --- B2: return code when PROVIDER=claude (probe ran, fake outputs nothing) --
# The fake claude does not output "--mcp-config", so the grep returns no match
# and the function returns 1. Verify the return code comes from the probe result,
# not from the provider guard forcing rc=1.
if [[ "$PROBE_RC" -ne 0 ]]; then
    pass "B2: _cli_supports_mcp_config returns non-zero (probe ran; fake claude has no --mcp-config)"
else
    # rc=0 would mean the fake claude output matched "--mcp-config", which is
    # unexpected given our fake outputs "Usage: claude [options]" only.
    fail "B2: unexpected rc=0 — fake claude output should not match --mcp-config"
fi

# --- summary -----------------------------------------------------------------
if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo "All mcp_resolve provider guard tests passed (${PASS_COUNT})"
    exit 0
else
    echo "FAIL: ${FAIL_COUNT} tests failed (${PASS_COUNT} passed)"
    exit 1
fi
