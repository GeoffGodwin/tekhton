#!/usr/bin/env bash
# tests/test_no_claude_e2e_structure.sh — structural validation for the m23
# zero-claude e2e harness and its fixture project.
#
# Does NOT run the full pipeline (that requires TEKHTON_E2E=1 and a built
# binary). This test verifies:
#   1. test_no_claude_e2e.sh exists and self-skips without TEKHTON_E2E=1
#   2. The cutover_project fixture has all required files with correct content
#   3. The scripts/audit-raw-claude.sh prerequisite exists
#   4. The fixture pipeline.conf has the correct settings for a fake-shim run
#   5. The fixture MANIFEST.cfg uses the expected format
#   6. The fixture m01-hello.md has the required acceptance criteria
#
# All assertions must be deterministic and independent of pipeline state.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_SCRIPT="${TEKHTON_HOME}/tests/test_no_claude_e2e.sh"
FIXTURE_DIR="${TEKHTON_HOME}/tests/fixtures/cutover_project"
SCRIPTS_DIR="${TEKHTON_HOME}/scripts"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1"; FAIL=$(( FAIL + 1 )); }

# ---------------------------------------------------------------------------
# 1. e2e test script exists and self-skips without TEKHTON_E2E=1
# ---------------------------------------------------------------------------

if [[ -f "$E2E_SCRIPT" ]]; then
    pass "e2e script exists at tests/test_no_claude_e2e.sh"
else
    fail "e2e script missing at tests/test_no_claude_e2e.sh"
fi

if [[ -x "$E2E_SCRIPT" ]] || bash -n "$E2E_SCRIPT" 2>/dev/null; then
    pass "e2e script has valid bash syntax"
else
    fail "e2e script has bash syntax errors"
fi

# Self-skip: running without TEKHTON_E2E=1 must exit 0 with a SKIP message.
if [[ -f "$E2E_SCRIPT" ]]; then
    # Run to capture exit code cleanly.
    unset_e2e_rc=0
    TEKHTON_E2E=0 bash "$E2E_SCRIPT" > /dev/null 2>&1 || unset_e2e_rc=$?
    if [[ "$unset_e2e_rc" -eq 0 ]]; then
        pass "e2e self-skips with exit 0 when TEKHTON_E2E=0"
    else
        fail "e2e exited $unset_e2e_rc (expected 0) when TEKHTON_E2E=0"
    fi

    skip_text=$(TEKHTON_E2E=0 bash "$E2E_SCRIPT" 2>&1 || true)
    if echo "$skip_text" | grep -qi "skip"; then
        pass "e2e prints SKIP message when TEKHTON_E2E=0"
    else
        fail "e2e did not print SKIP message when TEKHTON_E2E=0 (output: ${skip_text})"
    fi

    # Self-skip when var is unset.
    no_var_rc=0
    env -u TEKHTON_E2E bash "$E2E_SCRIPT" > /dev/null 2>&1 || no_var_rc=$?
    if [[ "$no_var_rc" -eq 0 ]]; then
        pass "e2e self-skips with exit 0 when TEKHTON_E2E is unset"
    else
        fail "e2e exited $no_var_rc when TEKHTON_E2E is unset (expected 0)"
    fi
fi

# ---------------------------------------------------------------------------
# 2. Fixture project structure
# ---------------------------------------------------------------------------

if [[ -d "$FIXTURE_DIR" ]]; then
    pass "fixture directory exists: tests/fixtures/cutover_project/"
else
    fail "fixture directory missing: tests/fixtures/cutover_project/"
fi

required_files=(
    ".claude/pipeline.conf"
    ".claude/agents/coder.md"
    ".claude/agents/reviewer.md"
    ".claude/agents/tester.md"
    ".claude/milestones/MANIFEST.cfg"
    ".claude/milestones/m01-hello.md"
)
for f in "${required_files[@]}"; do
    if [[ -f "${FIXTURE_DIR}/${f}" ]]; then
        pass "fixture file exists: $f"
    else
        fail "fixture file missing: $f"
    fi
done

# ---------------------------------------------------------------------------
# 3. Fixture pipeline.conf correctness
# ---------------------------------------------------------------------------

