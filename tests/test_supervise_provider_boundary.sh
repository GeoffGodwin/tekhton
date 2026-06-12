#!/usr/bin/env bash
# Shim-boundary test for m19: provider-aware supervise seam.
#
# Asserts that `tekhton supervise` honors PROVIDER env / envelope field
# instead of hardwiring the Claude supervisor, and that the structural
# m19 post-conditions hold (supervisor.New retired from supervise.go and
# run_stage.go, empty-chain guard present).
#
# Self-skips when the tekhton binary is not built.
#
# Live-binary tests (C/D) create temporary fake `codex` and `claude`
# scripts on PATH:
#   fake_codex: records invocation in WORK_DIR/codex_invoked.txt, emits
#               a minimal codex JSON event stream, exits 0.
#   fake_claude: records invocation in WORK_DIR/claude_invoked.txt, emits
#                a minimal claude JSON event stream, exits 0.
# With PROVIDER=codex and m19 implemented: codex is invoked, claude is not.
# With m19 absent (hardwired supervisor.New): claude is invoked, codex is not.
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

# --- skip guard -----------------------------------------------------------
if [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "SKIP: tekhton binary not built at ${TEKHTON_BIN} — run 'make build' first"
    exit 0
fi

# --- structural check A: supervisor.New retired from supervise.go ---------
# After m19, supervise.go must not contain supervisor.New — provider
# resolution replaces it. The only remaining supervisor.New calls allowed
# in non-test files are internal/runner/provider_select.go (claude factory)
# and cmd/tekhton/quota.go (quota probe — m21 scope).
SUPERVISE_SUPERVISOR_LINES=""
SUPERVISE_SUPERVISOR_LINES=$(grep -n "supervisor\.New" \
    "${TEKHTON_HOME}/cmd/tekhton/supervise.go" 2>/dev/null) || true

if [[ -z "$SUPERVISE_SUPERVISOR_LINES" ]]; then
    pass "A: supervise.go has no supervisor.New (provider resolution in place)"
else
    LINES=$(echo "$SUPERVISE_SUPERVISOR_LINES" | wc -l | tr -d ' ')
    fail "A: supervise.go still contains ${LINES} supervisor.New call(s) — m19 not implemented"
    echo "$SUPERVISE_SUPERVISOR_LINES"
fi

# --- structural check B: run_stage.go does not import internal/provider/claude
# After m19, run_stage.go must use runner.ResolveProvider per stage, not
# hardcode claude.New(supervisor.New(...)).
RUN_STAGE_CLAUDE=""
RUN_STAGE_CLAUDE=$(grep -n "internal/provider/claude\|claude\.New" \
    "${TEKHTON_HOME}/cmd/tekhton/run_stage.go" 2>/dev/null) || true

if [[ -z "$RUN_STAGE_CLAUDE" ]]; then
    pass "B: run_stage.go does not import or call internal/provider/claude directly"
else
    LINES=$(echo "$RUN_STAGE_CLAUDE" | wc -l | tr -d ' ')
    fail "B: run_stage.go still has ${LINES} hardcoded claude reference(s) — m19 not implemented"
    echo "$RUN_STAGE_CLAUDE"
fi

# --- structural check B2: supervisor.New count across non-test files ------
# After m19, only two files may contain supervisor.New outside _test files:
# internal/runner/provider_select.go and cmd/tekhton/quota.go.
SUPERVISOR_NEW_FILES=""
SUPERVISOR_NEW_FILES=$(grep -rln "supervisor\.New" \
    "${TEKHTON_HOME}/internal/" "${TEKHTON_HOME}/cmd/" \
    --include="*.go" 2>/dev/null \
    | grep -v "_test\.go" \
    | sort) || true

EXPECTED_FILES=$(printf '%s\n' \
    "${TEKHTON_HOME}/cmd/tekhton/quota.go" \
    "${TEKHTON_HOME}/internal/runner/provider_select.go" \
    | sort)

if [[ "$SUPERVISOR_NEW_FILES" == "$EXPECTED_FILES" ]]; then
    pass "B2: supervisor.New present only in provider_select.go and quota.go (non-test files)"
else
    fail "B2: unexpected supervisor.New locations — expected only provider_select.go + quota.go"
    echo "  Expected:"
    echo "$EXPECTED_FILES" | sed 's|'"${TEKHTON_HOME}/"'||g' | sed 's/^/    /'
    echo "  Got:"
    echo "$SUPERVISOR_NEW_FILES" | sed 's|'"${TEKHTON_HOME}/"'||g' | sed 's/^/    /'
fi

# --- live binary setup ---------------------------------------------------
if ! command -v bash >/dev/null 2>&1; then
    echo "SKIP: C/D (bash not on PATH — cannot create fake binary scripts)"
    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        echo "All supervise provider boundary tests passed (${PASS_COUNT})"
        exit 0
    else
        echo "FAIL: ${FAIL_COUNT} tests failed (${PASS_COUNT} passed)"
        exit 1
    fi
fi

WORK_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

CODEX_INVOKED_FILE="${WORK_DIR}/codex_invoked.txt"
CLAUDE_INVOKED_FILE="${WORK_DIR}/claude_invoked.txt"

# Fake codex: records invocation + emits minimal task_complete stream.
# The codex provider decodes JSONL where each line is {"id":"N","msg":{...}}.
# A task_complete event is sufficient for OutcomeSuccess (NullRun=true path
# needs no events; exitCode 0 → OutcomeSuccess per outcome.go:63).
cat > "${WORK_DIR}/codex" << 'CODEX_EOF'
#!/usr/bin/env bash
touch "${FAKE_CODEX_INVOKED_FILE}"
printf '{"id":"1","msg":{"type":"task_started"}}\n'
printf '{"id":"2","msg":{"type":"task_complete"}}\n'
exit 0
CODEX_EOF
chmod +x "${WORK_DIR}/codex"

# Fake claude: records invocation + emits a minimal supervisor event stream.
# The V4 supervisor reads claude CLI JSONL; turn_started/turn_ended is enough.
cat > "${WORK_DIR}/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
touch "${FAKE_CLAUDE_INVOKED_FILE}"
printf '{"type":"turn_started","turn":1}\n'
printf '{"type":"turn_ended","turn":1}\n'
exit 0
CLAUDE_EOF
chmod +x "${WORK_DIR}/claude"

# Minimal prompt file required by agent.request.v1.
printf 'Test task for m19 boundary test.\n' > "${WORK_DIR}/prompt.txt"

_run_supervise() {
    local req_file="$1"
    local out_file="${WORK_DIR}/response_$$.json"
    rm -f "${CODEX_INVOKED_FILE}" "${CLAUDE_INVOKED_FILE}"

    FAKE_CODEX_INVOKED_FILE="${CODEX_INVOKED_FILE}" \
    FAKE_CLAUDE_INVOKED_FILE="${CLAUDE_INVOKED_FILE}" \
    PROVIDER=codex \
    CODEX_API_KEY="fake-key-for-test" \
    TEKHTON_AGENT_BINARY="" \
    PATH="${WORK_DIR}:${PATH}" \
    "${TEKHTON_BIN}" supervise --request-file "${req_file}" \
        > "${out_file}" 2>/dev/null || true

    printf '%s' "${out_file}"
}

# Build a minimal agent.request.v1 JSON for a plain label (no spaces).
cat > "${WORK_DIR}/request_plain.json" << REQ_EOF
{
  "proto": "tekhton.agent.request.v1",
  "run_id": "test-m19-boundary",
  "label": "Coder",
  "model": "claude-sonnet-4-6",
  "max_turns": 2,
  "prompt_file": "${WORK_DIR}/prompt.txt",
  "working_dir": "${WORK_DIR}",
  "timeout_secs": 30,
  "activity_timeout_secs": 10
}
REQ_EOF

# --- live test C: PROVIDER=codex routes to fake codex, not claude ---------
RESPONSE_FILE=$(_run_supervise "${WORK_DIR}/request_plain.json")

if [[ -f "${CODEX_INVOKED_FILE}" ]]; then
    pass "C: fake codex binary invoked when PROVIDER=codex (PROVIDER env honored)"
else
    fail "C: fake codex binary NOT invoked — PROVIDER=codex ignored (supervisor.New hardcode active)"
fi

if [[ ! -f "${CLAUDE_INVOKED_FILE}" ]]; then
    pass "C2: claude not invoked when PROVIDER=codex"
else
    fail "C2: claude was invoked despite PROVIDER=codex — hardcoded supervisor still active"
fi

# --- live test D: space-and-parens label falls back to global PROVIDER ----
# sanitizeLabel("Test Fix (attempt 2)") → "TEST_FIX__ATTEMPT_2_"
# PROVIDER_TEST_FIX__ATTEMPT_2_ is unset → falls back to PROVIDER=codex
cat > "${WORK_DIR}/request_complex_label.json" << DLABEL_EOF
{
  "proto": "tekhton.agent.request.v1",
  "run_id": "test-m19-label",
  "label": "Test Fix (attempt 2)",
  "model": "claude-sonnet-4-6",
  "max_turns": 2,
  "prompt_file": "${WORK_DIR}/prompt.txt",
  "working_dir": "${WORK_DIR}",
  "timeout_secs": 30,
  "activity_timeout_secs": 10
}
DLABEL_EOF

_run_supervise "${WORK_DIR}/request_complex_label.json" > /dev/null

if [[ -f "${CODEX_INVOKED_FILE}" ]]; then
    pass "D: label 'Test Fix (attempt 2)' sanitized and routed to codex via global PROVIDER"
else
    fail "D: label 'Test Fix (attempt 2)' did not route to codex — sanitization or fallback broken"
fi

# --- live test E: response envelope is valid JSON with proto field ---------
# Re-run plain request to get a fresh response.
RESPONSE_FILE=$(_run_supervise "${WORK_DIR}/request_plain.json")

if [[ -f "${RESPONSE_FILE}" ]]; then
    # Check proto field exists (python3 or grep fallback)
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "
import json,sys
d=json.load(open('${RESPONSE_FILE}'))
assert d.get('proto','').startswith('tekhton.agent.response')
" 2>/dev/null; then
            pass "E: agent.response.v1 envelope is valid JSON with proto field"
        else
            fail "E: agent.response.v1 envelope missing proto field or not valid JSON"
        fi
    else
        # Fallback: grep for the proto value
        if grep -q '"tekhton.agent.response' "${RESPONSE_FILE}" 2>/dev/null; then
            pass "E: agent.response.v1 envelope contains proto field (grep)"
        else
            fail "E: agent.response.v1 envelope missing proto field"
        fi
    fi
else
    fail "E: supervise produced no output file"
fi

# --- summary -------------------------------------------------------------
if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo "All supervise provider boundary tests passed (${PASS_COUNT})"
    exit 0
else
    echo "FAIL: ${FAIL_COUNT} tests failed (${PASS_COUNT} passed)"
    exit 1
fi
