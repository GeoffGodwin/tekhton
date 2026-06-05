#!/usr/bin/env bash
# =============================================================================
# test_state_writer_resume_fields.sh — m40.1 acceptance test for the auto-
# advance round-trip in the bash state writer.
#
# Exercises write_pipeline_state with AUTO_ADVANCE=true AUTO_ADVANCE_LIMIT=4
# in the environment and asserts the produced JSON contains both fields with
# the right shape (auto_advance: true, auto_advance_limit: 4). Backward-compat
# AC: a writer call WITHOUT the env vars must produce a JSON envelope that
# omits both fields.
#
# Covers both writer paths:
#   1. Go path:  `tekhton state update` reads --field K=V and applies the
#      reflective applyField extended for reflect.Bool in m40.1.
#   2. Bash fallback: `_state_bash_write_fields` honors the bool/int scalar
#      types and omitempty parity with the Go encoder.
#
# Skips gracefully when the tekhton binary is not available (fresh-clone CI
# before `make build`); the bash-fallback path is still exercised.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"

FAIL=0
_pass() { echo "PASS: $*"; }
_fail() { echo "FAIL: $*"; FAIL=1; }

# _write_with_env STATE_FILE AUTO_ADVANCE_VAL AUTO_ADVANCE_LIMIT_VAL
# Wraps a fresh subshell so the source + env state is isolated per scenario.
_write_with_env() {
    local state_file="$1"
    local aa="${2:-}"
    local aal="${3:-}"
    local force_bash="${4:-false}"
    (
        # Always clear any inherited AUTO_ADVANCE_* before the test reseeds.
        # Tekhton-pipeline-driven test runs export these for the current
        # milestone — a stale parent value would mask backward-compat
        # regressions.
        unset AUTO_ADVANCE AUTO_ADVANCE_LIMIT
        PIPELINE_STATE_FILE="$state_file"
        export PIPELINE_STATE_FILE
        [[ -n "$aa"  ]] && { AUTO_ADVANCE="$aa";  export AUTO_ADVANCE; }
        [[ -n "$aal" ]] && { AUTO_ADVANCE_LIMIT="$aal"; export AUTO_ADVANCE_LIMIT; }

        if [[ "$force_bash" = "true" ]]; then
            # Re-export PATH minus the tekhton binary location so the writer
            # exercises the bash-fallback branch even when `make build` has
            # produced bin/tekhton. Modification is intentionally subshell-
            # local — _write_with_env runs in (..) so the parent script's PATH
            # is untouched.
            # shellcheck disable=SC2030
            PATH=$(printf '%s' "$PATH" | tr ':' '\n' \
                | grep -v -E '(tekhton/bin|/tekhton/?$)' | paste -sd: -)
            export PATH
        fi

        # shellcheck source=/dev/null
        source "${TEKHTON_HOME}/lib/state.sh"
        write_pipeline_state "review" "blockers_remain" "--start-at review" \
            "Drive m40.1 round-trip" "test note" "m42"
    )
}

# ---------------------------------------------------------------------------
# Locate the tekhton binary (optional — bash fallback is the primary gate).
# ---------------------------------------------------------------------------

_TEKHTON_BIN=""
if [[ -x "${TEKHTON_HOME}/bin/tekhton" ]]; then
    _TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"
fi

# ---------------------------------------------------------------------------
# Scenario A: bash-fallback writer — primary path; runs even without binary.
# ---------------------------------------------------------------------------

_BASH_FILE="${TMPDIR}/state_bash.json"
_write_with_env "$_BASH_FILE" "true" "4" "true"

if [[ ! -f "$_BASH_FILE" ]]; then
    _fail "bash-fallback writer did not produce $_BASH_FILE"
else
    if grep -q '"auto_advance":true' "$_BASH_FILE"; then
        _pass "bash-fallback emits auto_advance: true"
    else
        _fail "bash-fallback missing auto_advance — file: $(cat "$_BASH_FILE")"
    fi
    if grep -q '"auto_advance_limit":4' "$_BASH_FILE"; then
        _pass "bash-fallback emits auto_advance_limit: 4"
    else
        _fail "bash-fallback missing auto_advance_limit — file: $(cat "$_BASH_FILE")"
    fi
fi

# Backward-compat: writer call WITHOUT env vars must omit both fields.
_BASH_FILE_OFF="${TMPDIR}/state_bash_off.json"
_write_with_env "$_BASH_FILE_OFF" "" "" "true"

if grep -q '"auto_advance"' "$_BASH_FILE_OFF"; then
    _fail "bash-fallback emitted auto_advance without env set"
else
    _pass "bash-fallback omits auto_advance when AUTO_ADVANCE unset"
fi
if grep -q '"auto_advance_limit"' "$_BASH_FILE_OFF"; then
    _fail "bash-fallback emitted auto_advance_limit without env set"
else
    _pass "bash-fallback omits auto_advance_limit when env unset"
fi

# ---------------------------------------------------------------------------
# Scenario B: Go-path writer (`tekhton state update`). Skipped without binary.
# ---------------------------------------------------------------------------

if [[ -n "$_TEKHTON_BIN" ]]; then
    # Top-level PATH update — the earlier _write_with_env subshells that
    # stripped PATH ran in (..) and did not leak back here. shellcheck's
    # SC2031 false-flags this; silence it explicitly.
    # shellcheck disable=SC2031
    PATH="${TEKHTON_HOME}/bin:$PATH"
    export PATH

    _GO_FILE="${TMPDIR}/state_go.json"
    _write_with_env "$_GO_FILE" "true" "4" "false"

    if [[ ! -f "$_GO_FILE" ]]; then
        _fail "Go-path writer did not produce $_GO_FILE"
    else
        # Validate JSON parses by re-reading it through the Go state reader;
        # a corrupt file yields exit 2. `tekhton state read` is the closest
        # in-repo equivalent to the "tekhton state validate" the milestone
        # design refers to (see CODER_SUMMARY Design Observations).
        if "$_TEKHTON_BIN" state read --path "$_GO_FILE" >/dev/null 2>&1; then
            _pass "Go-path produces valid JSON (state read exits 0)"
        else
            _fail "Go-path JSON failed to parse via state read"
        fi
        _val=$("$_TEKHTON_BIN" state read --path "$_GO_FILE" --field auto_advance 2>/dev/null || true)
        if [[ "$_val" = "true" ]]; then
            _pass "Go-path persists auto_advance=true"
        else
            _fail "Go-path auto_advance read returned '$_val' (want 'true')"
        fi
        _val=$("$_TEKHTON_BIN" state read --path "$_GO_FILE" --field auto_advance_limit 2>/dev/null || true)
        if [[ "$_val" = "4" ]]; then
            _pass "Go-path persists auto_advance_limit=4"
        else
            _fail "Go-path auto_advance_limit read returned '$_val' (want '4')"
        fi
    fi

    # Backward-compat round-trip via the Go reader.
    _GO_FILE_OFF="${TMPDIR}/state_go_off.json"
    _write_with_env "$_GO_FILE_OFF" "" "" "false"

    _val=$("$_TEKHTON_BIN" state read --path "$_GO_FILE_OFF" --field auto_advance 2>/dev/null || true)
    if [[ -z "$_val" ]]; then
        _pass "Go-path omits auto_advance when AUTO_ADVANCE unset"
    else
        _fail "Go-path emitted auto_advance='$_val' when env unset"
    fi
else
    echo "SKIP: Go-path tests — tekhton binary not built (run 'make build' to enable)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "state writer resume-fields test passed"