PIPELINE_CONF="${FIXTURE_DIR}/.claude/pipeline.conf"
if [[ -f "$PIPELINE_CONF" ]]; then
    # INTAKE_AGENT_ENABLED=false prevents the fake codex from needing to
    # produce an intake verdict (clarity score etc.).
    if grep -q "^INTAKE_AGENT_ENABLED=false" "$PIPELINE_CONF"; then
        pass "pipeline.conf disables intake agent (not needed for fake-codex run)"
    else
        fail "pipeline.conf missing INTAKE_AGENT_ENABLED=false (fake codex won't produce intake verdict)"
    fi

    # TEST_CMD=true (or "true") ensures the completion gate always passes.
    if grep -qE '^TEST_CMD="?true"?' "$PIPELINE_CONF"; then
        pass "pipeline.conf uses TEST_CMD=true (deterministic gate)"
    else
        fail "pipeline.conf missing TEST_CMD=true (gate may fail in fixture)"
    fi

    # SECURITY_AGENT_ENABLED=false prevents the security stage from needing
    # a full codex interaction with security-review verdicts.
    if grep -q "^SECURITY_AGENT_ENABLED=false" "$PIPELINE_CONF"; then
        pass "pipeline.conf disables security agent"
    else
        fail "pipeline.conf missing SECURITY_AGENT_ENABLED=false"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Fixture MANIFEST.cfg format
# ---------------------------------------------------------------------------

MANIFEST="${FIXTURE_DIR}/.claude/milestones/MANIFEST.cfg"
if [[ -f "$MANIFEST" ]]; then
    # The e2e test greps for: ^m01|...|done| — so MANIFEST must have m01.
    if grep -qE "^m01\|" "$MANIFEST"; then
        pass "MANIFEST.cfg has m01 entry"
    else
        fail "MANIFEST.cfg missing m01 entry (e2e assertion B will fail)"
    fi

    # Initial status must be 'todo' so the pipeline can mark it 'done'.
    if grep -qE "^m01\|[^|]*\|todo\|" "$MANIFEST"; then
        pass "MANIFEST.cfg m01 initial status is 'todo'"
    else
        fail "MANIFEST.cfg m01 status is not 'todo' — pipeline cannot transition it to done"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Fixture milestone m01-hello.md
# ---------------------------------------------------------------------------

M01="${FIXTURE_DIR}/.claude/milestones/m01-hello.md"
if [[ -f "$M01" ]]; then
    if grep -q "hello.txt" "$M01"; then
        pass "m01-hello.md references hello.txt (the coder deliverable)"
    else
        fail "m01-hello.md does not reference hello.txt"
    fi

    if grep -qE "^## Acceptance Criteria" "$M01"; then
        pass "m01-hello.md has Acceptance Criteria section"
    else
        fail "m01-hello.md missing Acceptance Criteria section"
    fi
fi

# ---------------------------------------------------------------------------
# 6. scripts/audit-raw-claude.sh existence
# ---------------------------------------------------------------------------
# The e2e test mentions running this script as a post-run assertion.
# It must exist so the full e2e run can succeed.

AUDIT_SCRIPT="${SCRIPTS_DIR}/audit-raw-claude.sh"
if [[ -f "$AUDIT_SCRIPT" ]]; then
    pass "scripts/audit-raw-claude.sh exists (referenced by e2e assertion)"
else
    fail "scripts/audit-raw-claude.sh missing — e2e post-run assertion will fail"
fi

# ---------------------------------------------------------------------------
# 7. docs/cutover-runbook.md existence (m23 Goal 3)
# ---------------------------------------------------------------------------

RUNBOOK="${TEKHTON_HOME}/docs/cutover-runbook.md"
if [[ -f "$RUNBOOK" ]]; then
    pass "docs/cutover-runbook.md exists"

    for section in "Before June 15" "Promoting stable" "Rollback" "Post-cutover"; do
        if grep -qi "$section" "$RUNBOOK"; then
            pass "runbook has section: $section"
        else
            fail "runbook missing section: $section"
        fi
    done

    if grep -qi "tekhton-stable" "$RUNBOOK"; then
        pass "runbook references ../tekhton-stable promotion procedure"
    else
        fail "runbook does not reference tekhton-stable — stable-promotion steps missing"
    fi

    if grep -qi "test_no_claude_e2e" "$RUNBOOK"; then
        pass "runbook names test_no_claude_e2e.sh as the promotion gate"
    else
        fail "runbook does not name test_no_claude_e2e.sh as the gate"
    fi
else
    fail "docs/cutover-runbook.md missing (m23 Goal 3 not implemented)"
fi

# ---------------------------------------------------------------------------
# 8. docs/v5-polyglot.md cross-link (m23 acceptance criterion)
# ---------------------------------------------------------------------------

POLYGLOT="${TEKHTON_HOME}/docs/v5-polyglot.md"
if [[ -f "$POLYGLOT" ]]; then
    if grep -qi "cutover-runbook" "$POLYGLOT"; then
        pass "docs/v5-polyglot.md links to cutover-runbook"
    else
        fail "docs/v5-polyglot.md missing cross-link to cutover-runbook.md"
    fi
else
    fail "docs/v5-polyglot.md not found"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All structural tests passed (${PASS})"
    exit 0
else
    echo "FAIL: ${FAIL} structural tests failed (${PASS} passed)"
    exit 1
fi
