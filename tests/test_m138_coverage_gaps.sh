#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_m138_coverage_gaps.sh — Coverage-gap tests for M138
#
# Addresses two gaps identified in the M138 reviewer report:
#
#   GAP-1: VERBOSE_OUTPUT=true stderr diagnostic in _apply_ci_ui_gate_defaults
#     All 10 existing tests in test_ci_environment_detection.sh leave
#     VERBOSE_OUTPUT at its default (false). This file exercises the
#     `echo "[tekhton] CI environment detected …" >&2` branch and verifies
#     it is silent when VERBOSE_OUTPUT is false or auto-elevation does not fire.
#
#   GAP-2: log_verbose annotation in _normalize_ui_gate_env
#     No prior test covers the TEKHTON_CI_ENVIRONMENT_DETECTED=1 branch at
#     gates_ui_helpers.sh:97-99 that emits a diagnostic via log_verbose >&2.
#     This file verifies the call fires when detected=1 and is silent otherwise.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — '$needle' not found in stderr output"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if ! printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — '$needle' found in output but should be absent"
        FAIL=$((FAIL + 1))
    fi
}

# =============================================================================
# Source config_defaults_ci.sh for GAP-1 tests.
# We source the helper file directly (not via config_defaults.sh) so we get
# only the three M138 function definitions without triggering the full chain
# of 600+ lines of default assignments and their associated stubs.
# =============================================================================

# _apply_ci_ui_gate_defaults has no external dependencies beyond its sibling
# helpers in the same file. No stubs are required for sourcing.
# shellcheck source=../lib/config_defaults_ci.sh
source "${TEKHTON_HOME}/lib/config_defaults_ci.sh"

# Clear all named-platform CI signals that could leak from the parent shell.
# Matches the exact set checked by _detect_runtime_ci_environment.
_clear_all_ci_vars() {
    unset GITHUB_ACTIONS GITLAB_CI CIRCLECI TRAVIS BUILDKITE \
          JENKINS_URL TF_BUILD TEAMCITY_VERSION BITBUCKET_BUILD_NUMBER CI \
          2>/dev/null || true
}
_clear_all_ci_vars

# =============================================================================
# GAP-1: VERBOSE_OUTPUT=true stderr diagnostic in _apply_ci_ui_gate_defaults
#
# Source: lib/config_defaults_ci.sh lines 75-77
#   if [[ "${VERBOSE_OUTPUT:-false}" == "true" ]]; then
#       echo "[tekhton] CI environment detected ($(_get_ci_platform_name)) — TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 (auto)" >&2
#   fi
#
# The diagnostic fires ONLY when all three conditions are true:
#   1. The key is absent from _CONF_KEYS_SET (user did not set it explicitly)
#   2. _detect_runtime_ci_environment returns 0 (we are in a CI environment)
#   3. VERBOSE_OUTPUT=true
# =============================================================================
echo "=== GAP-1: VERBOSE_OUTPUT=true stderr diagnostic in _apply_ci_ui_gate_defaults ==="

# GAP-1.1: Happy path — all three conditions satisfied.
#   → stderr must contain the [tekhton] diagnostic with platform name.
echo "  GAP-1.1: CI detected + key absent + VERBOSE_OUTPUT=true → [tekhton] diagnostic on stderr"
_clear_all_ci_vars
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEKHTON_CI_ENVIRONMENT_DETECTED 2>/dev/null || true
export GITHUB_ACTIONS=true
_CONF_KEYS_SET="PROJECT_NAME TEST_CMD"
VERBOSE_OUTPUT=true

_tmp_stderr=$(mktemp)
_apply_ci_ui_gate_defaults 2>"$_tmp_stderr"
_stderr_out=$(cat "$_tmp_stderr"); rm -f "$_tmp_stderr"

assert_contains "GAP-1.1 stderr contains [tekhton] prefix" "[tekhton]" "$_stderr_out"
assert_contains "GAP-1.1 stderr contains 'CI environment detected'" "CI environment detected" "$_stderr_out"
assert_contains "GAP-1.1 stderr contains platform name 'GitHub Actions'" "GitHub Actions" "$_stderr_out"
assert_contains "GAP-1.1 stderr contains 'TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 (auto)'" \
    "TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 (auto)" "$_stderr_out"
unset GITHUB_ACTIONS VERBOSE_OUTPUT

# GAP-1.2: VERBOSE_OUTPUT=false (default) — auto-elevation fires silently.
#   → stderr must be empty regardless of CI detection.
echo "  GAP-1.2: CI detected + key absent + VERBOSE_OUTPUT=false → no stderr output"
_clear_all_ci_vars
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEKHTON_CI_ENVIRONMENT_DETECTED 2>/dev/null || true
export GITHUB_ACTIONS=true
_CONF_KEYS_SET="PROJECT_NAME TEST_CMD"
VERBOSE_OUTPUT=false

_tmp_stderr=$(mktemp)
_apply_ci_ui_gate_defaults 2>"$_tmp_stderr"
_stderr_out=$(cat "$_tmp_stderr"); rm -f "$_tmp_stderr"

assert_not_contains "GAP-1.2 no [tekhton] output when VERBOSE_OUTPUT=false" "[tekhton]" "$_stderr_out"
unset GITHUB_ACTIONS VERBOSE_OUTPUT

