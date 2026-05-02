#!/usr/bin/env bash
# Test: Runtime CI environment auto-detection (m138)
# Tests _detect_runtime_ci_environment(), _get_ci_platform_name(), and
# _apply_ci_ui_gate_defaults() — the source-time defaulter that elevates
# TEKHTON_UI_GATE_FORCE_NONINTERACTIVE to 1 inside a CI environment when
# the user has not set the key explicitly in pipeline.conf.
# shellcheck disable=SC2034
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Stubs for functions config_defaults.sh expects from common.sh / config.sh.
# config_defaults.sh sources config_defaults_ci.sh and then calls
# _apply_ci_ui_gate_defaults at top level — these stubs keep that side effect
# silent and prevent un-stubbed clamp helpers from aborting the source.
log()                  { :; }
warn()                 { :; }
log_verbose()          { :; }
_clamp_config_value()  { :; }
_clamp_config_float()  { :; }

# Minimal fake PROJECT_DIR so _FILE defaults that interpolate it don't blow up.
TEST_TMPDIR=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Required top-level config var for the source-time validation paths.
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"

# Clear every CI signal we test against — inherited values from the parent
# shell would otherwise contaminate T1 / T6 / T10. The named-platform list
# matches the helper exactly; keep them in sync.
_clear_all_ci_vars() {
    unset GITHUB_ACTIONS GITLAB_CI CIRCLECI TRAVIS BUILDKITE
    unset JENKINS_URL TF_BUILD TEAMCITY_VERSION BITBUCKET_BUILD_NUMBER CI
}
_clear_all_ci_vars

# Source config_defaults.sh — chains into config_defaults_ci.sh and defines
# the three m138 helpers we exercise below.
# shellcheck source=../lib/config_defaults.sh
source "${TEKHTON_HOME}/lib/config_defaults.sh"

echo "=== T1: No CI vars set → returns 1 ==="
_clear_all_ci_vars
if _detect_runtime_ci_environment; then
    fail "T1: expected 1 (no CI), got 0 (detected)"
else
    pass "T1: no CI signals → returns 1"
fi
[[ "$(_get_ci_platform_name)" == "unknown" ]] \
    && pass "T1: platform name is 'unknown'" \
    || fail "T1: platform name expected 'unknown', got '$(_get_ci_platform_name)'"

echo "=== T2: GITHUB_ACTIONS=true → GitHub Actions ==="
_clear_all_ci_vars
export GITHUB_ACTIONS=true
_detect_runtime_ci_environment \
    && pass "T2: GITHUB_ACTIONS=true → returns 0" \
    || fail "T2: expected 0, got 1"
[[ "$(_get_ci_platform_name)" == "GitHub Actions" ]] \
    && pass "T2: platform name 'GitHub Actions'" \
    || fail "T2: platform name expected 'GitHub Actions', got '$(_get_ci_platform_name)'"
unset GITHUB_ACTIONS

echo "=== T3: GITLAB_CI=true → GitLab CI ==="
_clear_all_ci_vars
export GITLAB_CI=true
_detect_runtime_ci_environment \
    && pass "T3: GITLAB_CI=true → returns 0" \
    || fail "T3: expected 0, got 1"
[[ "$(_get_ci_platform_name)" == "GitLab CI" ]] \
    && pass "T3: platform name 'GitLab CI'" \
    || fail "T3: platform name expected 'GitLab CI', got '$(_get_ci_platform_name)'"
unset GITLAB_CI

echo "=== T4: CIRCLECI=true → CircleCI ==="
_clear_all_ci_vars
export CIRCLECI=true
_detect_runtime_ci_environment \
    && pass "T4: CIRCLECI=true → returns 0" \
    || fail "T4: expected 0, got 1"
[[ "$(_get_ci_platform_name)" == "CircleCI" ]] \
    && pass "T4: platform name 'CircleCI'" \
    || fail "T4: platform name expected 'CircleCI', got '$(_get_ci_platform_name)'"
unset CIRCLECI

echo "=== T5: JENKINS_URL=non-empty → Jenkins ==="
_clear_all_ci_vars
export JENKINS_URL="http://jenkins.example.com/"
_detect_runtime_ci_environment \
    && pass "T5: JENKINS_URL set → returns 0" \
    || fail "T5: expected 0, got 1"
