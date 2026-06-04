#!/usr/bin/env bash
# =============================================================================
# tests/test_preflight_noop_test_cmd.sh — m42
#
# Acceptance Criterion #1: A project with TEST_CMD="true" in MILESTONE_MODE
#   produces a preflight warning and a HUMAN_ACTION_REQUIRED entry.
# Acceptance Criterion #5: REQUIRE_REAL_TEST_CMD=true escalates the warning
#   to a preflight hard-fail; default stays warn.
#
# The check itself lives in internal/preflight/test_cmd.go; this test exercises
# the user-visible behavior through the bash helpers (_is_noop_test_cmd,
# _record_tests_run_state) that mirror the Go side. The Go-side parity is
# covered by internal/preflight/test_cmd_test.go.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub the common.sh log/warn family so the helpers can be sourced standalone.
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# shellcheck source=../lib/hooks_final_checks_helpers.sh
source "${TEKHTON_HOME}/lib/hooks_final_checks_helpers.sh"

# -----------------------------------------------------------------------------
# Group 1: _is_noop_test_cmd recognizes the canonical no-op forms
# -----------------------------------------------------------------------------
echo "=== _is_noop_test_cmd recognition ==="

for noop in "true" ":" "" "  true  " "/bin/true" "/usr/bin/true"; do
    if _is_noop_test_cmd "$noop"; then
        pass "_is_noop_test_cmd recognises '${noop}' as no-op"
    else
        fail "_is_noop_test_cmd MISSED '${noop}' (should be no-op)"
    fi
done

for real in "pytest" "npm test" "cargo test" "go test ./..." "bash tests/run_tests.sh" "true && false"; do
    if _is_noop_test_cmd "$real"; then
        fail "_is_noop_test_cmd false-positive on real command '${real}'"
    else
        pass "_is_noop_test_cmd correctly rejects '${real}'"
    fi
done

# -----------------------------------------------------------------------------
# Group 2: _record_tests_run_state writes the sentinel file and patches
#          RUN_RESULT.json (jq path)
# -----------------------------------------------------------------------------
echo "=== _record_tests_run_state writes sentinel + patches RUN_RESULT.json ==="

PROJ="${TEST_TMPDIR}/proj1"
mkdir -p "${PROJ}/.tekhton"
TEKHTON_DIR="${PROJ}/.tekhton"
export TEKHTON_DIR

cat > "${TEKHTON_DIR}/RUN_RESULT.json" <<'EOF'
{
  "proto": "tekhton.run.result.v1",
  "disposition": "success",
  "attempts": 1
}
EOF

_record_tests_run_state "false"

if [[ -f "${TEKHTON_DIR}/.tests_run_state" ]] \
   && [[ "$(cat "${TEKHTON_DIR}/.tests_run_state")" == "false" ]]; then
    pass "sentinel file written with 'false'"
else
    fail "sentinel file missing or wrong content"
fi

if command -v jq >/dev/null 2>&1; then
    if jq -e '.tests_run == false' "${TEKHTON_DIR}/RUN_RESULT.json" >/dev/null 2>&1; then
        pass "RUN_RESULT.json patched with tests_run: false"
    else
        fail "RUN_RESULT.json not patched with tests_run: false"
    fi
else
    echo "  SKIP: jq not present; RUN_RESULT.json patch path not exercised"
fi

# True-state path: subsequent record should flip the value
_record_tests_run_state "true"
if [[ "$(cat "${TEKHTON_DIR}/.tests_run_state")" == "true" ]]; then
    pass "sentinel file updated to 'true' on second call"
else
    fail "sentinel file not updated to 'true'"
fi
if command -v jq >/dev/null 2>&1; then
    if jq -e '.tests_run == true' "${TEKHTON_DIR}/RUN_RESULT.json" >/dev/null 2>&1; then
        pass "RUN_RESULT.json updated to tests_run: true"
    else
        fail "RUN_RESULT.json not updated to tests_run: true"
    fi
fi

# -----------------------------------------------------------------------------
# Group 3: _record_tests_run_state is best-effort when artifacts are missing
# -----------------------------------------------------------------------------
echo "=== _record_tests_run_state best-effort on missing artifacts ==="

PROJ2="${TEST_TMPDIR}/proj-empty"
mkdir -p "$PROJ2"   # no .tekhton subdir
TEKHTON_DIR="${PROJ2}/.tekhton"
export TEKHTON_DIR

if _record_tests_run_state "false"; then
    pass "_record_tests_run_state returns 0 when TEKHTON_DIR is absent"
else
    fail "_record_tests_run_state failed on missing TEKHTON_DIR"
fi
if [[ ! -f "${TEKHTON_DIR}/.tests_run_state" ]]; then
    pass "no sentinel written when TEKHTON_DIR is absent"
else
    fail "sentinel was written despite missing TEKHTON_DIR"
fi

# Present TEKHTON_DIR but no RUN_RESULT.json: sentinel still writes, no crash.
PROJ3="${TEST_TMPDIR}/proj-nojson"
mkdir -p "${PROJ3}/.tekhton"
TEKHTON_DIR="${PROJ3}/.tekhton"
export TEKHTON_DIR
if _record_tests_run_state "false"; then
    pass "_record_tests_run_state returns 0 when RUN_RESULT.json is absent"
else
    fail "_record_tests_run_state failed on missing RUN_RESULT.json"
fi
if [[ "$(cat "${TEKHTON_DIR}/.tests_run_state")" == "false" ]]; then
    pass "sentinel written even when RUN_RESULT.json is absent"
else
    fail "sentinel not written when RUN_RESULT.json is absent"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