# GAP-1.3: VERBOSE_OUTPUT=true but no CI detected.
#   → auto-elevation never fires → diagnostic is not emitted.
echo "  GAP-1.3: No CI detected + VERBOSE_OUTPUT=true → no stderr output"
_clear_all_ci_vars
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEKHTON_CI_ENVIRONMENT_DETECTED 2>/dev/null || true
_CONF_KEYS_SET="PROJECT_NAME TEST_CMD"
VERBOSE_OUTPUT=true

_tmp_stderr=$(mktemp)
_apply_ci_ui_gate_defaults 2>"$_tmp_stderr"
_stderr_out=$(cat "$_tmp_stderr"); rm -f "$_tmp_stderr"

assert_not_contains "GAP-1.3 no [tekhton] when not in CI" "[tekhton]" "$_stderr_out"
unset VERBOSE_OUTPUT

# GAP-1.4: VERBOSE_OUTPUT=true + CI detected + key IN _CONF_KEYS_SET.
#   → explicit user override wins → auto-elevation is suppressed → no diagnostic.
echo "  GAP-1.4: CI detected + key explicitly in pipeline.conf + VERBOSE_OUTPUT=true → no stderr"
_clear_all_ci_vars
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEKHTON_CI_ENVIRONMENT_DETECTED 2>/dev/null || true
export GITHUB_ACTIONS=true
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0
_CONF_KEYS_SET="PROJECT_NAME TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEST_CMD"
VERBOSE_OUTPUT=true

_tmp_stderr=$(mktemp)
_apply_ci_ui_gate_defaults 2>"$_tmp_stderr"
_stderr_out=$(cat "$_tmp_stderr"); rm -f "$_tmp_stderr"

assert_not_contains "GAP-1.4 no [tekhton] when key was explicitly set by user" "[tekhton]" "$_stderr_out"
unset GITHUB_ACTIONS VERBOSE_OUTPUT

# GAP-1.5: Verify platform name changes with CI platform — use CIRCLECI to
#   confirm _get_ci_platform_name returns the right string in the diagnostic.
echo "  GAP-1.5: CIRCLECI=true + VERBOSE_OUTPUT=true → 'CircleCI' in stderr diagnostic"
_clear_all_ci_vars
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEKHTON_CI_ENVIRONMENT_DETECTED 2>/dev/null || true
export CIRCLECI=true
_CONF_KEYS_SET="PROJECT_NAME TEST_CMD"
VERBOSE_OUTPUT=true

_tmp_stderr=$(mktemp)
_apply_ci_ui_gate_defaults 2>"$_tmp_stderr"
_stderr_out=$(cat "$_tmp_stderr"); rm -f "$_tmp_stderr"

assert_contains "GAP-1.5 stderr contains 'CircleCI'" "CircleCI" "$_stderr_out"
unset CIRCLECI VERBOSE_OUTPUT

# =============================================================================
# GAP-2: log_verbose annotation in _normalize_ui_gate_env
#
# Source: lib/gates_ui_helpers.sh lines 97-99
#   if [[ "${TEKHTON_CI_ENVIRONMENT_DETECTED:-0}" == "1" ]]; then
#       log_verbose "[gate-env] TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 was set automatically (CI auto-detect)" >&2
#   fi
#
# The >&2 redirect is load-bearing: _normalize_ui_gate_env's stdout is consumed
# by `mapfile` in _ui_run_cmd. Any unredirected output would corrupt the
# KEY=VALUE env list. We verify the diagnostic appears on stderr, not stdout.
#
# We stub log_verbose to always emit (independent of VERBOSE_OUTPUT) so the
# assertion can detect the call without depending on production VERBOSE_OUTPUT
# semantics.
# =============================================================================
echo "=== GAP-2: log_verbose annotation in _normalize_ui_gate_env ==="

# Stub log_verbose to emit unconditionally — the call itself is what we are
# testing, not the VERBOSE_OUTPUT gate inside the production implementation.
# The stub writes to stdout; the >&2 in the source redirects that to stderr.
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

# GAP-2.1: TEKHTON_CI_ENVIRONMENT_DETECTED=1 → log_verbose emits the
#   [gate-env] diagnostic to stderr; stdout env list is unaffected.
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
# Verify the diagnostic does NOT bleed into the stdout env list
assert_not_contains "GAP-2.1 stdout env list is clean of [gate-env] text" "[gate-env]" "$_stdout_out"

# GAP-2.2: TEKHTON_CI_ENVIRONMENT_DETECTED=0 → no log_verbose call, stderr empty.
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

# GAP-2.3: TEKHTON_CI_ENVIRONMENT_DETECTED unset (treated as 0 by :- default).
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
#   → stdout contains the playwright env line; stderr has the CI annotation.
#   Confirms the >&2 redirect correctly separates the two channels.
echo "  GAP-2.4: TEKHTON_CI_ENVIRONMENT_DETECTED=1 + playwright → stdout clean, stderr has diagnostic"
_clear_gate_vars
TEKHTON_CI_ENVIRONMENT_DETECTED=1
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1  # triggers playwright framework path

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
