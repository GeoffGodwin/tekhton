#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_m138_coverage_gaps.sh — Coverage-gap tests for M138 (m16-adapted)
#
# Pre-m16 GAP-1 exercised the bash _apply_ci_ui_gate_defaults stderr
# diagnostic that fires when VERBOSE_OUTPUT=true and CI auto-elevation kicks
# in. m16 ports that diagnostic to internal/config/ci.go::applyCIGateDefault;
# this test now drives the Go binary and asserts the same stderr behavior.
#
# GAP-2 (log_verbose annotation in _normalize_ui_gate_env) is unrelated to
# the m16 wedge — gates_ui_helpers.sh is still bash — and is preserved
# verbatim from the pre-m16 test.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
BIN="${TEKHTON_HOME}/bin/tekhton"

if [[ ! -x "$BIN" ]]; then
    echo "SKIP: tekhton binary not built (run 'make build')"
    exit 0
fi

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        pass "$desc"
    else
        fail "$desc — '$needle' not found in output"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if ! printf '%s' "$haystack" | grep -qF "$needle"; then
        pass "$desc"
    else
        fail "$desc — '$needle' present but should be absent"
    fi
}

# Minimal valid pipeline.conf reused by every GAP-1 case.
cat > "${TMPDIR_BASE}/min.conf" <<'EOF'
PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo ok"
EOF

cat > "${TMPDIR_BASE}/explicit.conf" <<'EOF'
PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo ok"
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0
EOF

# Capture stderr from `tekhton config load` with controlled CI + VERBOSE env.
# Args after CONF are exported only for this single invocation.
_capture_stderr() {
    local conf="$1"; shift
    env -i PATH="$PATH" HOME="$HOME" "$@" \
        "$BIN" config load --path "$conf" --project-dir "$TMPDIR_BASE" \
        --emit shell 2>&1 >/dev/null
}

# =============================================================================
# GAP-1: VERBOSE_OUTPUT=true stderr diagnostic in applyCIGateDefault
#
# Source: internal/config/ci.go::applyCIGateDefault — emits one
#   `[tekhton] CI environment detected (<platform>) — TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 (auto)`
# line on stderr when VERBOSE_OUTPUT=true and auto-elevation fires.
# =============================================================================
echo "=== GAP-1: VERBOSE_OUTPUT=true stderr diagnostic in CI gate defaulter ==="

# GAP-1.1: CI detected + key absent + VERBOSE_OUTPUT=true → diagnostic fires.
echo "  GAP-1.1: GITHUB_ACTIONS=true + VERBOSE_OUTPUT=true + key absent → [tekhton] diagnostic"
out=$(_capture_stderr "${TMPDIR_BASE}/min.conf" GITHUB_ACTIONS=true VERBOSE_OUTPUT=true || true)
assert_contains "GAP-1.1 stderr contains [tekhton] prefix"          "[tekhton]" "$out"
assert_contains "GAP-1.1 stderr contains 'CI environment detected'" "CI environment detected" "$out"
assert_contains "GAP-1.1 stderr contains 'GitHub Actions'"          "GitHub Actions" "$out"
assert_contains "GAP-1.1 stderr contains 'TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 (auto)'" \
    "TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 (auto)" "$out"

# GAP-1.2: VERBOSE_OUTPUT=false → silent even when auto-elevation fires.
echo "  GAP-1.2: GITHUB_ACTIONS=true + VERBOSE_OUTPUT=false → silent"
out=$(_capture_stderr "${TMPDIR_BASE}/min.conf" GITHUB_ACTIONS=true || true)
assert_not_contains "GAP-1.2 no [tekhton] when VERBOSE_OUTPUT=false" "[tekhton]" "$out"

# GAP-1.3: VERBOSE_OUTPUT=true + no CI → diagnostic does not fire.
echo "  GAP-1.3: No CI + VERBOSE_OUTPUT=true → silent"
out=$(_capture_stderr "${TMPDIR_BASE}/min.conf" VERBOSE_OUTPUT=true || true)
assert_not_contains "GAP-1.3 no [tekhton] when not in CI" "[tekhton]" "$out"

# GAP-1.4: CI detected + VERBOSE_OUTPUT=true + explicit user override
#   → auto-elevation suppressed → diagnostic does not fire.
echo "  GAP-1.4: explicit override + CI + VERBOSE_OUTPUT=true → silent"
out=$(_capture_stderr "${TMPDIR_BASE}/explicit.conf" GITHUB_ACTIONS=true VERBOSE_OUTPUT=true || true)
assert_not_contains "GAP-1.4 no [tekhton] when key was explicitly set" "[tekhton]" "$out"

# GAP-1.5: Verify platform name changes with CI platform.
echo "  GAP-1.5: CIRCLECI=true + VERBOSE_OUTPUT=true → 'CircleCI' in stderr"
out=$(_capture_stderr "${TMPDIR_BASE}/min.conf" CIRCLECI=true VERBOSE_OUTPUT=true || true)
assert_contains "GAP-1.5 stderr contains 'CircleCI'" "CircleCI" "$out"

