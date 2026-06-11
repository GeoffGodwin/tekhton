#!/usr/bin/env bash
# Test: qwen-local end-to-end tool-loop smoke test (m18)
#
# Honesty gate: verifies that PROVIDER=qwen-local routes through codex to a
# local OpenAI-compatible endpoint AND that the model actually calls tools
# (not just emits text). The fixture task requires a file edit AND a shell
# command; a model that only produces text will fail both assertions.
#
# Skip conditions (any one causes SKIP → exit 0):
#   - No local server reachable at QWEN_LOCAL_BASE_URL
#   - codex not on PATH
#   - tekhton binary not built
#
# To run manually with Ollama:
#   ollama pull qwen2.5-coder:32b
#   bash tests/test_qwen_local_smoke.sh
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$(( FAIL_COUNT + 1 )); }

# --- skip guard: binary ---------------------------------------------------
if [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "SKIP: tekhton binary not built at ${TEKHTON_BIN} — run 'make build' first"
    exit 0
fi

# --- skip guard: codex on PATH -------------------------------------------
command -v codex >/dev/null 2>&1 || {
    echo "SKIP: codex not on PATH — qwen-local delegates to codex"
    exit 0
}

# --- skip guard: local server reachable ----------------------------------
base="${QWEN_LOCAL_BASE_URL:-http://localhost:11434/v1}"
base_root="${base%/v1}"
if ! curl -fsS --max-time 3 "${base_root}/" >/dev/null 2>&1 \
        && ! curl -fsS --max-time 3 "${base}/models" >/dev/null 2>&1; then
    echo "SKIP: no local server reachable at ${base} — set up Ollama and pull qwen2.5-coder:32b"
    exit 0
fi

# --- fixture setup -------------------------------------------------------
FIXTURE_DIR="${TEKHTON_HOME}/tests/fixtures/qwen_local_smoke"
WORK_DIR=""
WORK_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

# Copy fixture into the working directory (preserves hidden .claude/ dir).
cp -r "${FIXTURE_DIR}/." "${WORK_DIR}/"
# Ensure marker.txt starts empty and ran.txt does not exist.
: > "${WORK_DIR}/marker.txt"
rm -f "${WORK_DIR}/ran.txt"

# --- run tekhton with qwen-local -----------------------------------------
TASK="Append the line TOOL_LOOP_OK to marker.txt, then run: date +%s > ran.txt"

run_output=""
run_exit=0
run_output=$(
    PROVIDER=qwen-local \
    QWEN_LOCAL_BASE_URL="${QWEN_LOCAL_BASE_URL:-http://localhost:11434/v1}" \
    "${TEKHTON_BIN}" run \
        --project-dir "${WORK_DIR}" \
        --tekhton-home "${TEKHTON_HOME}" \
        --no-tui \
        --task "${TASK}" \
        2>&1
) || run_exit=$?

if [[ $run_exit -ne 0 ]]; then
    echo "--- tekhton run output (exit ${run_exit}) ---"
    echo "$run_output"
    echo "---"
fi

# --- assert side effects -------------------------------------------------
# AC 2a: marker.txt must contain TOOL_LOOP_OK.
if grep -qF "TOOL_LOOP_OK" "${WORK_DIR}/marker.txt"; then
    pass "marker.txt contains TOOL_LOOP_OK (file-edit tool loop fired)"
else
    fail "marker.txt does not contain TOOL_LOOP_OK — tool-edit loop did not fire"
    echo "    marker.txt contents: $(cat "${WORK_DIR}/marker.txt" 2>/dev/null || echo '(missing)')"
fi

# AC 2b: ran.txt must exist and be non-empty.
if [[ -s "${WORK_DIR}/ran.txt" ]]; then
    pass "ran.txt exists and is non-empty (shell-command tool loop fired)"
else
    if [[ -f "${WORK_DIR}/ran.txt" ]]; then
        fail "ran.txt exists but is empty — shell tool ran but wrote nothing"
    else
        fail "ran.txt does not exist — shell-command tool loop did not fire"
    fi
fi

# --- summary -------------------------------------------------------------
echo ""
if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo "All qwen-local smoke tests passed ($PASS_COUNT)"
    exit 0
else
    echo "FAIL: $FAIL_COUNT test(s) failed ($PASS_COUNT passed)"
    exit 1
fi
