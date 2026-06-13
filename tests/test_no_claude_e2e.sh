#!/usr/bin/env bash
# tests/test_no_claude_e2e.sh — m23 zero-claude end-to-end cutover verification.
#
# Runs a full Tekhton pipeline milestone under PROVIDER=codex using fake shims,
# then asserts that the claude binary was never invoked as an AI agent.
#
# TEKHTON_E2E=1 guard: skip unless the caller opts in (slow, requires built binary).
# Self-skips when:
#   - TEKHTON_E2E != "1"
#   - tekhton binary not built
#   - codex not on PATH (the fake will shadow it, but we verify the real one exists
#     so operators know what's being shimmed)
#
# Acceptance assertions (m23 Goal 1):
#   A — pipeline exits 0
#   B — MANIFEST.cfg milestone entry is "done"
#   C — hello.txt exists in the fixture working dir
#   D — claude_invocations.log is absent or empty (zero AI-agent invocations)
#   E — sabotage check: forcing PROVIDER=claude for the coder stage causes
#       claude_invocations.log to be non-empty, proving the shim detects invocations
#
# TIMEOUT_SECS=120
set -uo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"
FIXTURE_DIR="${TEKHTON_HOME}/tests/fixtures/cutover_project"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

# --- E2E guard ---------------------------------------------------------------
if [[ "${TEKHTON_E2E:-0}" != "1" ]]; then
    echo "SKIP: set TEKHTON_E2E=1 to run this test (slow — requires built binary)"
    exit 0
fi

# --- prerequisite guards -----------------------------------------------------
if [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "SKIP: tekhton binary not built at ${TEKHTON_BIN} — run 'make build' first"
    exit 0
fi

if ! command -v codex >/dev/null 2>&1; then
    echo "SKIP: codex not on PATH — the e2e harness needs codex as the base binary to shim"
    exit 0
fi

# --- workspace setup ---------------------------------------------------------
WORK_DIR=$(mktemp -d)
FAKE_HOME=$(mktemp -d)
FAKE_BIN=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}' '${FAKE_HOME}' '${FAKE_BIN}'" EXIT

# Copy fixture into working directory.
cp -r "${FIXTURE_DIR}/." "${WORK_DIR}/"

# Initialise a git repo in the working copy so finalize commit hooks don't error.
(
    cd "${WORK_DIR}" || exit
    git init -q
    git config user.email "e2e-test@tekhton.local"
    git config user.name  "Tekhton E2E Test"
    git add -A
    git commit -q -m "initial: cutover e2e fixture"
) 2>/dev/null

# Create fake ~/.codex/auth.json so codex.Tier() resolves to "subscription"
# without hitting the real auth state of the host machine.
mkdir -p "${FAKE_HOME}/.codex"
printf '{"token":"fake-e2e-subscription-token"}\n' > "${FAKE_HOME}/.codex/auth.json"

# Log file for recording claude invocations (any call other than --version).
CLAUDE_LOG="${WORK_DIR}/claude_invocations.log"

# --- fake claude shim --------------------------------------------------------
# Handles --version cleanly (so preflight claude_env check passes), but records
# any other invocation (real AI-agent calls) to CLAUDE_LOG and exits 99.
cat > "${FAKE_BIN}/claude" << CLAUDE_SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
    echo "2.1.180 (Claude Code)"
    exit 0
fi
echo "claude \$*" >> "${CLAUDE_LOG}"
exit 99
CLAUDE_SHIM
chmod +x "${FAKE_BIN}/claude"

# --- fake codex shim ---------------------------------------------------------
# TARGET is embedded at test-script creation time so the shim always writes
# to WORK_DIR regardless of the --cd arg the codex provider supplies.
#
# NOTE: the codex provider currently passes os.Getwd() (TEKHTON_HOME) as --cd
# rather than req.WorkingDir (BUG-001). Parsing --cd would write files to the
# wrong directory. Embedding the path avoids that dependency while still
# exercising the full provider dispatch path.
#
# Unquoted CODEX_SHIM delimiter: ${WORK_DIR} expands now; \$(...) refs
# expand at shim execution time.
cat > "${FAKE_BIN}/codex" << CODEX_SHIM
#!/usr/bin/env bash
# Project dir is hardcoded at test-script creation time.
TARGET="${WORK_DIR}"

# Coder deliverable: create hello.txt in the fixture project.
printf 'hello\n' > "\${TARGET}/hello.txt"

# Pre-write APPROVED reviewer report so the review stage finds a ready verdict
# without the AI writing a new one. Guard prevents double-write on repeat calls.
mkdir -p "\${TARGET}/.tekhton"
if [[ ! -f "\${TARGET}/.tekhton/REVIEWER_REPORT.md" ]]; then
    printf '%s\n' \
        "## Verdict" "APPROVED" "" \
        "## Complex Blockers" "- None" "" \
        "## Simple Blockers" "- None" "" \
        "## Non-Blocking Notes" "- None" "" \
        "## Coverage Gaps" "- None" "" \
        "## Drift Observations" "- None" \
        > "\${TARGET}/.tekhton/REVIEWER_REPORT.md"
fi

# Emit minimal JSONL event stream — sufficient for OutcomeSuccess.
printf '{"id":"1","msg":{"type":"task_started"}}\n'
printf '{"id":"2","msg":{"type":"task_complete"}}\n'
exit 0
CODEX_SHIM
chmod +x "${FAKE_BIN}/codex"

