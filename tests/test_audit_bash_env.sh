#!/usr/bin/env bash
# tests/test_audit_bash_env.sh — m27.1 unit tests for the env-audit script.
#
# Drives `scripts/audit-bash-env.sh` against six fixtures that isolate one
# detection case each (guarded / unguarded / comment / conditional /
# out-of-allowlist / single-quoted-heredoc). Verifies exit codes and
# expected output substrings. Also asserts that a default scan of
# lib/ + stages/ completes under 5 seconds (m27.1 acceptance criterion).
set -euo pipefail

TEKHTON_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_SCRIPT="${TEKHTON_HOME}/scripts/audit-bash-env.sh"
FIXTURES_DIR="${TEKHTON_HOME}/tests/testdata/audit_bash_env"

FAILED_CASES=()

# Run audit against a single fixture and capture (output, exit code).
_run_audit() {
    local target="$1"
    local _output
    local _rc
    set +e
    _output="$(bash "${AUDIT_SCRIPT}" "${target}" 2>&1)"
    _rc=$?
    set -e
    AUDIT_OUTPUT="${_output}"
    AUDIT_RC="${_rc}"
}

_assert_exit() {
    local label="$1"
    local expected="$2"
    if [[ "${AUDIT_RC}" -ne "${expected}" ]]; then
        echo "FAIL: ${label} — expected exit ${expected}, got ${AUDIT_RC}"
        echo "  Output: ${AUDIT_OUTPUT}"
        FAILED_CASES+=("${label}")
        return 1
    fi
    return 0
}

_assert_empty_stdout() {
    local label="$1"
    if [[ -n "${AUDIT_OUTPUT}" ]]; then
        echo "FAIL: ${label} — expected empty output, got: ${AUDIT_OUTPUT}"
        FAILED_CASES+=("${label}")
        return 1
    fi
    return 0
}

_assert_contains() {
    local label="$1"
    local needle="$2"
    if ! grep -qF -- "${needle}" <<<"${AUDIT_OUTPUT}"; then
        echo "FAIL: ${label} — expected output to contain '${needle}'"
        echo "  Actual: ${AUDIT_OUTPUT}"
        FAILED_CASES+=("${label}")
        return 1
    fi
    return 0
}

# --- Acceptance: script exists and is executable -------------------------
echo "== test: script is present and executable"
if [[ ! -x "${AUDIT_SCRIPT}" ]]; then
    echo "FAIL: ${AUDIT_SCRIPT} is missing or not executable"
    FAILED_CASES+=("script-executable")
fi

# --- Fixture 01: guarded — must NOT flag ---------------------------------
echo "== test: 01-guarded — \${VAR:-default} is safe"
_run_audit "${FIXTURES_DIR}/01-guarded.sh"
_assert_exit "01-guarded" 0
_assert_empty_stdout "01-guarded"

# --- Fixture 02: unguarded — must flag at line 1 -------------------------
echo "== test: 02-unguarded — \${VAR} flagged"
_run_audit "${FIXTURES_DIR}/02-unguarded.sh"
_assert_exit "02-unguarded" 1
_assert_contains "02-unguarded" "02-unguarded.sh:1:MILESTONE_MODE"

# --- Fixture 03: comment-only line — must NOT flag -----------------------
echo "== test: 03-comment — # \${VAR} in comment is skipped"
_run_audit "${FIXTURES_DIR}/03-comment.sh"
_assert_exit "03-comment" 0
_assert_empty_stdout "03-comment"

# --- Fixture 04: conditional — must NOT flag -----------------------------
echo "== test: 04-conditional — \${VAR+x} existence check is safe"
_run_audit "${FIXTURES_DIR}/04-conditional.sh"
_assert_exit "04-conditional" 0
_assert_empty_stdout "04-conditional"

# --- Fixture 05: out of allowlist — must NOT flag ------------------------
echo "== test: 05-out-of-allowlist — non-allowlist var ignored"
_run_audit "${FIXTURES_DIR}/05-out-of-allowlist.sh"
_assert_exit "05-out-of-allowlist" 0
_assert_empty_stdout "05-out-of-allowlist"

# --- Fixture 06: single-quoted heredoc — must NOT flag -------------------
echo "== test: 06-heredoc — <<'EOF' suppresses expansion"
_run_audit "${FIXTURES_DIR}/06-heredoc.sh"
_assert_exit "06-heredoc" 0
_assert_empty_stdout "06-heredoc"

# --- Performance assertion: default scan completes in under 5 seconds ----
echo "== test: default scan (lib/ + stages/) under 5s"
_start=$(date +%s)
set +e
bash "${AUDIT_SCRIPT}" >/dev/null 2>&1
set -e
_end=$(date +%s)
_elapsed=$(( _end - _start ))
echo "   elapsed: ${_elapsed}s"
if [[ "${_elapsed}" -ge 5 ]]; then
    echo "FAIL: default scan took ${_elapsed}s, exceeds 5s ceiling"
    FAILED_CASES+=("perf-default-scan")
fi

# --- Summary -------------------------------------------------------------
if [[ "${#FAILED_CASES[@]}" -eq 0 ]]; then
    echo "PASS: all audit-bash-env fixture cases green"
    exit 0
fi
echo "FAIL: ${#FAILED_CASES[@]} cases failed:"
printf '  - %s\n' "${FAILED_CASES[@]}"
exit 1
