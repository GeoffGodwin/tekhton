#!/usr/bin/env bash
# =============================================================================
# test_completion_gate_retry.sh — m45 shim-boundary integration test
#
# Drives `tekhton gate completion` against a flake-then-pass TEST_CMD and
# asserts:
#
#   1. The gate does NOT halt — exit code 0 means the m45 retry kicked in
#      and the second invocation passed.
#   2. The causal log contains a "completion_gate_flake" event with the
#      documented fields (first_exit, retry_exit, test_cmd, milestone).
#
# Plus a negative scenario: both invocations fail → gate halts with
# non-zero exit and no flake event written.
#
# Self-skips when the `tekhton` binary is not on PATH (e.g. on a fresh
# clone before `make build`). The grace and retry-delay windows are
# zeroed so the test runs in ~1s rather than waiting out 3+5 seconds.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${REPO_ROOT}/bin/tekhton"

if ! command -v go >/dev/null 2>&1; then
    printf 'SKIP test_completion_gate_retry: go toolchain not found\n'
    exit 0
fi
if [[ ! -x "$TEKHTON_BIN" ]]; then
    if ! (cd "$REPO_ROOT" && make build >/dev/null 2>&1); then
        printf 'SKIP test_completion_gate_retry: make build failed\n'
        exit 0
    fi
fi

FAIL=0
_pass() { printf 'PASS: %s\n' "$*"; }
_fail() { printf 'FAIL: %s\n' "$*"; FAIL=1; }

# _make_flake_script DIR
#   Writes a TEST_CMD script that exits 1 on first call (creates sentinel)
#   and exits 0 on every subsequent call. PATH is set to expose the script
#   as `flake_test_cmd`.
_make_flake_script() {
    local dir="$1"
    cat > "${dir}/flake_test_cmd" <<'EOF'
#!/usr/bin/env bash
sentinel="${TEKHTON_TEST_SENTINEL:?sentinel path}"
if [[ ! -f "$sentinel" ]]; then
    : > "$sentinel"
    echo "first attempt: simulated transient failure"
    exit 1
fi
echo "subsequent attempt: pass"
exit 0
EOF
    chmod +x "${dir}/flake_test_cmd"
}

# --- Scenario 1: flake-then-pass → gate proceeds, causal event fires --------
_scenario_flake_then_pass() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    mkdir -p "${tmp}/.tekhton" "${tmp}/.claude/logs" "${tmp}/bin"
    printf '## Status: COMPLETE\n' > "${tmp}/.tekhton/CODER_SUMMARY.md"
    _make_flake_script "${tmp}/bin"

    local sentinel="${tmp}/flake.sentinel"
    local causal_log="${tmp}/.claude/logs/CAUSAL_LOG.jsonl"

    local exit_code=0
    env -i \
        PATH="${tmp}/bin:$PATH" \
        HOME="$HOME" \
        TMPDIR="$tmp" \
        TEKHTON_DIR=".tekhton" \
        PROJECT_DIR="$tmp" \
        CODER_SUMMARY_FILE=".tekhton/CODER_SUMMARY.md" \
        TEST_CMD="flake_test_cmd" \
        COMPLETION_GATE_TEST_ENABLED=true \
        COMPLETION_GATE_GRACE_SECS=0 \
        COMPLETION_GATE_RETRY_NO_BASELINE=true \
        COMPLETION_GATE_RETRY_DELAY_SECS=0 \
        CAUSAL_LOG_ENABLED=true \
        CAUSAL_LOG_FILE=".claude/logs/CAUSAL_LOG.jsonl" \
        CAUSAL_LOG_MAX_EVENTS=2000 \
        _CURRENT_MILESTONE="m45" \
        TEKHTON_TEST_SENTINEL="$sentinel" \
        "$TEKHTON_BIN" gate completion \
        >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        _pass "flake-then-pass: gate exited 0 (did not halt)"
    else
        _fail "flake-then-pass: gate exited ${exit_code}, want 0"
    fi

    if [[ ! -f "$sentinel" ]]; then
        _fail "flake-then-pass: TEST_CMD sentinel missing — first invocation never ran"
    fi

    if [[ ! -f "$causal_log" ]]; then
        _fail "flake-then-pass: causal log missing at ${causal_log}"
        return
    fi

    if grep -q '"type":"completion_gate_flake"' "$causal_log"; then
        _pass "flake-then-pass: causal log contains completion_gate_flake event"
    else
        _fail "flake-then-pass: completion_gate_flake event missing"
        printf '--- causal log ---\n'
        cat "$causal_log"
        printf '--- end ---\n'
        return
    fi

    local detail_line
    detail_line=$(grep '"type":"completion_gate_flake"' "$causal_log" | head -1)
    for needle in 'first_exit=1' 'retry_exit=0' 'test_cmd=flake_test_cmd' 'milestone=m45'; do
        if printf '%s' "$detail_line" | grep -q -- "$needle"; then
            _pass "flake-then-pass: causal detail contains ${needle}"
        else
            _fail "flake-then-pass: causal detail missing ${needle} — line was: ${detail_line}"
        fi
    done

    if printf '%s' "$detail_line" | grep -q '"stage":"completion_gate"'; then
        _pass "flake-then-pass: causal stage = completion_gate"
    else
        _fail "flake-then-pass: causal stage missing — line was: ${detail_line}"
    fi
}

# --- Scenario 2: both attempts fail → gate halts, no flake event ------------
_scenario_both_fail() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    mkdir -p "${tmp}/.tekhton" "${tmp}/.claude/logs"
    printf '## Status: COMPLETE\n' > "${tmp}/.tekhton/CODER_SUMMARY.md"

    local causal_log="${tmp}/.claude/logs/CAUSAL_LOG.jsonl"

    local exit_code=0
    env -i \
        PATH="$PATH" \
        HOME="$HOME" \
        TMPDIR="$tmp" \
        TEKHTON_DIR=".tekhton" \
        PROJECT_DIR="$tmp" \
        CODER_SUMMARY_FILE=".tekhton/CODER_SUMMARY.md" \
        TEST_CMD="false" \
        COMPLETION_GATE_TEST_ENABLED=true \
        COMPLETION_GATE_GRACE_SECS=0 \
        COMPLETION_GATE_RETRY_NO_BASELINE=true \
        COMPLETION_GATE_RETRY_DELAY_SECS=0 \
        CAUSAL_LOG_ENABLED=true \
        CAUSAL_LOG_FILE=".claude/logs/CAUSAL_LOG.jsonl" \
        _CURRENT_MILESTONE="m45" \
        "$TEKHTON_BIN" gate completion \
        >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        _pass "both-fail: gate exited ${exit_code} (halted as expected)"
    else
        _fail "both-fail: gate exited 0, want non-zero"
    fi

    if [[ -f "$causal_log" ]] && grep -q '"type":"completion_gate_flake"' "$causal_log"; then
        _fail "both-fail: completion_gate_flake event should not exist when both attempts fail"
    else
        _pass "both-fail: no completion_gate_flake event written"
    fi
}

_scenario_flake_then_pass
_scenario_both_fail

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
printf 'All test_completion_gate_retry scenarios passed.\n'
