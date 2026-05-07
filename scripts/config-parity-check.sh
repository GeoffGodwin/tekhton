#!/usr/bin/env bash
# scripts/config-parity-check.sh — m16 acceptance gate.
#
# The pre-m16 bash loader (lib/config.sh::load_config + lib/config_defaults.sh
# + lib/config_defaults_ci.sh) was ~1100 lines of `:=` defaults, validations,
# clamps, and CI auto-detection. m16 ports the entire loader to Go and reduces
# the bash side to a 50-line shim.
#
# This script asserts behavioural parity by sourcing the Go-emitted shell
# environment for each fixture under tests/fixtures/config/ and verifying:
#
#   1. Required-key validation rejects configs missing PROJECT_NAME / CLAUDE_STANDARD_MODEL / ANALYZE_CMD
#   2. Defaults populate every documented key
#   3. Operator-set values override defaults
#   4. Out-of-range values are clamped to the hard caps
#   5. Invalid enum values reset to safe defaults
#   6. Health weights mismatching 100 trigger reset to defaults
#   7. CI auto-detection elevates TEKHTON_UI_GATE_FORCE_NONINTERACTIVE
#   8. Explicit pipeline.conf value wins over CI auto-elevation
#   9. Relative paths resolve against PROJECT_DIR
#  10. Milestone-mode overrides apply on top of base config
#
# Exit codes:
#   0 — all assertions hold
#   1 — at least one assertion failed (or setup error)
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$REPO_ROOT"

_log()  { printf '\033[0;36m[parity]\033[0m %s\n' "$*"; }
_ok()   { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
_fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

FAIL_COUNT=0

if ! command -v go >/dev/null 2>&1; then
    _log "Go not installed — config parity gate cannot run. Skipping."
    exit 0
fi

_log "Building Go binary via 'make build'..."
make build >/dev/null
GO_BIN="${REPO_ROOT}/bin/tekhton"

FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/config"

# Load a fixture with optional CI-env vars and milestone-mode flag, source
# the emit-shell payload into a clean subshell, and print one key's value.
# Usage: _emit_var FIXTURE KEY [--milestone-mode] [VAR=value ...]
#
# We `eval` the shell payload (rather than regex-extracting from the raw
# `export KEY='value'` line) so single-quote escape sequences (`'\''`) decode
# correctly — that's the round trip a real bash caller actually performs.
_emit_var() {
    local fixture="$1"; shift
    local key="$1"; shift
    local extra_args=()
    if [[ "${1:-}" == "--milestone-mode" ]]; then
        extra_args+=(--milestone-mode); shift
    fi
    local proj
    proj=$(mktemp -d)
    # shellcheck disable=SC2064 # expand-now is intentional — capture this $proj
    trap "rm -rf '$proj'" RETURN
    local payload
    payload=$(env -i PATH="$PATH" HOME="$HOME" "$@" \
        "$GO_BIN" config load --path "${FIXTURE_DIR}/${fixture}" --project-dir "$proj" \
        "${extra_args[@]}" --emit shell --no-warn 2>/dev/null)
    (
        eval "$payload"
        eval "printf '%s' \"\${${key}-}\""
    )
}

# Assert that loading a fixture exits with the given code.
# Usage: _assert_exit FIXTURE EXPECTED_CODE
_assert_exit() {
    local fixture="$1" expected="$2"
    local proj
    proj=$(mktemp -d)
    # shellcheck disable=SC2064 # expand-now is intentional — capture this $proj
    trap "rm -rf '$proj'" RETURN
    set +e
    env -i PATH="$PATH" HOME="$HOME" \
        "$GO_BIN" config load --path "${FIXTURE_DIR}/${fixture}" --project-dir "$proj" \
        --emit shell --no-warn >/dev/null 2>&1
    local actual=$?
    set -e
    [[ "$actual" == "$expected" ]]
}

_assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        _ok "$desc"
    else
        _fail "$desc — expected '$expected', got '$actual'"
    fi
}

# === FIXTURES =================================================================

_log "Fixture 01_minimal: defaults populate every documented key"
_assert_eq "PROJECT_NAME from conf"   "minimal"           "$(_emit_var 01_minimal.conf PROJECT_NAME)"
_assert_eq "CODER_MAX_TURNS default"  "80"                "$(_emit_var 01_minimal.conf CODER_MAX_TURNS)"
_assert_eq "MAX_REVIEW_CYCLES default" "3"                "$(_emit_var 01_minimal.conf MAX_REVIEW_CYCLES)"
_assert_eq "TEKHTON_DIR default"      ".tekhton"          "$(_emit_var 01_minimal.conf TEKHTON_DIR)"
_assert_eq "DASHBOARD_VERBOSITY default" "normal"          "$(_emit_var 01_minimal.conf DASHBOARD_VERBOSITY)"
_assert_eq "PIPELINE_ORDER default"   "standard"          "$(_emit_var 01_minimal.conf PIPELINE_ORDER)"

