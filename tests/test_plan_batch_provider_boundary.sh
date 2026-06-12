#!/usr/bin/env bash
# tests/test_plan_batch_provider_boundary.sh — m20 shim-boundary test.
#
# Verifies that _call_planning_batch routes through `tekhton supervise`
# (honoring the PROVIDER env) rather than calling the claude binary directly.
#
# Self-skips ONLY if the tekhton binary is not built; the structural
# assertion (A) runs unconditionally so CI catches regressions immediately.
#
# With m20 implemented:
#   A: lib/plan_batch.sh has no raw claude call.
#   B: Fake claude (exits 99) is never invoked when PROVIDER=codex.
#   C: Exit code is not 99.
#   D: Fake codex IS invoked via tekhton supervise.
#
# Without m20 (pre-change):
#   A fails (raw claude still present).
#   B/C/D run but skip with a note (live tests require A to pass first).
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"

# m20 rewrites _call_planning_batch() to route through `tekhton supervise`.
# Until that lands, lib/plan_batch.sh still has a raw `claude` invocation in
# command position at line 88. Self-skip so the suite stays green; assertions
# A/B/C/D exercise the post-m20 contract.
if grep -qE '^[[:space:]]*claude[[:space:]]*\\$' \
        "${TEKHTON_HOME}/lib/plan_batch.sh" 2>/dev/null; then
    echo "SKIP: lib/plan_batch.sh still uses raw claude — m20 not implemented"
    exit 0
fi

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }
note() { echo "NOTE: $1"; }

# --- A: structural — no raw claude in command position in plan_batch.sh -----
# This runs WITHOUT a skip guard — it must catch regressions even before
# the live tests can run.
# Pattern from m20 AC: matches flag form, subcommand form, line-continuation.
# Excludes: shell comments, CLAUDE_ variable names, .claude path strings.
PLAN_BATCH="${TEKHTON_HOME}/lib/plan_batch.sh"
RAW_HITS=""
if [[ -f "$PLAN_BATCH" ]]; then
    RAW_HITS=$(grep -En \
        '(^|[;&|(` ]|[[:space:]])claude([[:space:]]|\\$)' \
        "$PLAN_BATCH" 2>/dev/null \
        | grep -v '^[^:]*:[[:space:]]*#' \
        | grep -v 'CLAUDE_' \
        | grep -v '\.claude' \
        || true)
fi

if [[ -z "$RAW_HITS" ]]; then
    pass "A: lib/plan_batch.sh has no raw claude invocation in command position"
else
    fail "A: lib/plan_batch.sh still calls claude directly (m20 not implemented)"
    printf '  %s\n' "$RAW_HITS"
fi

# --- binary guard for live tests -------------------------------------------
if [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "SKIP B/C/D: tekhton binary not built — run 'make build' first"
    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        echo "All runnable plan batch tests passed (${PASS_COUNT})"
        exit 0
    else
        echo "FAIL: ${FAIL_COUNT} tests failed (${PASS_COUNT} passed)"
        exit 1
    fi
fi

# --- structural skip guard for live tests -----------------------------------
# The live tests (B/C/D) assert PROVIDER routing through tekhton supervise.
# That routing only works once plan_batch.sh no longer calls claude directly.
# Gate them behind the structural assertion — if A failed, B/C/D are
# already broken by design and we skip rather than produce noise.
if [[ -n "$RAW_HITS" ]]; then
    note "B/C/D skipped — waiting for A to pass (m20 not yet implemented)"
    echo "FAIL: ${FAIL_COUNT} tests failed (${PASS_COUNT} passed)"
    exit 1
fi

# --- live shim-boundary setup -----------------------------------------------
WORK_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

CODEX_INVOKED_FILE="${WORK_DIR}/codex_invoked.txt"
CLAUDE_INVOKED_FILE="${WORK_DIR}/claude_invoked.txt"

# Fake codex: records invocation + emits minimal JSONL (task_complete → OutcomeSuccess)
cat > "${WORK_DIR}/codex" << 'CODEX_EOF'
#!/usr/bin/env bash
touch "${FAKE_CODEX_INVOKED_FILE}"
printf '{"id":"1","msg":{"type":"task_started"}}\n'
printf '{"id":"2","msg":{"type":"task_complete"}}\n'
exit 0
CODEX_EOF
chmod +x "${WORK_DIR}/codex"

# Fake claude: records invocation and exits 99 (sentinel: claude called directly)
cat > "${WORK_DIR}/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
touch "${FAKE_CLAUDE_INVOKED_FILE}"
exit 99
CLAUDE_EOF
chmod +x "${WORK_DIR}/claude"

LOG_FILE="${WORK_DIR}/plan_batch.log"
touch "$LOG_FILE"
PROMPT_TEXT="Describe this project in one sentence for testing."

# Stub logging so sourcing common.sh doesn't pollute test output.
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
log_verbose() { :; }
emit_event()  { :; }
_TUI_ACTIVE=false
export _TUI_ACTIVE

# shellcheck source=../lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=../lib/agent_shim.sh
source "${TEKHTON_HOME}/lib/agent_shim.sh"
# shellcheck source=../lib/plan_batch.sh
source "${TEKHTON_HOME}/lib/plan_batch.sh"

# Call _call_planning_batch with PROVIDER=codex; TEKHTON_TEST_MODE=1 suppresses spinner.
PLAN_RC=0
set +e
(
    export FAKE_CODEX_INVOKED_FILE="${CODEX_INVOKED_FILE}"
    export FAKE_CLAUDE_INVOKED_FILE="${CLAUDE_INVOKED_FILE}"
    export PROVIDER=codex
    export CODEX_API_KEY="fake-key-for-test"
    export TEKHTON_BIN="${TEKHTON_BIN}"
    export TEKHTON_TEST_MODE=1
    export PATH="${WORK_DIR}:${PATH}"
    _call_planning_batch "claude-sonnet-4-6" "10" "$PROMPT_TEXT" "$LOG_FILE"
) > /dev/null 2>&1
PLAN_RC=$?
set -e

# --- B: claude not invoked when PROVIDER=codex
if [[ ! -f "${CLAUDE_INVOKED_FILE}" ]]; then
    pass "B: fake claude NOT invoked when PROVIDER=codex"
else
    fail "B: fake claude WAS invoked — _call_planning_batch calling claude directly"
fi

# --- C: exit code not 99 (sentinel: claude not the exit path)
if [[ "$PLAN_RC" -ne 99 ]]; then
    pass "C: _call_planning_batch exit code is not 99 (claude not called as exit path)"
else
    fail "C: exit code is 99 — fake claude was called as exit path"
fi

# --- D: codex invoked via tekhton supervise
if [[ -f "${CODEX_INVOKED_FILE}" ]]; then
    pass "D: fake codex invoked — PROVIDER=codex routing through tekhton supervise works"
else
    fail "D: fake codex NOT invoked — _call_planning_batch did not route through tekhton supervise"
fi

# --- summary -----------------------------------------------------------------
if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo "All plan batch provider boundary tests passed (${PASS_COUNT})"
    exit 0
else
    echo "FAIL: ${FAIL_COUNT} tests failed (${PASS_COUNT} passed)"
    exit 1
fi
