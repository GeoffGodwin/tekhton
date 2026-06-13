#!/usr/bin/env bash
# Test: m27 false-completion gate, end-to-end through check_milestone_acceptance.
#
# Drives the REAL check_milestone_acceptance (lib/milestone_acceptance.sh) in a
# throwaway git repo, reproducing the false-completion scenario: TEST_CMD passes
# but the agent produced no substantive files. Asserts:
#   1. gate ON  + hollow run         -> FAIL (rc 1)   (the fix)
#   2. gate OFF + hollow run         -> PASS (rc 0)   (proves it IS m27, not noise)
#   3. gate ON  + real work present  -> PASS (rc 0)
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }

# minimal stubs for check_milestone_acceptance's collaborators
header(){ :; }; log(){ :; }; warn(){ :; }; success(){ :; }
run_op(){ shift; "$@"; }          # run_op "desc" cmd... -> run cmd
parse_milestones(){ echo ""; }    # DAG mode: no inline criteria in CLAUDE.md

# shellcheck source=../lib/milestone_acceptance.sh disable=SC1091
source "${TEKHTON_HOME}/lib/milestone_acceptance.sh"
set +e   # the sourced file enables set -e; we capture rc deliberately

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || { echo "FAIL: cd tmp"; exit 1; }
git init -q; git config user.email t@t.t; git config user.name t
echo seed > seed.txt; git add seed.txt; git commit -qm seed
mkdir -p .tekhton .claude/logs
export TEKHTON_SESSION_DIR="${WORK}/.tekhton/session"
export MILESTONE_MODE=true TEST_CMD=true
unset ANALYZE_CMD 2>/dev/null || true

# hollow state: agent self-reported COMPLETE but changed only artifacts
echo "Status: COMPLETE" > .tekhton/CODER_SUMMARY.md
echo "5.99.0" > VERSION

rc=0
MILESTONE_REQUIRE_SUBSTANTIVE_WORK=true check_milestone_acceptance 21 CLAUDE.md >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 1 ]]; then pass "hollow run is BLOCKED with gate on (rc 1)"
else fail "hollow run was NOT blocked with gate on (rc=$rc)"; fi

rc=0
MILESTONE_REQUIRE_SUBSTANTIVE_WORK=false check_milestone_acceptance 21 CLAUDE.md >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then pass "same hollow run passes with gate off (proves it is m27)"
else fail "gate-off control did not pass (rc=$rc)"; fi

echo "package x" > feature.go
rc=0
MILESTONE_REQUIRE_SUBSTANTIVE_WORK=true check_milestone_acceptance 21 CLAUDE.md >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then pass "real work passes with gate on (rc 0)"
else fail "real work was incorrectly blocked (rc=$rc)"; fi

echo "────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
[[ "$FAIL" -eq 0 ]]