_log "Fixture 02_customized: operator overrides apply"
_assert_eq "PROJECT_DESCRIPTION override" "A real description" "$(_emit_var 02_customized.conf PROJECT_DESCRIPTION)"
_assert_eq "CODER_MAX_TURNS override"     "120"                "$(_emit_var 02_customized.conf CODER_MAX_TURNS)"
_assert_eq "DASHBOARD_VERBOSITY override" "verbose"            "$(_emit_var 02_customized.conf DASHBOARD_VERBOSITY)"
_assert_eq "SECURITY_BLOCK_SEVERITY override" "MEDIUM"          "$(_emit_var 02_customized.conf SECURITY_BLOCK_SEVERITY)"
_assert_eq "INTAKE_TWEAK_THRESHOLD override" "80"                "$(_emit_var 02_customized.conf INTAKE_TWEAK_THRESHOLD)"

_log "Fixture 03_ci_default: no CI env → 0; CI env → 1"
_assert_eq "no CI: TEKHTON_UI_GATE_FORCE_NONINTERACTIVE" "0" "$(_emit_var 03_ci_default.conf TEKHTON_UI_GATE_FORCE_NONINTERACTIVE)"
_assert_eq "no CI: TEKHTON_CI_ENVIRONMENT_DETECTED"      "0" "$(_emit_var 03_ci_default.conf TEKHTON_CI_ENVIRONMENT_DETECTED)"
_assert_eq "GH:    TEKHTON_UI_GATE_FORCE_NONINTERACTIVE" "1" "$(_emit_var 03_ci_default.conf TEKHTON_UI_GATE_FORCE_NONINTERACTIVE GITHUB_ACTIONS=true)"
_assert_eq "GH:    TEKHTON_CI_ENVIRONMENT_DETECTED"      "1" "$(_emit_var 03_ci_default.conf TEKHTON_CI_ENVIRONMENT_DETECTED GITHUB_ACTIONS=true)"

_log "Fixture 04_ci_explicit_override: explicit value wins over auto-elevation"
_assert_eq "explicit 0 wins under CI" "0" "$(_emit_var 04_ci_explicit_override.conf TEKHTON_UI_GATE_FORCE_NONINTERACTIVE GITHUB_ACTIONS=true)"
_assert_eq "CI still detected for diagnostics" "1" "$(_emit_var 04_ci_explicit_override.conf TEKHTON_CI_ENVIRONMENT_DETECTED GITHUB_ACTIONS=true)"

_log "Fixture 05_out_of_range: integer + float clamps fire"
_assert_eq "CODER_MAX_TURNS clamped"  "500" "$(_emit_var 05_out_of_range.conf CODER_MAX_TURNS)"
_assert_eq "DASHBOARD_HISTORY_DEPTH reset to 50 (range check)" "50" "$(_emit_var 05_out_of_range.conf DASHBOARD_HISTORY_DEPTH)"
_assert_eq "INTAKE_CLARITY/_TWEAK reset to defaults" "40" "$(_emit_var 05_out_of_range.conf INTAKE_CLARITY_THRESHOLD)"
_assert_eq "INTAKE_TWEAK_THRESHOLD reset"            "70" "$(_emit_var 05_out_of_range.conf INTAKE_TWEAK_THRESHOLD)"
_assert_eq "QUOTA_RETRY_INTERVAL reset (range)"       "300" "$(_emit_var 05_out_of_range.conf QUOTA_RETRY_INTERVAL)"
_assert_eq "REWORK_TURN_ESCALATION_FACTOR clamped to 10.0" "10.0" "$(_emit_var 05_out_of_range.conf REWORK_TURN_ESCALATION_FACTOR)"
_assert_eq "UI_GATE_ENV_RETRY_TIMEOUT_FACTOR clamped to 1.0" "1.0" "$(_emit_var 05_out_of_range.conf UI_GATE_ENV_RETRY_TIMEOUT_FACTOR)"

