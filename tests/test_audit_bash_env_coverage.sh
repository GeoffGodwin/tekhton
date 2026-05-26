#!/usr/bin/env bash
# tests/test_audit_bash_env_coverage.sh — m27.1 supplemental coverage.
#
# Covers the two reviewer gaps not addressed by test_audit_bash_env.sh:
#
#   1. Binary-absent fallback path: when the tekhton binary cannot be found,
#      the script must fall back to its hardcoded allowlist and emit a
#      `# WARNING:` line on stderr. The fallback must still exit 0 on clean
#      files and exit 1 (with findings) on unguarded reads.
#
#   2. Inline single-quoted string false positive: `echo '${MILESTONE_MODE}'`
#      is flagged by the awk scanner even though bash does not expand variables
#      inside single quotes. This test documents that known false-positive as a
#      regression guard — if the scanner is later extended to exclude intra-line
#      single-quoted content this test will fail and remind the author to update
#      both the scanner and this assertion.
set -euo pipefail

TEKHTON_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_SCRIPT="${TEKHTON_HOME}/scripts/audit-bash-env.sh"
FIXTURES_DIR="${TEKHTON_HOME}/tests/testdata/audit_bash_env"

FAILED_CASES=()

# Temp dir for the binary-absent tests; cleaned up on exit.
_FALLBACK_TMPDIR=""
trap '[[ -n "${_FALLBACK_TMPDIR}" ]] && rm -rf "${_FALLBACK_TMPDIR}"' EXIT

# Build a PATH that excludes the tekhton binary directory so
# `command -v tekhton` fails inside the audit subprocess.
_NO_BIN_PATH=$(printf '%s' "${PATH}" | tr ':' '\n' \
    | grep -vF "${TEKHTON_HOME}/bin" | tr '\n' ':' | sed 's/:$//')

# --- Assertion helpers (never return 1 so set -e doesn't abort on first fail)

_assert_exit() {
    local label="$1" expected="$2"
    if [[ "${AUDIT_RC}" -ne "${expected}" ]]; then
        echo "FAIL: ${label} — expected exit ${expected}, got ${AUDIT_RC}"
        echo "  stdout: ${AUDIT_STDOUT:-}"
        FAILED_CASES+=("${label}")
    fi
}

_assert_empty() {
    local label="$1" value="${2:-}"
    if [[ -n "${value}" ]]; then
        echo "FAIL: ${label} — expected empty, got: ${value}"
        FAILED_CASES+=("${label}")
    fi
}

_assert_contains() {
    local label="$1" needle="$2" haystack="${3:-${AUDIT_STDOUT:-}}"
    if ! grep -qF -- "${needle}" <<<"${haystack}" 2>/dev/null; then
        echo "FAIL: ${label} — expected '${needle}' in: ${haystack}"
        FAILED_CASES+=("${label}")
    fi
}

# --- Helper: run audit in a context where the tekhton binary cannot be found.
#
# Strategy: copy the script to a temp directory so REPO_ROOT (computed from
# BASH_SOURCE[0]) points to a directory that does not contain tekhton. Also
# pass TEKHTON_BIN=/nonexistent and a PATH without ${TEKHTON_HOME}/bin so all
# three binary-discovery paths in _resolve_tekhton_bin() fail.
#
# Captures stdout → AUDIT_STDOUT, stderr → AUDIT_STDERR, exit → AUDIT_RC.
AUDIT_STDOUT=""
AUDIT_STDERR=""
AUDIT_RC=0

_setup_fallback_tmpdir() {
    if [[ -z "${_FALLBACK_TMPDIR}" ]]; then
        _FALLBACK_TMPDIR=$(mktemp -d)
        mkdir -p "${_FALLBACK_TMPDIR}/scripts"
        cp "${AUDIT_SCRIPT}" "${_FALLBACK_TMPDIR}/scripts/audit-bash-env.sh"
        chmod +x "${_FALLBACK_TMPDIR}/scripts/audit-bash-env.sh"
    fi
}

_run_audit_no_bin() {
    local target="$1"
    _setup_fallback_tmpdir

    local _stderr_file="${_FALLBACK_TMPDIR}/stderr_$$.txt"
    local _rc=0
    set +e
    AUDIT_STDOUT=$(TEKHTON_BIN=/nonexistent PATH="${_NO_BIN_PATH}" \
        bash "${_FALLBACK_TMPDIR}/scripts/audit-bash-env.sh" "${target}" \
        2>"${_stderr_file}")
    _rc=$?
    set -e
    AUDIT_RC="${_rc}"
    AUDIT_STDERR=$(cat "${_stderr_file}" 2>/dev/null || true)
}

# =========================================================================
# Case 1: Binary-absent fallback — negative fixture (guarded form)
# =========================================================================
echo "== test: fallback-guarded — \${VAR:-default} exits 0, empty stdout, WARNING on stderr"

_run_audit_no_bin "${FIXTURES_DIR}/01-guarded.sh"

_assert_exit "fallback-guarded-exit" 0
_assert_empty "fallback-guarded-stdout" "${AUDIT_STDOUT}"
_assert_contains "fallback-guarded-warning" "# WARNING:" "${AUDIT_STDERR}"

# =========================================================================
# Case 2: Binary-absent fallback — positive fixture (unguarded form)
# =========================================================================
echo "== test: fallback-unguarded — bare \${VAR} exits 1, finding on stdout, WARNING on stderr"

_run_audit_no_bin "${FIXTURES_DIR}/02-unguarded.sh"

_assert_exit "fallback-unguarded-exit" 1
_assert_contains "fallback-unguarded-finding" "02-unguarded.sh:1:MILESTONE_MODE"
_assert_contains "fallback-unguarded-warning" "# WARNING:" "${AUDIT_STDERR}"

# =========================================================================
# Case 3: Inline single-quoted string false positive (fixture 07)
#
# The awk scanner matches `${MILESTONE_MODE}` inside `echo '${MILESTONE_MODE}'`
# because it cannot detect intra-line single-quote boundaries. Bash does not
# expand variables inside single quotes, so this is a known false positive.
# This test documents the current behavior so any future fix to exclude
# intra-line single-quoted content causes an explicit test update.
# =========================================================================
echo "== test: single-quoted false positive — echo '\${VAR}' is flagged (known behavior)"

set +e
AUDIT_STDOUT=$(bash "${AUDIT_SCRIPT}" "${FIXTURES_DIR}/07-single-quoted.sh" 2>/dev/null)
AUDIT_RC=$?
set -e

_assert_exit "single-quoted-exit" 1
_assert_contains "single-quoted-finding" "07-single-quoted.sh:1:MILESTONE_MODE"

# =========================================================================
# Summary
# =========================================================================
if [[ "${#FAILED_CASES[@]}" -eq 0 ]]; then
    echo "PASS: all audit-bash-env coverage cases green"
    exit 0
fi
echo "FAIL: ${#FAILED_CASES[@]} cases failed:"
printf '  - %s\n' "${FAILED_CASES[@]}"
exit 1
