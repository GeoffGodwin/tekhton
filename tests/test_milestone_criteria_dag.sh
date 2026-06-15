#!/usr/bin/env bash
# =============================================================================
# test_milestone_criteria_dag.sh — S5: acceptance reads DAG milestone criteria
# (_milestone_criteria_semijoined) and runs automatable ones
# (_run_automatable_criteria). Both in lib/milestone_acceptance_deliverable.sh.
# =============================================================================
set -u
TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Collaborator stubs used by _run_automatable_criteria.
log() { :; }; success() { :; }; warn() { :; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# Milestone fixture with criteria (one automatable, one prose, one with backticks).
cat > "$WORK/m.md" <<'EOF'
# m99 — Test

## Acceptance Criteria

- [ ] `bash -n lib/common.sh` passes.
- [ ] The Foo() function returns 0 on success.
- [ ] `internal/x.go` exists.

## Watch For
- nothing
EOF
_read_milestone_file() { cat "$WORK/m.md"; }

# shellcheck source=../lib/milestone_acceptance_deliverable.sh disable=SC1091
source "${TEKHTON_HOME}/lib/milestone_acceptance_deliverable.sh"
set +e

# --- _milestone_criteria_semijoined ----------------------------------------
joined=$(_milestone_criteria_semijoined 99)
if grep -q "bash -n lib/common.sh passes." <<<"$joined"; then
    pass "criteria extracted from DAG file (backticks stripped)"
else
    fail "criteria not extracted correctly: $joined"
fi
# 3 criteria -> 3 ';' delimiters; and Watch For section excluded.
delims=$(grep -o ';' <<<"$joined" | wc -l | tr -d ' ')
if [[ "$delims" == "3" ]]; then pass "exactly 3 criteria joined"; else fail "want 3 delimiters, got $delims ($joined)"; fi
if grep -q "nothing" <<<"$joined"; then fail "Watch For leaked into criteria"; else pass "non-criteria sections excluded"; fi

# --- _run_automatable_criteria: passing bash -n ----------------------------
_run_automatable_criteria "bash -n ${TEKHTON_HOME}/lib/common.sh;The Foo returns 0;"
rc=$?
if [[ "$rc" -eq 0 ]]; then pass "valid bash -n criterion + prose -> rc 0"; else fail "valid criteria returned rc $rc"; fi

# --- _run_automatable_criteria: failing bash -n ----------------------------
printf 'if then fi (\n' > "$WORK/broken.sh"
_run_automatable_criteria "bash -n ${WORK}/broken.sh;"
rc=$?
if [[ "$rc" -eq 1 ]]; then pass "failing bash -n criterion -> rc 1"; else fail "broken syntax returned rc $rc"; fi

# --- prose-only criteria -> rc 0 (MANUAL, non-blocking) --------------------
_run_automatable_criteria "Something works as described;Another thing;"
rc=$?
if [[ "$rc" -eq 0 ]]; then pass "prose-only criteria are MANUAL (rc 0)"; else fail "prose criteria returned rc $rc"; fi

echo "────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
[[ "$FAIL" -eq 0 ]]
