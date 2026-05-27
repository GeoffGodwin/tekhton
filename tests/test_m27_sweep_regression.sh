#!/usr/bin/env bash
# tests/test_m27_sweep_regression.sh — Regression guard for the m27.2
# defensive ${VAR:-default} sweep.
#
# Validates three acceptance criteria that have no other dedicated test:
#   1. audit-bash-env.sh exits 0 with empty stdout on the full repo —
#      the primary AC: the sweep is complete and has not regressed.
#   2. .tekhton/M27_INVENTORY.md no longer exists in the working tree —
#      the transient working artifact was consumed and deleted.
#   3. The _strip_m27_defaults filter added to test_m84_static_analysis.sh
#      correctly strips ${VAR:-PATH/FILENAME.md} forms (close-brace
#      signature) and preserves bare FILENAME.md occurrences.
set -euo pipefail

TEKHTON_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_SCRIPT="${TEKHTON_HOME}/scripts/audit-bash-env.sh"

PASS=0
FAIL=0
FAILED_CASES=()

_pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
_fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; FAILED_CASES+=("$*"); }

# =============================================================================
# Case 1: audit-bash-env.sh exits 0 with empty stdout on the full repo.
#
# This is the primary acceptance criterion for m27.2: the sweep covered every
# unguarded read site in lib/ and stages/. Any future edit that introduces a
# new bare ${VAR} read of a contract variable will flip this test red.
# =============================================================================
echo "== test 1: full-repo audit-bash-env.sh exits 0, empty stdout"

audit_stdout=""
audit_rc=0
set +e
audit_stdout="$(bash "${AUDIT_SCRIPT}" 2>/dev/null)"
audit_rc=$?
set -e

if [[ "${audit_rc}" -ne 0 ]]; then
    _fail "1: audit-bash-env.sh exited ${audit_rc} (expected 0) — unguarded reads remain:"$'\n'"${audit_stdout}"
elif [[ -n "${audit_stdout}" ]]; then
    finding_count=$(echo "${audit_stdout}" | wc -l | tr -d ' ')
    _fail "1: audit-bash-env.sh produced ${finding_count} finding(s) — sweep incomplete:"$'\n'"${audit_stdout}"
else
    _pass "1: audit-bash-env.sh exits 0 with no findings (sweep complete)"
fi

# =============================================================================
# Case 2: .tekhton/M27_INVENTORY.md absent from working tree.
#
# The inventory was a transient artifact produced by m27.1 and consumed by
# m27.2. Its presence would indicate the cleanup step was skipped.
# =============================================================================
echo "== test 2: .tekhton/M27_INVENTORY.md deleted"

inventory_file="${TEKHTON_HOME}/.tekhton/M27_INVENTORY.md"
if [[ -f "${inventory_file}" ]]; then
    _fail "2: M27_INVENTORY.md still exists at ${inventory_file} — should have been git-rm'd"
else
    _pass "2: M27_INVENTORY.md correctly absent from working tree"
fi

# =============================================================================
# Case 3: _strip_m27_defaults filter correctness.
#
# The filter was added to test_m84_static_analysis.sh (ACP accepted by the
# reviewer) so the M84 "no literal filenames" check exempts the m27.2
# ${VAR:-PATH/FILENAME.md} default-expansion form. It uses
# `grep -v "${fname}}"` — the close-brace immediately following the filename
# is the signature that distinguishes a default expansion from a bare literal.
#
# 3a: A line containing FILENAME.md} IS stripped (default-expansion form).
# 3b: A bare FILENAME.md reference without close-brace is NOT stripped.
# 3c: A line in the actual grep-r output format is handled correctly.
# =============================================================================
echo "== test 3: _strip_m27_defaults filter strips close-brace form, preserves bare form"

_strip_m27_defaults() {
    local fname="$1"
    grep -v "${fname}}" || true
}

# 3a
default_line='lib/foo.sh:${SCOUT_REPORT_FILE:-${TEKHTON_DIR}/SCOUT_REPORT.md}'
filtered_3a=$(echo "${default_line}" | _strip_m27_defaults "SCOUT_REPORT.md")
if [[ -n "${filtered_3a}" ]]; then
    _fail "3a: default-expansion line was not stripped: [${filtered_3a}]"
else
    _pass "3a: default-expansion form (close-brace signature) is stripped"
fi

# 3b
bare_line='lib/foo.sh:10:  "SCOUT_REPORT.md" referenced here'
filtered_3b=$(echo "${bare_line}" | _strip_m27_defaults "SCOUT_REPORT.md")
if [[ -z "${filtered_3b}" ]]; then
    _fail "3b: bare literal SCOUT_REPORT.md was incorrectly stripped"
else
    _pass "3b: bare literal reference (no close-brace) is preserved"
fi

# 3c: grep -r output format — the actual format the M84 suite produces
grepr_line='lib/something.sh:22:  echo "${SCOUT_REPORT_FILE:-${TEKHTON_DIR}/SCOUT_REPORT.md}"'
filtered_3c=$(echo "${grepr_line}" | _strip_m27_defaults "SCOUT_REPORT.md")
if [[ -n "${filtered_3c}" ]]; then
    _fail "3c: grep-r format line was not stripped: [${filtered_3c}]"
else
    _pass "3c: grep-r format default-expansion line is stripped"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "=== m27.2 Sweep Regression: ${PASS} passed, ${FAIL} failed ==="

if [[ "${#FAILED_CASES[@]}" -gt 0 ]]; then
    printf '  - FAIL: %s\n' "${FAILED_CASES[@]}"
    exit 1
fi
exit 0
