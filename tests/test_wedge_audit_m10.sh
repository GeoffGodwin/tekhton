#!/usr/bin/env bash
# =============================================================================
# test_wedge_audit_m10.sh — Tests for the m10-specific patterns added to
# scripts/wedge-audit.sh:
#
#   Pattern A: python3 -c.*json  (single-line inline JSON parse regression guard)
#   Pattern B: source .*/agent_monitor*  (re-introduction of deleted supervisor)
#   Pattern C: source .*/agent_retry*   (re-introduction of deleted supervisor)
#
# Each test:
#   1. Writes a temp .sh file into lib/ with a PID-scoped unique name
#   2. Runs wedge-audit.sh and asserts the expected exit code
#   3. Cleans up the temp file
#
# HEAD itself must be clean (verified first).
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_SCRIPT="${TEKHTON_HOME}/scripts/wedge-audit.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $*"; FAIL=$(( FAIL + 1 )); }

# PID-scoped temp file so parallel runs don't collide.
_VFILE="${TEKHTON_HOME}/lib/_test_wedge_m10_violation_$$.sh"
trap 'rm -f "$_VFILE"' EXIT INT TERM

_audit_output=""
_audit_rc=0

_inject_and_audit() {
    local content="$1"
    printf '%s\n' "#!/usr/bin/env bash" "$content" > "$_VFILE"
    _audit_rc=0
    _audit_output=$(bash "$AUDIT_SCRIPT" 2>&1) || _audit_rc=$?
}

_reset() {
    _audit_rc=0
    _audit_output=""
    rm -f "$_VFILE"
}

# ---------------------------------------------------------------------------
# Test 1 (sanity): HEAD is clean — the m10 patterns must not trip on the
# actual source tree (since agent_monitor*.sh and agent_retry*.sh are deleted
# and no file should contain a single-line python3 -c json call).
# ---------------------------------------------------------------------------

if bash "$AUDIT_SCRIPT" >/dev/null 2>&1; then
    pass "1 clean HEAD exits 0 (m10 patterns not tripped on production source)"
else
    fail "1 clean HEAD: wedge-audit failed on the real source tree — check for regressions"
fi

# ---------------------------------------------------------------------------
# Test 2: Pattern A — single-line python3 -c "...json..." is detected.
# ---------------------------------------------------------------------------

_inject_and_audit 'ver=$(python3 -c "import json; print(json.loads(open(f).read())[\"version\"])")'
if [[ "$_audit_rc" -ne 0 ]]; then
    pass "2 python3 -c '...json...' (double-quoted) detected"
else
    fail "2 python3 -c '...json...' should have been detected, audit exit was 0"
fi
_reset

# ---------------------------------------------------------------------------
# Test 3: Pattern A — variant with single-quote python3 argument.
# ---------------------------------------------------------------------------

_inject_and_audit "ver=\$(python3 -c 'import json; d = json.load(open(\"x\")); print(d[\"version\"])')"
if [[ "$_audit_rc" -ne 0 ]]; then
    pass "3 python3 -c '...json...' (single-quoted) detected"
else
    fail "3 python3 -c single-quote variant should have been detected"
fi
_reset

# ---------------------------------------------------------------------------
# Test 4: Pattern A — python3 followed by -c and json anywhere on same line.
# ---------------------------------------------------------------------------

_inject_and_audit 'result=$(python3    -c "import json; sys.exit(0)")'
if [[ "$_audit_rc" -ne 0 ]]; then
    pass "4 python3 -c with extra whitespace detected"
else
    fail "4 python3 -c whitespace variant should have been detected"
fi
_reset

# ---------------------------------------------------------------------------
# Test 5: Pattern B — source .../agent_monitor_platform.sh is detected.
# The pattern is anchored to a source/.  builtin at line start.
# ---------------------------------------------------------------------------

_inject_and_audit 'source "${TEKHTON_HOME}/lib/agent_monitor_platform.sh"'
if [[ "$_audit_rc" -ne 0 ]]; then
    pass "5 source .../agent_monitor_platform.sh detected"
