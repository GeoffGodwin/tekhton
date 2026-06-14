#!/usr/bin/env bash
# =============================================================================
# test_milestone_deliverable_gate.sh — S2 declared-deliverable gate, end-to-end
# through the real check_milestone_acceptance.
#
# Reproduces the m22 failure: a milestone declares Create internal/provider/
# profile.go but the run never builds it (it changes an unrelated file, so m27's
# substantive gate is satisfied). Asserts:
#   1. gate ON  + declared Create file MISSING -> acceptance FAILS (rc 1)
#   2. gate ON  + declared Create file PRESENT -> acceptance PASSES (rc 0)
#   3. gate OFF + missing                       -> PASSES (proves it is S2)
# =============================================================================
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }

# Collaborator stubs.
header(){ :; }; log(){ :; }; warn(){ :; }; success(){ :; }
run_op(){ shift; "$@"; }
parse_milestones(){ echo ""; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || { echo "FAIL: cd"; exit 1; }
git init -q; git config user.email t@t.t; git config user.name t
echo seed > seed.txt; git add seed.txt; git commit -qm seed
mkdir -p .tekhton internal/provider

# Milestone fixture declaring a Create deliverable that the "run" won't build.
cat > "$WORK/milestone.md" <<'EOF'
# m99 — Test

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/provider/profile.go` | Create | The core deliverable. |
| `internal/runner/env.go` | Modify | Export a var. |
EOF
# Stub _read_milestone_file so the gate finds our fixture (any milestone id).
_read_milestone_file(){ cat "$WORK/milestone.md"; }

# shellcheck source=../lib/milestone_acceptance_deliverable.sh disable=SC1091
source "${TEKHTON_HOME}/lib/milestone_acceptance_deliverable.sh"
# shellcheck source=../lib/milestone_acceptance.sh disable=SC1091
source "${TEKHTON_HOME}/lib/milestone_acceptance.sh"
set +e

export MILESTONE_MODE=true TEST_CMD=true
export TEKHTON_SESSION_DIR="${WORK}/.tekhton/session"
unset ANALYZE_CMD 2>/dev/null || true

# Substantive (unrelated) change so the m27 gate passes and check 6 is reached.
echo "package x" > unrelated.go

# Sanity: the parser sees both declared files with correct types.
decl=$(_milestone_declared_files 99)
if grep -q $'internal/provider/profile.go\tCreate' <<<"$decl" \
   && grep -q $'internal/runner/env.go\tModify' <<<"$decl"; then
    pass "parser extracts declared path+type rows"
else
    fail "parser output wrong: $decl"
fi

# Case 1: declared Create file missing -> FAIL
rc=0
MILESTONE_DELIVERABLE_GATE_ENABLED=true check_milestone_acceptance 99 CLAUDE.md >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 1 ]]; then pass "missing Create deliverable blocks acceptance (rc 1)"
else fail "missing deliverable not blocked (rc=$rc)"; fi

# Case 2: create the declared file -> PASS
echo "package provider" > internal/provider/profile.go
rc=0
MILESTONE_DELIVERABLE_GATE_ENABLED=true check_milestone_acceptance 99 CLAUDE.md >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then pass "present Create deliverable passes (rc 0)"
else fail "present deliverable still blocked (rc=$rc)"; fi

# Case 3: gate off + missing again -> PASS (proves it is S2)
rm -f internal/provider/profile.go
rc=0
MILESTONE_DELIVERABLE_GATE_ENABLED=false check_milestone_acceptance 99 CLAUDE.md >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then pass "gate off reverts (rc 0)"
else fail "gate off still blocked (rc=$rc)"; fi

echo "────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
[[ "$FAIL" -eq 0 ]]