[[ "$(_get_ci_platform_name)" == "Jenkins" ]] \
    && pass "T5: platform name 'Jenkins'" \
    || fail "T5: platform name expected 'Jenkins', got '$(_get_ci_platform_name)'"
unset JENKINS_URL

echo "=== T6: Generic CI=true (no named-platform var) → CI (generic) ==="
_clear_all_ci_vars
export CI=true
_detect_runtime_ci_environment \
    && pass "T6: CI=true → returns 0" \
    || fail "T6: expected 0, got 1"
[[ "$(_get_ci_platform_name)" == "CI (generic)" ]] \
    && pass "T6: platform name 'CI (generic)'" \
    || fail "T6: platform name expected 'CI (generic)', got '$(_get_ci_platform_name)'"
unset CI

echo "=== T7: CI detected + key NOT in _CONF_KEYS_SET → auto-elevate to 1 ==="
_clear_all_ci_vars
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEKHTON_CI_ENVIRONMENT_DETECTED
export GITHUB_ACTIONS=true
_CONF_KEYS_SET="PROJECT_NAME TEST_CMD"   # key absent from user's pipeline.conf
_apply_ci_ui_gate_defaults
[[ "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE}" == "1" ]] \
    && pass "T7: TEKHTON_UI_GATE_FORCE_NONINTERACTIVE auto-elevated to 1" \
    || fail "T7: expected 1, got '${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:-<unset>}'"
[[ "${TEKHTON_CI_ENVIRONMENT_DETECTED}" == "1" ]] \
    && pass "T7: TEKHTON_CI_ENVIRONMENT_DETECTED=1" \
    || fail "T7: TEKHTON_CI_ENVIRONMENT_DETECTED expected 1, got '${TEKHTON_CI_ENVIRONMENT_DETECTED:-<unset>}'"
unset GITHUB_ACTIONS

echo "=== T8: Explicit pipeline.conf =0 wins over CI detection ==="
_clear_all_ci_vars
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEKHTON_CI_ENVIRONMENT_DETECTED
export GITHUB_ACTIONS=true
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0   # user explicitly opted out in pipeline.conf
_CONF_KEYS_SET="PROJECT_NAME TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEST_CMD"
_apply_ci_ui_gate_defaults
[[ "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE}" == "0" ]] \
    && pass "T8: explicit =0 honoured (auto-elevation suppressed)" \
    || fail "T8: expected 0, got '${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE}'"
[[ "${TEKHTON_CI_ENVIRONMENT_DETECTED}" == "0" ]] \
    && pass "T8: TEKHTON_CI_ENVIRONMENT_DETECTED=0 (explicit-wins branch)" \
    || fail "T8: TEKHTON_CI_ENVIRONMENT_DETECTED expected 0, got '${TEKHTON_CI_ENVIRONMENT_DETECTED}'"
unset GITHUB_ACTIONS

echo "=== T9: Explicit pipeline.conf =1 preserved (no CI required) ==="
_clear_all_ci_vars
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEKHTON_CI_ENVIRONMENT_DETECTED
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1
_CONF_KEYS_SET="PROJECT_NAME TEKHTON_UI_GATE_FORCE_NONINTERACTIVE"
_apply_ci_ui_gate_defaults
[[ "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE}" == "1" ]] \
    && pass "T9: explicit =1 preserved" \
    || fail "T9: expected 1, got '${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE}'"

echo "=== T10: No CI + no conf key → defaults to 0 ==="
_clear_all_ci_vars
unset TEKHTON_UI_GATE_FORCE_NONINTERACTIVE TEKHTON_CI_ENVIRONMENT_DETECTED
_CONF_KEYS_SET="PROJECT_NAME TEST_CMD"
_apply_ci_ui_gate_defaults
[[ "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE}" == "0" ]] \
    && pass "T10: defaults to 0 outside CI" \
    || fail "T10: expected 0, got '${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE}'"
[[ "${TEKHTON_CI_ENVIRONMENT_DETECTED}" == "0" ]] \
    && pass "T10: TEKHTON_CI_ENVIRONMENT_DETECTED=0" \
    || fail "T10: TEKHTON_CI_ENVIRONMENT_DETECTED expected 0, got '${TEKHTON_CI_ENVIRONMENT_DETECTED}'"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
