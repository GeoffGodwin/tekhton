#!/usr/bin/env bash
# Test: m27 substantive-work acceptance backstop (lib/milestone_acceptance.sh).
#
# Verifies the false-completion fix: a milestone that produced no substantive
# (non-artifact) file changes must FAIL acceptance, while one that produced a
# real code change must PASS. Exercises _milestone_substantive_file_count
# directly (the unit it gates on) in a throwaway git repo so the working-tree
# probe is deterministic.
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- minimal shims so milestone_acceptance.sh sources cleanly --------------
log()     { :; }
warn()    { :; }
success() { :; }
header()  { :; }

# shellcheck source=../lib/milestone_acceptance.sh disable=SC1091
source "${TEKHTON_HOME}/lib/milestone_acceptance.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || { echo "FAIL: cannot cd to tmp"; exit 1; }

git init -q
git config user.email t@t.t
git config user.name t
mkdir -p .tekhton .claude/logs .claude/milestones
echo "seed" > seed.txt
git add seed.txt && git commit -qm seed

export TEKHTON_SESSION_DIR="${WORK}/.tekhton/session"

# --- Case A: only artifact changes → count is 0 (would FAIL acceptance) ----
echo "log line" > .tekhton/CODER_SUMMARY.md
echo "{}" > .tekhton/RUN_RESULT.json
echo "noise" > .claude/logs/run.log
echo "5.27.0" > VERSION
printf 'm27|x|done||m27.md|g\n' > .claude/milestones/MANIFEST.cfg
count_a=$(_milestone_substantive_file_count)
if [[ "${count_a:-x}" == "0" ]]; then
    pass "A: artifact-only changes count as 0 substantive files"
else
    fail "A: expected 0, got '${count_a}' (artifacts leaked into substantive count)"
fi

# --- Case B: a real source change → count >= 1 (would PASS acceptance) -----
echo "real code" > feature.go
count_b=$(_milestone_substantive_file_count)
if [[ "${count_b:-0}" -ge 1 ]]; then
    pass "B: a real (non-artifact) file change is counted as substantive (${count_b})"
else
    fail "B: expected >=1, got '${count_b}' (substantive change not detected)"
fi

# --- Case C: untracked source file also counts -----------------------------
rm -f feature.go
echo "untracked" > newmod.py
count_c=$(_milestone_substantive_file_count)
if [[ "${count_c:-0}" -ge 1 ]]; then
    pass "C: untracked non-artifact file counts as substantive (${count_c})"
else
    fail "C: expected >=1 for untracked source, got '${count_c}'"
fi

echo "────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
[[ "$FAIL" -eq 0 ]]