# Helper: run the happy-path pipeline and capture exit code.
# For the sabotage check (which sets extra env vars) we call the binary directly.
_run_pipeline() {
    local _rc=0

    # Scrub any inherited provider overrides to prevent host-machine env
    # from leaking into the fixture run.
    unset PROVIDER PROVIDER_CODER PROVIDER_REVIEW PROVIDER_TESTER \
          PROVIDER_INTAKE PROVIDER_SECURITY PROVIDER_DOCS \
          TEKHTON_AGENT_BINARY CODEX_API_KEY 2>/dev/null || true

    HOME="${FAKE_HOME}" \
    PROVIDER=codex \
    PATH="${FAKE_BIN}:${PATH}" \
    "${TEKHTON_BIN}" run \
        --milestone m01 \
        --project-dir "${WORK_DIR}" \
        --tekhton-home "${TEKHTON_HOME}" \
        --no-tui \
        2>&1 || _rc=$?
    return $_rc
}

# =============================================================================
# Happy-path run (PROVIDER=codex everywhere)
# =============================================================================
echo "--- Running happy-path pipeline (PROVIDER=codex) ---"
HAPPY_RC=0
_run_pipeline > "${WORK_DIR}/pipeline_happy.log" 2>&1 || HAPPY_RC=$?

# A: pipeline exits 0
if [[ "$HAPPY_RC" -eq 0 ]]; then
    pass "A: pipeline exited 0 under PROVIDER=codex"
else
    fail "A: pipeline exited ${HAPPY_RC} — see ${WORK_DIR}/pipeline_happy.log"
    echo "    --- pipeline output tail ---"
    tail -20 "${WORK_DIR}/pipeline_happy.log" | sed 's/^/    /'
fi

# B: MANIFEST.cfg milestone entry is "done"
MANIFEST="${WORK_DIR}/.claude/milestones/MANIFEST.cfg"
if grep -qE '^m01\|[^|]*\|done\|' "${MANIFEST}" 2>/dev/null; then
    pass "B: MANIFEST.cfg m01 entry is 'done'"
else
    fail "B: MANIFEST.cfg m01 not marked done"
    echo "    MANIFEST content:"
    grep "^m01" "${MANIFEST}" 2>/dev/null | sed 's/^/    /' || echo "    (m01 not found)"
fi

# C: hello.txt exists
if [[ -f "${WORK_DIR}/hello.txt" ]]; then
    pass "C: hello.txt created in fixture project"
else
    fail "C: hello.txt missing — coder deliverable not produced"
fi

# D: claude_invocations.log absent or empty
if [[ ! -f "${CLAUDE_LOG}" ]] || [[ ! -s "${CLAUDE_LOG}" ]]; then
    pass "D: claude was not invoked as an AI agent (claude_invocations.log absent/empty)"
else
    fail "D: claude was invoked — zero-claude contract violated"
    echo "    Invocations recorded:"
    sed 's/^/    /' "${CLAUDE_LOG}"
fi

# =============================================================================
# Sabotage check (PROVIDER_coder=claude forces claude for the coder stage)
# =============================================================================
# Note on sabotage vector choice: PROVIDER_REVIEW=claude is used rather than
# PROVIDER_CODER=claude. The coder stage's Go implementation has deps.RunAgent
# nil in production (BUG-002); cfg.Provider is set from stageProvider but never
# wired to deps.RunAgent, making per-stage provider overrides ineffective for
# the coder stage. The review stage (stages/review/cycle.go:174) calls
# cfg.Provider.RunAgent directly, so PROVIDER_REVIEW is the correct sabotage
# lever for exercising the dispatch path. Note: stage "review" maps to env var
# PROVIDER_REVIEW (not PROVIDER_REVIEWER) — ResolveProvider uses
# strings.ToUpper(stageName) where stageName = "review".
echo ""
echo "--- Running sabotage check (PROVIDER_REVIEW=claude) ---"

# Reset the log so only sabotage-run invocations are captured.
rm -f "${CLAUDE_LOG}"

# Reset milestone status so the pipeline re-runs m01.
if [[ -f "$MANIFEST" ]]; then
    sed -i 's/^m01|\([^|]*\)|done|/m01|\1|todo|/' "${MANIFEST}" 2>/dev/null || true
fi

# Remove the pre-written REVIEWER_REPORT.md so the review stage always calls
# the agent (rather than seeing a stale APPROVED from the happy-path run).
rm -f "${WORK_DIR}/.tekhton/REVIEWER_REPORT.md"

HOME="${FAKE_HOME}" \
PROVIDER=codex \
PROVIDER_REVIEW=claude \
PATH="${FAKE_BIN}:${PATH}" \
"${TEKHTON_BIN}" run \
    --milestone m01 \
    --project-dir "${WORK_DIR}" \
    --tekhton-home "${TEKHTON_HOME}" \
    --no-tui \
    > "${WORK_DIR}/pipeline_sabotage.log" 2>&1 || true

# E: sabotage check — claude_invocations.log must be non-empty (shim detected it)
if [[ -f "${CLAUDE_LOG}" ]] && [[ -s "${CLAUDE_LOG}" ]]; then
    pass "E: sabotage detected — PROVIDER_REVIEW=claude caused claude invocation to be recorded"
    echo "    Recorded invocation(s):"
    head -5 "${CLAUDE_LOG}" | sed 's/^/    /'
else
    fail "E: sabotage NOT detected — claude_invocations.log absent/empty despite PROVIDER_REVIEW=claude"
    echo "    See ${WORK_DIR}/pipeline_sabotage.log for the pipeline run output."
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo "All zero-claude e2e tests passed (${PASS_COUNT})"
    exit 0
else
    echo "FAIL: ${FAIL_COUNT} tests failed (${PASS_COUNT} passed)"
    exit 1
fi