else
    fail "5 agent_monitor_platform.sh source should have been detected"
fi
_reset

# ---------------------------------------------------------------------------
# Test 6: Pattern B — source .../agent_monitor.sh detected.
# ---------------------------------------------------------------------------

_inject_and_audit '. "${TEKHTON_HOME}/lib/agent_monitor.sh"'
if [[ "$_audit_rc" -ne 0 ]]; then
    pass "6 . .../agent_monitor.sh detected"
else
    fail "6 agent_monitor.sh dot-source should have been detected"
fi
_reset

# ---------------------------------------------------------------------------
# Test 7: Pattern C — source .../agent_retry.sh detected.
# ---------------------------------------------------------------------------

_inject_and_audit 'source "${TEKHTON_HOME}/lib/agent_retry.sh"'
if [[ "$_audit_rc" -ne 0 ]]; then
    pass "7 source .../agent_retry.sh detected"
else
    fail "7 agent_retry.sh source should have been detected"
fi
_reset

# ---------------------------------------------------------------------------
# Test 8: Pattern C — source .../agent_retry_pause.sh detected.
# ---------------------------------------------------------------------------

_inject_and_audit 'source "${TEKHTON_HOME}/lib/agent_retry_pause.sh"'
if [[ "$_audit_rc" -ne 0 ]]; then
    pass "8 source .../agent_retry_pause.sh detected"
else
    fail "8 agent_retry_pause.sh source should have been detected"
fi
_reset

# ---------------------------------------------------------------------------
# Test 9: Comment mentioning agent_monitor.sh should NOT trigger the pattern.
# The audit pattern is anchored to ^[[:space:]]*(source|\.)  — a comment line
# does not start with source or '.'.
# ---------------------------------------------------------------------------

_inject_and_audit '# This file was replaced by agent_monitor.sh and agent_retry.sh in m10'
if [[ "$_audit_rc" -eq 0 ]]; then
    pass "9 comment naming agent_monitor.sh does not trigger pattern"
else
    fail "9 comment line incorrectly triggered the wedge-audit pattern"
fi
_reset

# ---------------------------------------------------------------------------
# Test 10: python3 without -c and json should NOT trigger Pattern A.
# (e.g. a python3 script path that happens to contain 'json' in the name)
# ---------------------------------------------------------------------------

_inject_and_audit 'python3 tools/parse_json_schema.py "$file"'
if [[ "$_audit_rc" -eq 0 ]]; then
    pass "10 python3 without -c flag is not flagged"
else
    fail "10 python3 script invocation without -c incorrectly flagged"
fi
_reset

# ---------------------------------------------------------------------------
# Test 11: Report output names the offending file when Pattern A fires.
# ---------------------------------------------------------------------------

printf '%s\n' '#!/usr/bin/env bash' 'v=$(python3 -c "import json; print(1)")' > "$_VFILE"
_report_out=$(bash "$AUDIT_SCRIPT" 2>&1) || true
base=$(basename "$_VFILE")
if echo "$_report_out" | grep -qF "$base"; then
    pass "11 audit report names the violating file for Pattern A"
else
    fail "11 audit report does not name violating file; got: $_report_out"
fi
_reset

# ---------------------------------------------------------------------------
# Test 12: Report output names the offending file when Pattern B fires.
# ---------------------------------------------------------------------------

printf '%s\n' '#!/usr/bin/env bash' 'source "${TEKHTON_HOME}/lib/agent_monitor.sh"' > "$_VFILE"
_report_out=$(bash "$AUDIT_SCRIPT" 2>&1) || true
base=$(basename "$_VFILE")
if echo "$_report_out" | grep -qF "$base"; then
    pass "12 audit report names the violating file for Pattern B"
else
    fail "12 audit report does not name violating file for Pattern B; got: $_report_out"
fi
_reset

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "wedge-audit m10 tests: Passed=$PASS Failed=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "All wedge-audit m10 tests passed."
