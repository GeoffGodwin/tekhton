#!/usr/bin/env bash
# Test: Milestone acceptance criteria linter (M85)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/milestone_acceptance_lint.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ============= Unit: _lint_has_behavioral_criterion =============
echo "--- _lint_has_behavioral_criterion ---"

# M72-style criteria (all structural — no behavioral keywords)
m72_criteria="- [ ] TEKHTON_DIR config var exists in lib/config_defaults.sh
- [ ] lib/config_defaults.sh declares TEKHTON_DIR before any variable
- [ ] All new _FILE variables exist in config_defaults.sh
- [ ] PROJECT_RULES_FILE default is still CLAUDE.md
- [ ] Zero literal occurrences of the migrated filenames remain
- [ ] Running the migration twice is a no-op
- [ ] tekhton.sh creates TEKHTON_DIR on startup
- [ ] bash tests/run_tests.sh passes with zero failures
- [ ] shellcheck reports zero warnings"

w=$(_lint_has_behavioral_criterion "$m72_criteria")
if [[ -n "$w" ]]; then
    pass "M72-style structural criteria triggers behavioral warning"
else
    fail "M72-style structural criteria should trigger behavioral warning"
fi

# Criteria with behavioral keywords should not trigger
behavioral_criteria="- [ ] _emit_command_line() emits a comment when source is non-empty
- [ ] bash tests/run_tests.sh passes"

w=$(_lint_has_behavioral_criterion "$behavioral_criteria")
if [[ -z "$w" ]]; then
    pass "Criteria with 'emits' keyword passes behavioral check"
else
    fail "Criteria with 'emits' should not trigger warning: ${w}"
fi

# ============= Unit: _lint_refactor_has_completeness_check =============
echo "--- _lint_refactor_has_completeness_check ---"

w=$(_lint_refactor_has_completeness_check "- [ ] All files moved
- [ ] Build passes")
if [[ -n "$w" ]]; then
    pass "Refactor without grep patterns triggers warning"
else
    fail "Refactor without grep patterns should trigger warning"
fi

w=$(_lint_refactor_has_completeness_check "- [ ] grep for old_name returns zero hits")
if [[ -z "$w" ]]; then
    pass "Refactor with grep pattern passes"
else
    fail "Refactor with grep should pass: ${w}"
fi

w=$(_lint_refactor_has_completeness_check "- [ ] no remaining references to old API")
if [[ -z "$w" ]]; then
    pass "Refactor with 'no remaining' passes"
else
    fail "Refactor with 'no remaining' should pass: ${w}"
fi

# ============= Unit: _lint_config_has_self_referential_check =============
echo "--- _lint_config_has_self_referential_check ---"

w=$(_lint_config_has_self_referential_check "- [ ] New config key added
- [ ] Build passes")
if [[ -n "$w" ]]; then
    pass "Config without self-referential check triggers warning"
else
    fail "Config without self-referential check should trigger warning"
fi

w=$(_lint_config_has_self_referential_check "- [ ] pipeline.conf loads the new key correctly")
if [[ -z "$w" ]]; then
    pass "Config with pipeline.conf check passes"
else
    fail "Config with pipeline.conf should pass: ${w}"
fi

# ============= Integration: lint_acceptance_criteria on real M72 =============
echo "--- lint_acceptance_criteria on real M72 ---"

m72_file="${TEKHTON_HOME}/.claude/milestones/m72-tidy-project-root-tekhton-dir.md"
if [[ -f "$m72_file" ]]; then
    warnings=$(lint_acceptance_criteria "$m72_file")
    wcount=$(echo "$warnings" | grep -c 'Lint:' || true)
    if [[ "$wcount" -ge 2 ]]; then
        pass "Real M72 triggers ${wcount} warnings (>=2)"
    else
        fail "Real M72 should trigger >=2 warnings, got ${wcount}: ${warnings}"
    fi
else
    fail "M72 file not found at ${m72_file}"
fi

# ============= False positive check: M73-M83 =============
echo "--- False positive check (M73-M83) ---"

ms_dir="${TEKHTON_HOME}/.claude/milestones"
for mnum in 73 74 75 76 77 78 79 80 81 82 83; do
    mfile=""
    for f in "${ms_dir}/m${mnum}"-*.md; do
        [[ -f "$f" ]] && mfile="$f" && break
    done
    if [[ -z "$mfile" ]]; then
        fail "M${mnum}: milestone file not found"
        continue
    fi
    mw=$(lint_acceptance_criteria "$mfile")
    if [[ -n "$mw" ]]; then
        fail "M${mnum}: false positive — ${mw}"
    else
        pass "M${mnum}: zero warnings"
    fi
done

# ============= Integration: check_milestone_acceptance logs warnings =============
echo "--- Integration: check_milestone_acceptance ---"

# Variables consumed by sourced libraries (milestone_acceptance.sh, milestones.sh, etc.)
export TEST_CMD=""
export ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
export MILESTONE_DIR=".claude/milestones"
export MILESTONE_DAG_ENABLED=true
export NON_BLOCKING_LOG_FILE="${TEKHTON_DIR}/NON_BLOCKING_LOG.md"
export PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
export MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
export DOCS_STRICT_MODE=false
export PROJECT_RULES_FILE="CLAUDE.md"
export REVIEWER_REPORT_FILE="${TEKHTON_DIR}/REVIEWER_REPORT.md"

mkdir -p "${TMPDIR}/.claude/milestones" "${LOG_DIR}" "${TMPDIR}/${TEKHTON_DIR}"

# Test milestone: refactor with only structural criteria
cat > "${TMPDIR}/.claude/milestones/m99-test-move-files.md" << 'EOF'
# Milestone 99: Test Move Files

## Acceptance Criteria

- [ ] Files moved to new location
- [ ] Build passes
- [ ] Tests pass
EOF

cat > "${TMPDIR}/.claude/milestones/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m99|Test Move Files|pending||m99-test-move-files.md|
EOF

cat > "${TMPDIR}/${NON_BLOCKING_LOG_FILE}" << 'EOF'
# Non-Blocking Notes Log

## Open

## Resolved
EOF

cat > "${TMPDIR}/CLAUDE.md" << 'EOF'
# Project Rules
EOF

source "${TEKHTON_HOME}/lib/state.sh"

# Stub run_build_gate
run_build_gate() { return 0; }
parse_milestones() { echo ""; }
get_milestone_title() { echo "Test Move Files"; }

source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"

cd "$TMPDIR"
load_manifest 2>/dev/null || true

check_output=$(check_milestone_acceptance "99" "CLAUDE.md" 2>&1) || true

if echo "$check_output" | grep -q 'Lint:.*behavioral'; then
    pass "Lint behavioral warning appears in check_milestone_acceptance output"
else
    fail "Lint warning should appear in output"
fi

if echo "$check_output" | grep -q 'Lint:.*refactor.*completeness'; then
    pass "Lint refactor warning appears in check_milestone_acceptance output"
else
    fail "Refactor lint warning should appear in output"
fi

if grep -q 'Lint:' "${TMPDIR}/${NON_BLOCKING_LOG_FILE}" 2>/dev/null; then
    pass "Lint warnings logged to NON_BLOCKING_LOG"
else
    fail "Lint warnings should be logged to NON_BLOCKING_LOG"
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