_log "Fixture 06_invalid_enums: bad enum values reset to safe defaults"
_assert_eq "PIPELINE_ORDER reset to standard"        "standard" "$(_emit_var 06_invalid_enums.conf PIPELINE_ORDER)"
_assert_eq "UI_FRAMEWORK reset to empty"             ""         "$(_emit_var 06_invalid_enums.conf UI_FRAMEWORK)"
_assert_eq "SECURITY_BLOCK_SEVERITY reset to HIGH"   "HIGH"     "$(_emit_var 06_invalid_enums.conf SECURITY_BLOCK_SEVERITY)"
_assert_eq "SECURITY_UNFIXABLE_POLICY reset"         "escalate" "$(_emit_var 06_invalid_enums.conf SECURITY_UNFIXABLE_POLICY)"
_assert_eq "DASHBOARD_VERBOSITY reset to normal"     "normal"   "$(_emit_var 06_invalid_enums.conf DASHBOARD_VERBOSITY)"
_assert_eq "UI_VALIDATION_CONSOLE_SEVERITY reset"    "error"    "$(_emit_var 06_invalid_enums.conf UI_VALIDATION_CONSOLE_SEVERITY)"

_log "Fixture 07_health_weights_bad: weights resetting"
_assert_eq "HEALTH_WEIGHT_TESTS reset"   "30" "$(_emit_var 07_health_weights_bad.conf HEALTH_WEIGHT_TESTS)"
_assert_eq "HEALTH_WEIGHT_QUALITY reset" "25" "$(_emit_var 07_health_weights_bad.conf HEALTH_WEIGHT_QUALITY)"

_log "Fixture 08_paths_relative: PROJECT_DIR resolution"
_proj=$(mktemp -d)
# shellcheck disable=SC2064 # expand-now is intentional
trap "rm -rf '$_proj'" EXIT
_pipeline_state=$(env -i PATH="$PATH" HOME="$HOME" "$GO_BIN" config load \
    --path "${FIXTURE_DIR}/08_paths_relative.conf" --project-dir "$_proj" \
    --emit shell --no-warn 2>/dev/null \
    | grep -E '^export PIPELINE_STATE_FILE=' | sed -E "s/^export PIPELINE_STATE_FILE='(.*)'\$/\1/")
case "$_pipeline_state" in
    "$_proj"/custom/state.md) _ok "PIPELINE_STATE_FILE resolved to ${_pipeline_state}" ;;
    *)                        _fail "PIPELINE_STATE_FILE resolution failed (got: $_pipeline_state)" ;;
esac

_log "Fixture 09_quoted_values: parser strips quotes + inline comments"
_assert_eq "single-quoted value"    "single-quoted"               "$(_emit_var 09_quoted_values.conf PROJECT_NAME)"
_assert_eq "ANALYZE_CMD piped value" "bash -c 'eslint . | tee out.txt'" "$(_emit_var 09_quoted_values.conf ANALYZE_CMD)"
# Bash parity: when a quoted value is followed by an inline comment, the
# quote-strip step does NOT fire (value as a whole doesn't match `^".*"$`),
# so the resulting value retains its surrounding quotes after the inline
# comment is removed. Replicates lib/config.sh's behavior.
_assert_eq "PROJECT_DESCRIPTION trim trailing comment" '"A real one"' "$(_emit_var 09_quoted_values.conf PROJECT_DESCRIPTION)"
_assert_eq "ANALYZE_ERROR_PATTERN keeps pipe" "error|fail" "$(_emit_var 09_quoted_values.conf ANALYZE_ERROR_PATTERN)"

_log "Fixture 10_milestone_mode: --milestone-mode applies overrides"
_assert_eq "base CODER_MAX_TURNS=80"        "80"  "$(_emit_var 10_milestone_mode.conf CODER_MAX_TURNS)"
_assert_eq "milestone CODER_MAX_TURNS=200" "200" "$(_emit_var 10_milestone_mode.conf CODER_MAX_TURNS --milestone-mode)"
_assert_eq "milestone REVIEWER_MAX_TURNS=30" "30" "$(_emit_var 10_milestone_mode.conf REVIEWER_MAX_TURNS --milestone-mode)"

_log "Required-key enforcement: missing keys exit non-zero"
_invalid_dir=$(mktemp -d)
# shellcheck disable=SC2064 # expand-now is intentional
trap "rm -rf '$_invalid_dir'" EXIT
echo "PROJECT_NAME=oops" > "${_invalid_dir}/missing.conf"
if env -i PATH="$PATH" HOME="$HOME" "$GO_BIN" config load --path "${_invalid_dir}/missing.conf" --project-dir "$_invalid_dir" --emit shell --no-warn >/dev/null 2>&1; then
    _fail "missing required keys: expected non-zero exit, got 0"
else
    _ok "missing required keys: non-zero exit"
fi

# === SUMMARY =================================================================

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    _log "All parity assertions passed."
    exit 0
fi
_log "config parity gate: ${FAIL_COUNT} assertion(s) failed."
exit 1