# =============================================================================
# GAP-2: log_verbose annotation in _normalize_ui_gate_env
#
# This block is unchanged from pre-m16 — gates_ui_helpers.sh is still bash.
# Stub log_verbose to emit unconditionally so the assertion can detect the
# call independent of production VERBOSE_OUTPUT semantics.
# =============================================================================
echo "=== GAP-2: log_verbose annotation in _normalize_ui_gate_env ==="

log_verbose() { echo "LOG_VERBOSE: $*"; }

# shellcheck source=../lib/gates_ui_helpers.sh
source "${TEKHTON_HOME}/lib/gates_ui_helpers.sh"

_clear_gate_vars() {
    TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=""
    TEKHTON_CI_ENVIRONMENT_DETECTED=""
    UI_FRAMEWORK=""
    UI_TEST_CMD=""
    PROJECT_DIR="$TMPDIR_BASE"
    unset PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED 2>/dev/null || true
}

# GAP-2.1: TEKHTON_CI_ENVIRONMENT_DETECTED=1 → log_verbose emits the annotation
echo "  GAP-2.1: TEKHTON_CI_ENVIRONMENT_DETECTED=1 → [gate-env] diagnostic on stderr"
_clear_gate_vars
TEKHTON_CI_ENVIRONMENT_DETECTED=1
UI_FRAMEWORK=""

_tmp_stdout=$(mktemp)
_tmp_stderr=$(mktemp)
_normalize_ui_gate_env >"$_tmp_stdout" 2>"$_tmp_stderr"
_stderr_out=$(cat "$_tmp_stderr")
_stdout_out=$(cat "$_tmp_stdout")
rm -f "$_tmp_stdout" "$_tmp_stderr"

assert_contains "GAP-2.1 stderr contains [gate-env] prefix" "[gate-env]" "$_stderr_out"
assert_contains "GAP-2.1 stderr contains 'CI auto-detect'" "CI auto-detect" "$_stderr_out"
assert_contains "GAP-2.1 stderr contains 'TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1'" \
    "TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1" "$_stderr_out"
assert_contains "GAP-2.1 stderr contains 'automatically'" "automatically" "$_stderr_out"
assert_not_contains "GAP-2.1 stdout env list is clean of [gate-env] text" "[gate-env]" "$_stdout_out"

# GAP-2.2: TEKHTON_CI_ENVIRONMENT_DETECTED=0 → no diagnostic.
echo "  GAP-2.2: TEKHTON_CI_ENVIRONMENT_DETECTED=0 → no diagnostic on stderr"
_clear_gate_vars
TEKHTON_CI_ENVIRONMENT_DETECTED=0
UI_FRAMEWORK=""

_tmp_stdout=$(mktemp)
_tmp_stderr=$(mktemp)
_normalize_ui_gate_env >"$_tmp_stdout" 2>"$_tmp_stderr"
_stderr_out=$(cat "$_tmp_stderr")
rm -f "$_tmp_stdout" "$_tmp_stderr"

assert_not_contains "GAP-2.2 no [gate-env] when TEKHTON_CI_ENVIRONMENT_DETECTED=0" "[gate-env]" "$_stderr_out"

# GAP-2.3: TEKHTON_CI_ENVIRONMENT_DETECTED unset
echo "  GAP-2.3: TEKHTON_CI_ENVIRONMENT_DETECTED unset → no diagnostic on stderr"
_clear_gate_vars
unset TEKHTON_CI_ENVIRONMENT_DETECTED 2>/dev/null || true
UI_FRAMEWORK=""

_tmp_stdout=$(mktemp)
_tmp_stderr=$(mktemp)
_normalize_ui_gate_env >"$_tmp_stdout" 2>"$_tmp_stderr"
_stderr_out=$(cat "$_tmp_stderr")
rm -f "$_tmp_stdout" "$_tmp_stderr"

assert_not_contains "GAP-2.3 no [gate-env] when TEKHTON_CI_ENVIRONMENT_DETECTED unset" "[gate-env]" "$_stderr_out"

# GAP-2.4: TEKHTON_CI_ENVIRONMENT_DETECTED=1 with playwright framework active.
echo "  GAP-2.4: TEKHTON_CI_ENVIRONMENT_DETECTED=1 + playwright → stdout clean, stderr has annotation"
_clear_gate_vars
TEKHTON_CI_ENVIRONMENT_DETECTED=1
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1

_tmp_stdout=$(mktemp)
_tmp_stderr=$(mktemp)
_normalize_ui_gate_env >"$_tmp_stdout" 2>"$_tmp_stderr"
_stderr_out=$(cat "$_tmp_stderr")
_stdout_out=$(cat "$_tmp_stdout")
rm -f "$_tmp_stdout" "$_tmp_stderr"

assert_contains "GAP-2.4 stdout has playwright env var" "PLAYWRIGHT_HTML_OPEN=never" "$_stdout_out"
assert_contains "GAP-2.4 stderr has CI auto-detect annotation" "[gate-env]" "$_stderr_out"
assert_not_contains "GAP-2.4 [gate-env] not in stdout" "[gate-env]" "$_stdout_out"

echo ""
echo "════════════════════════════════════════"
echo "  M138 coverage gaps: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] || exit 1
